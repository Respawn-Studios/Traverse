#!/usr/bin/env python3
"""One explicitly approved generated image; no force operations or automatic retry."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
from dev import APP, ROOT, compiled_debug_inputs, environment, local_directory, require_unlocked_console, stamp
from dev import execute
from runtime_diagnostics import inspect as inspect_runtime
from verify_integrity_volume import identity, read_json, tool, write_json


def build_preparation_probe() -> None:
    execute(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        str(ROOT / "tools/DrivePreparationProbe.swift"),
        *[str(ROOT / "Packages/ExplorerKit/Sources/LocalStorage" / name) for name in
          ("VolumeLifecycle.swift", "VolumeRemovalProtection.swift", "MountedVolumeScope.swift", "NativeDeviceScope.swift",
           "DriveTopology.swift", "VolumeInspection.swift")],
        "-module-cache-path", str(local_directory("compiler-cache/probe")),
        "-o", str(local_directory("tools") / "drive-preparation-probe")], "build-drive-preparation-probe", timeout=120)


class Fixture:
    _IMAGE_SIZES = {512 << 20: "512MiB", 1 << 30: "1GiB"}

    @classmethod
    def prepared(cls, root: Path) -> "Fixture":
        """Read a sealed generated owner before its only image is created."""
        root = root.absolute()
        marker = read_json(root / "owner.json")
        job = str(uuid.UUID(marker.get("jobID", ""))).upper()
        if (root.resolve() != root or root.parent != ROOT / ".build/fixtures"
                or root.name != "drive-lifecycle-" + job
                or marker != {"jobID": job, "bytes": 1 << 30}):
            raise RuntimeError("Prepared generated fixture owner refused")
        instance = cls.__new__(cls)
        instance.job, instance.root, instance.image_bytes = job, root, 1 << 30
        instance.root_id = identity(root)
        instance.image, instance.image_id, instance.mount = root / "fixture.dmg", None, None
        instance.validate()
        if os.path.lexists(instance.image) or instance.attachment() is not None:
            raise RuntimeError("Prepared fixture already has an image or attachment")
        return instance

    @classmethod
    def preserved(cls, root: Path) -> "Fixture":
        root = root.absolute()
        marker = read_json(root / "owner.json")
        job = str(uuid.UUID(marker.get("jobID", ""))).upper()
        image_bytes = marker.get("bytes")
        if type(image_bytes) is not int or image_bytes not in cls._IMAGE_SIZES:
            raise RuntimeError("Preserved fixture size refused")
        if root.resolve() != root or root.parent != ROOT / ".build/fixtures" or root.name != "drive-lifecycle-" + job:
            raise RuntimeError("Preserved fixture path refused")
        instance = cls.__new__(cls)
        instance.job, instance.root = job, root
        instance.image_bytes = image_bytes
        instance.root_id = identity(root)
        instance.image, instance.mount = root / "fixture.dmg", None
        instance.image_id = identity(instance.image)
        instance.validate()
        attachment = instance.attachment()
        mounts = [entity for entity in (attachment or {}).get("system-entities", []) if entity.get("mount-point")]
        receipt_path = root / "drive-receipt.json"
        if receipt_path.exists():
            receipt = read_json(receipt_path)
            if receipt.get("jobID") != job:
                raise RuntimeError("Preserved drive receipt owner changed")
            mounts = [entity for entity in mounts if entity.get("mount-point") == receipt.get("initialMount")]
        if len(mounts) == 1:
            instance.mount = instance.os_mount_path(mounts[0]["mount-point"])
        return instance

    def __init__(self, *, image_bytes: int = 512 << 20, job: str | None = None) -> None:
        if type(image_bytes) is not int or image_bytes not in self._IMAGE_SIZES:
            raise RuntimeError("Fixture size must be exactly 512 MiB or 1 GiB")
        if job is not None:
            try:
                if str(uuid.UUID(job)).upper() != job:
                    raise ValueError("Noncanonical generated job")
            except (TypeError, ValueError, AttributeError):
                raise RuntimeError("Generated fixture job must be a canonical UUID") from None
        self.image_bytes = image_bytes
        self.job = job or str(uuid.uuid4()).upper()
        self.root = local_directory("fixtures") / ("drive-lifecycle-" + self.job)
        self.root.mkdir(mode=0o700)
        self.root_id = identity(self.root)
        self.image = self.root / "fixture.dmg"
        self.mount: Path | None = None
        self.image_id: tuple[int, int] | None = None
        write_json(self.root / "owner.json", {"jobID": self.job, "bytes": self.image_bytes})

    def validate(self) -> None:
        if self.root.resolve() != self.root or identity(self.root) != self.root_id:
            raise RuntimeError("Owned fixture directory changed")
        marker = read_json(self.root / "owner.json")
        if (type(self.image_bytes) is not int or self.image_bytes not in self._IMAGE_SIZES
                or type(marker.get("bytes")) is not int
                or marker != {"jobID": self.job, "bytes": self.image_bytes}):
            raise RuntimeError("Owned fixture marker changed")
        if self.image_id is not None:
            value = self.image.lstat()
            if identity(self.image) != self.image_id or not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size != self.image_bytes:
                raise RuntimeError("Owned image identity or size changed")

    def attachment(self) -> dict | None:
        self.validate()
        # Never persist other images' paths or device descriptions.
        images = plistlib.loads(tool(["/usr/bin/hdiutil", "info", "-plist"]))
        matches = [image for image in images.get("images", []) if image.get("image-path") == str(self.image)]
        if len(matches) > 1:
            raise RuntimeError("Ambiguous generated image attachment")
        if matches and matches[0].get("owner-uid") != os.geteuid():
            raise RuntimeError("Generated image attachment owner changed")
        return matches[0] if matches else None

    @staticmethod
    def os_mount_path(value: str) -> Path:
        mount = Path(value)
        if (not mount.is_absolute() or mount.parent != Path("/Volumes")
                or mount.is_symlink() or mount.resolve() != mount):
            raise RuntimeError("Generated OS-selected mount path refused")
        return mount

    def mounted_owned(self) -> tuple[Path, str]:
        attachment = self.attachment()
        entities = (attachment or {}).get("system-entities", [])
        mounts = [entity for entity in entities if entity.get("mount-point")]
        leaves = [entity.get("dev-entry", "") for entity in entities
                  if entity.get("content-hint") == "41504653-0000-11AA-AA11-00306543ECAC"]
        if (len(mounts) != 1 or len(leaves) != 1 or mounts[0].get("dev-entry") != leaves[0]
                or not re.fullmatch(r"/dev/disk[0-9]+s[0-9]+", leaves[0])):
            raise RuntimeError("Generated attachment must have one mounted APFS volume")
        mount = self.os_mount_path(mounts[0]["mount-point"])
        details = plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", str(mount)]))
        if (details.get("MountPoint") != str(mount) or details.get("DeviceNode") != leaves[0]
                or details.get("FilesystemType", "").lower() != "apfs" or mount.stat().st_dev == self.root_id[0]):
            raise RuntimeError("Refused nonfixture mount")
        self.mount = mount
        return mount, leaves[0]

    def two_member_owned(self, *, original_uuid: str, target_uuid: str | None = None) -> dict:
        """Read two ordinary APFS members of this exact image; keep one-member checks strict."""
        original_uuid = str(uuid.UUID(original_uuid)).upper()
        target_uuid = str(uuid.UUID(target_uuid)).upper() if target_uuid is not None else None
        attachment = self.attachment()
        entities = (attachment or {}).get("system-entities", [])
        outer = entities[0].get("dev-entry", "") if entities else ""
        leaves = [entity.get("dev-entry", "") for entity in entities
                  if entity.get("content-hint") == "41504653-0000-11AA-AA11-00306543ECAC"]
        if (not re.fullmatch(r"/dev/disk[0-9]+", outer) or not 1 <= len(leaves) <= 2
                or len(set(leaves)) != len(leaves)
                or any(not re.fullmatch(r"/dev/disk[0-9]+s[0-9]+", leaf) for leaf in leaves)):
            raise RuntimeError("Generated image outer/APFS attachment changed")
        leaf_infos = [plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", leaf])) for leaf in leaves]
        originals = [info for info in leaf_infos
                     if isinstance(info.get("VolumeUUID"), str)
                     and str(uuid.UUID(info["VolumeUUID"])).upper() == original_uuid]
        if len(originals) != 1:
            raise RuntimeError("Original generated APFS leaf is no longer in the attachment")
        original = originals[0]
        container_device = original.get("APFSContainerReference")
        if (original.get("DeviceNode") not in leaves or original.get("FilesystemType") != "apfs"
                or not isinstance(container_device, str) or not re.fullmatch(r"disk[0-9]+", container_device)):
            raise RuntimeError("Generated APFS attachment no longer resolves to its container")
        graph = plistlib.loads(tool(["/usr/sbin/diskutil", "apfs", "list", "-plist", container_device]))
        containers = graph.get("Containers", [])
        if len(containers) != 1 or not isinstance(containers[0], dict):
            raise RuntimeError("Generated APFS container observation is ambiguous")
        container = containers[0]
        volumes = container.get("Volumes", [])
        stores = container.get("PhysicalStores", [])
        if (container.get("ContainerReference") != container_device or len(volumes) != 2 or len(stores) != 1
                or not isinstance(container.get("APFSContainerUUID"), str)
                or type(container.get("CapacityCeiling")) is not int or container["CapacityCeiling"] <= 0
                or not isinstance(stores[0], dict) or not isinstance(stores[0].get("DeviceIdentifier"), str)):
            raise RuntimeError("Generated APFS graph is not one ordinary two-member container")
        expected = {original_uuid} if target_uuid is None else {original_uuid, target_uuid}
        members: dict[str, dict] = {}
        for member in volumes:
            if not isinstance(member, dict):
                raise RuntimeError("Generated APFS member observation is invalid")
            raw_identifier = member.get("APFSVolumeUUID")
            try:
                identifier = str(uuid.UUID(raw_identifier)).upper()
            except (ValueError, TypeError, AttributeError):
                raise RuntimeError("Generated APFS member UUID is invalid") from None
            device = member.get("DeviceIdentifier")
            if (not isinstance(identifier, str) or not isinstance(device, str)
                    or not re.fullmatch(r"disk[0-9]+s[0-9]+", device) or identifier in members
                    or not isinstance(member.get("Name"), str) or member.get("Roles") != []
                    or any(member.get(key) is not False for key in ("Encryption", "FileVault", "Locked", "CryptoMigrationOn"))
                    or type(member.get("CapacityQuota")) is not int or member["CapacityQuota"] != 0
                    or type(member.get("CapacityReserve")) is not int or member["CapacityReserve"] != 0):
                raise RuntimeError("Generated APFS member has unsupported identity or attributes")
            info = plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", device]))
            mount_text = info.get("MountPoint")
            try:
                info_uuid = str(uuid.UUID(info.get("VolumeUUID"))).upper()
            except (ValueError, TypeError, AttributeError):
                raise RuntimeError("Generated APFS member native UUID is invalid") from None
            if (info.get("DeviceIdentifier") != device or info_uuid != identifier
                    or info.get("APFSContainerReference") != container_device or info.get("FilesystemType") != "apfs"
                    or info.get("Internal") is not False or info.get("Encryption") is not False
                    or info.get("FileVault") is not False or info.get("Locked") is not False
                    or info.get("APFSVolumeGroupID") is not None
                    or not isinstance(mount_text, str) or not mount_text):
                raise RuntimeError("Generated APFS member native info changed")
            mount = self.os_mount_path(mount_text)
            mount_stat = mount.stat()
            if mount_stat.st_dev == self.root_id[0] or not stat.S_ISDIR(mount_stat.st_mode):
                raise RuntimeError("Generated APFS member mount changed")
            mounted_info = plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", str(mount)]))
            if (mounted_info.get("DeviceIdentifier") != device or mounted_info.get("MountPoint") != str(mount)
                    or str(uuid.UUID(mounted_info.get("VolumeUUID"))).upper() != identifier
                    or mount.stat().st_dev != mount_stat.st_dev):
                raise RuntimeError("Generated APFS member mount no longer matches its device")
            members[identifier] = {"device": device, "name": member["Name"], "mount": str(mount),
                                   "mountDevice": mount_stat.st_dev, "caseSensitive": info.get("FilesystemName") == "Case-sensitive APFS"}
        if original_uuid not in members or target_uuid is not None and set(members) != expected:
            raise RuntimeError("Generated APFS sibling or target identity changed")
        self.validate()
        if self.attachment() != attachment:
            raise RuntimeError("Generated image attachment changed during APFS observation")
        return {"outer": outer, "container": container_device, "containerUUID": container["APFSContainerUUID"],
                "capacity": container["CapacityCeiling"], "store": stores[0], "members": members}

    def member_marker(self, mount_text: str, leaf: str, *, expected_device: str,
                      expected_uuid: str, expected_mount_device: int) -> tuple[int, int] | None:
        """Inspect one fixed generated marker through its pinned member mount."""
        if leaf not in (".mac-explorer-drive-owner", ".mac-explorer-format-target"):
            raise RuntimeError("Unrecognized generated APFS marker")
        mount = self.os_mount_path(mount_text)
        expected_uuid = str(uuid.UUID(expected_uuid)).upper()
        def matches_mount() -> bool:
            details = plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", str(mount)]))
            try:
                observed_uuid = str(uuid.UUID(details.get("VolumeUUID"))).upper()
            except (ValueError, TypeError, AttributeError):
                return False
            return (details.get("DeviceIdentifier") == expected_device and observed_uuid == expected_uuid
                    and details.get("MountPoint") == str(mount))
        if not matches_mount():
            raise RuntimeError("Generated APFS marker mount no longer identifies its member")
        directory = os.open(mount, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            pinned = os.fstat(directory)
            if (not stat.S_ISDIR(pinned.st_mode) or pinned.st_dev != expected_mount_device
                    or pinned.st_dev == self.root_id[0]):
                raise RuntimeError("Generated APFS marker mount changed")
            try:
                fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
            except FileNotFoundError:
                if not matches_mount() or os.fstat(directory).st_dev != expected_mount_device:
                    raise RuntimeError("Generated APFS marker mount changed during read")
                return None
            try:
                value = os.fstat(fd)
                if (not stat.S_ISREG(value.st_mode) or value.st_dev != pinned.st_dev
                        or value.st_uid != os.geteuid() or value.st_nlink != 1 or value.st_size != 36
                        or os.read(fd, 37) != self.job.encode()):
                    raise RuntimeError("Generated APFS marker identity or contents changed")
                if not matches_mount() or os.fstat(directory).st_dev != expected_mount_device:
                    raise RuntimeError("Generated APFS marker mount changed during read")
                return value.st_dev, value.st_ino
            finally:
                os.close(fd)
        finally:
            os.close(directory)

    def attach_owned(self) -> None:
        self.validate()
        if self.attachment() is not None:
            raise RuntimeError("Generated image already attached; no duplicate attach")
        # Reuse direct_dmg's normal OS-selected /Volumes mount behavior: macOS27
        # can refuse nested mountpoints on this external development volume.
        tool(["/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-plist", str(self.image)], timeout=300)
        self.mounted_owned()

    def attach_preserved_two_member(self, *, original_uuid: str, target_uuid: str) -> dict:
        """Normal attach of a sealed retained image; keep one-member admission strict."""
        self.validate()
        if self.attachment() is not None:
            raise RuntimeError("Retained generated image is already attached; no duplicate attach")
        # This is an explicit native attachment, not a read-only file open.
        # The caller must own a fresh one-shot attach/detach scope. If the
        # child returns uncertain or the graph differs, retain the attachment.
        tool(["/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-plist", str(self.image)], timeout=300)
        return self.two_member_owned(original_uuid=original_uuid, target_uuid=target_uuid)

    def create(self) -> None:
        self.validate()
        space = os.statvfs(self.root)
        if space.f_bavail * space.f_frsize < 2 * 1024**3:
            raise RuntimeError("Conservative host headroom unavailable")
        print(f"Creating the single approved {self.image_bytes >> 20} MiB image.", flush=True)
        tool(["/usr/sbin/diskutil", "image", "--plist", "create", "blank", "--format", "RAW",
              "--size", self._IMAGE_SIZES[self.image_bytes], "--volumeName", "MacExplorerDrive-" + self.job, "-fs", "APFS", str(self.image)], timeout=300)
        self.image_id = identity(self.image)
        self.validate()
        print("Attaching the generated image at its OS-selected mount. Handle any macOS authorization dialog directly.", flush=True)
        self.attach_owned()
        self.initialize()

    def initialize(self) -> None:
        self.mounted_owned()
        assert self.mount is not None
        mounted = self.mount.stat()
        mount_fd = os.open(self.mount, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            pinned = os.fstat(mount_fd)
            if pinned.st_dev != mounted.st_dev or pinned.st_dev == self.root_id[0] or not stat.S_ISDIR(pinned.st_mode):
                raise RuntimeError("Generated mount changed before marker creation")
            # Pin the mounted directory before creating anything under /Volumes;
            # an unmount must not redirect the marker into the host directory.
            fd = os.open(".mac-explorer-drive-owner", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=mount_fd)
            try:
                if os.fstat(fd).st_dev != pinned.st_dev:
                    raise RuntimeError("Generated ownership marker is on a different filesystem")
                if os.write(fd, self.job.encode()) != 36:
                    raise RuntimeError("Short ownership marker write")
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            os.close(mount_fd)
        source = self.root / "Source"
        source.mkdir(mode=0o700)
        fd = os.open(source / "Generated copy.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            if os.write(fd, b"generated-native-drive-copy") != 27:
                raise RuntimeError("Short generated file write")
            os.fsync(fd)
        finally:
            os.close(fd)
        # The caller writes the existing run_receipt() v3 observation after
        # native preparation, rather than a weaker guessed-path v1 receipt.

    def detach_owned(self) -> None:
        attachment = self.attachment()
        if attachment is None:
            return
        entities = attachment.get("system-entities", [])
        first = entities[0].get("dev-entry", "") if entities else ""
        if not re.fullmatch(r"/dev/disk[0-9]+", first):
            raise RuntimeError("Generated whole-device attachment changed; preserved")
        # Normal image-specific teardown for the freshly matched original
        # image only. This is not a force request or an eject fallback.
        tool(["/usr/bin/hdiutil", "detach", first], timeout=120)
        if self.attachment() is not None:
            raise RuntimeError("Generated image remains attached; no force fallback")

    def run_receipt(self, evidence: Path) -> dict:
        attachment = self.attachment()
        entities = (attachment or {}).get("system-entities", [])
        mounts = [entity for entity in entities if entity.get("mount-point")]
        leaves = [entity.get("dev-entry") for entity in entities
                  if entity.get("content-hint") == "41504653-0000-11AA-AA11-00306543ECAC"]
        first = entities[0].get("dev-entry", "") if entities else ""
        if len(mounts) > 1 or len(leaves) != 1 or not re.fullmatch(r"/dev/disk[0-9]+", first):
            raise RuntimeError("Retained attachment must have one unambiguous generated APFS volume")
        binding = json.loads(tool([str(ROOT / ".build/tools/drive-preparation-probe"), "--owned-node", leaves[0], self.job], timeout=60))
        write_json(evidence / "read-only-native-binding.json", binding)
        if (binding.get("preparation") != "passed" or binding.get("deviceKind") != "diskImage"
                or not binding.get("canEject") or "/dev/" + binding.get("outerBSDName", "") != first
                or not isinstance(binding.get("mediaID"), int) or not isinstance(binding.get("outerMediaID"), int)):
            raise RuntimeError("Native outer-device scope does not match the exact preserved image")
        receipt = {"version": 3, "jobID": self.job, "initialMount": "", "mountDevice": 0,
                   "startsUnmounted": not mounts, "mediaID": binding["mediaID"], "outerMediaID": binding["outerMediaID"],
                   "fixtureDevice": self.root_id[0], "fixtureInode": self.root_id[1],
                   "imageDevice": self.image_id[0], "imageInode": self.image_id[1]}
        if not mounts:
            if binding.get("mount") is not None or not binding.get("canMount"):
                raise RuntimeError("Native unmounted fixture observation disagrees with attachment graph")
            self.validate()
            return receipt
        mount = self.os_mount_path(mounts[0]["mount-point"])
        self.mount = mount
        details = plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", str(mount)]))
        mounted = mount.stat()
        if (details.get("MountPoint") != str(mount) or details.get("DeviceNode") != mounts[0].get("dev-entry")
                or details.get("FilesystemType", "").lower() != "apfs" or mounted.st_dev == self.root_id[0]
                or binding.get("mount") != str(mount) or binding.get("mountDevice") != mounted.st_dev):
            raise RuntimeError("Generated mount binding changed")
        fd = os.open(mount / ".mac-explorer-drive-owner", os.O_RDONLY | os.O_NOFOLLOW)
        try:
            marker = os.fstat(fd)
            if (not stat.S_ISREG(marker.st_mode) or marker.st_dev != mounted.st_dev or marker.st_size != 36
                    or os.read(fd, 37) != self.job.encode()):
                raise RuntimeError("Generated mount owner marker changed")
        finally:
            os.close(fd)
        self.validate()
        return receipt | {"initialMount": str(mount), "mountDevice": mounted.st_dev}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--execute", action="store_true")
    mode.add_argument("--inspect-existing", type=Path)
    mode.add_argument("--qualify-attached", type=Path,
                      help="Run normal lifecycle checks within the separately approved retained-image session; never attaches an image.")
    parser.add_argument("--session-proof", type=Path)
    apfs_mode = parser.add_mutually_exclusive_group()
    apfs_mode.add_argument("--apfs-ui", action="store_true",
                           help="Existing lifecycle owner, one 1 GiB generated image, real CUA Review/Add flow; no other workload.")
    apfs_mode.add_argument("--apfs-format", action="store_true",
                           help="One new 1 GiB generated image; at most one Add and one APFS member Format in a test-only native route.")
    args = parser.parse_args()
    if args.qualify_attached is not None and args.session_proof is None:
        parser.error("--qualify-attached requires --session-proof")
    if args.session_proof is not None and args.qualify_attached is None:
        parser.error("--session-proof requires --qualify-attached")
    if (args.apfs_ui or args.apfs_format) and args.inspect_existing is not None:
        parser.error("APFS mutation modes are not inspection-only actions")
    if args.apfs_format and args.qualify_attached is not None:
        parser.error("--apfs-format requires a fresh image; retained sessions are refused")
    if not args.execute and args.inspect_existing is None and args.qualify_attached is None:
        print("Review only: " + ("one pre-image passive job check, one fresh 1 GiB image, at most one Add and one APFS member Format, then one cold read-only job check. " if args.apfs_format
              else "one 1 GiB image, CUA APFS Review/Add, at most one Add, no lifecycle/Copy workload. " if args.apfs_ui
              else "one 512 MiB APFS image; normal attach, app-coordinated Unmount/Mount/queued Copy/Eject. ")
              + "Preserve evidence and image. Use --execute only with the owner's explicit scoped approval.")
        return 0
    if not args.inspect_existing:
        if args.apfs_ui or args.apfs_format:
            require_unlocked_console()
        # Finish compilation and current-app admission before making a disk
        # image. A missing standalone-probe dependency must consume no mount.
        compiled_debug_inputs(require_current_source=True)
        build_preparation_probe()
    preserved_root = args.inspect_existing or args.qualify_attached
    fixture = Fixture.preserved(preserved_root) if preserved_root else Fixture(image_bytes=1 << 30 if args.apfs_ui or args.apfs_format else 512 << 20)
    if (args.apfs_ui or args.apfs_format) and fixture.image_bytes != 1 << 30:
        raise RuntimeError("APFS qualification requires the exact 1 GiB generated image")
    evidence = local_directory("evidence") / ("drive-lifecycle-" + stamp())
    evidence.mkdir(mode=0o700)
    log = evidence / "native.log"
    report = {"passed": False, "fixture": str(fixture.root), "imagePreserved": True,
              "apfsUI": args.apfs_ui, "apfsFormat": args.apfs_format,
              "addCallBudget": 1 if args.apfs_ui or args.apfs_format else 0,
              "formatCallBudget": 1 if args.apfs_format else 0,
              "preImageVisitBudget": 1 if args.apfs_format else 0,
              "coldReadOnlyVisitBudget": 1 if args.apfs_format else 0}
    uncertain_process = False
    try:
        if args.qualify_attached:
            proof_path = args.session_proof.absolute()
            if proof_path.resolve() != proof_path or proof_path.parent.parent != ROOT / ".build/evidence":
                raise RuntimeError("Retained session evidence path refused")
            proof = read_json(proof_path)
            if proof != {"fixture": str(fixture.root), "imageDevice": fixture.image_id[0],
                         "imageInode": fixture.image_id[1], "phase": "attached-for-qualification"}:
                raise RuntimeError("Retained session image binding changed")
            report["retainedSession"] = str(proof_path.parent)
        elif args.inspect_existing:
            if fixture.attachment() is not None:
                raise RuntimeError("Preserved fixture already attached; no duplicate attach")
            binary = local_directory("tools") / "drive-capability-probe"
            execute(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                     str(ROOT / "tools/DriveCapabilityProbe.swift"), "-o", str(binary)], "build-drive-capability-probe", timeout=120)
            print("Reattaching the approved preserved image for read-only metadata inspection.", flush=True)
            fixture.attach_owned()
            values = json.loads(tool([str(binary), str(fixture.mount)]))
            write_json(evidence / "owned-drive-capabilities.json", values)
            report["passed"] = True
            report["inspectionOnly"] = True
            print(json.dumps(values, indent=2), flush=True)
        else:
            if args.apfs_format:
                if os.path.lexists(fixture.image):
                    raise RuntimeError("Pre-image Format check found an existing fixture image")
                preflight_evidence = local_directory("evidence") / ("drive-lifecycle-preflight-" + fixture.job)
                preflight_evidence.mkdir(mode=0o700)
                preflight_log = preflight_evidence / "native.log"
                preflight_env = environment(tooling=False)
                preflight_env["MAC_EXPLORER_TEST_ROOT"] = str(fixture.root)
                preflight_command = [str(APP / "Contents/MacOS/Mac Explorer"), "--verify-ui", "--offscreen",
                                     "--verify-drive-lifecycle", "--apfs-format-preflight",
                                     "--fixture-root", str(fixture.root), "--evidence-root", str(preflight_evidence)]
                with preflight_log.open("xb") as stream:
                    preflight_process = subprocess.run(preflight_command, env=preflight_env, cwd=ROOT,
                        stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT, timeout=300, check=False)
                preflight_report = read_json(preflight_evidence / "ui-verification.json")
                preflight_result = read_json(preflight_evidence / "apfs-format-preflight.json")
                preflight_diagnostics = inspect_runtime(preflight_log)
                write_json(preflight_evidence / "runtime-diagnostics.json", preflight_diagnostics)
                if (preflight_process.returncode or preflight_report.get("passed") is not True
                        or preflight_report.get("mode") != "native-drive-format-preflight"
                        or preflight_result != {"passed": True, "cleanAdmission": True,
                                                "imageAbsent": True, "recorderCreated": False,
                                                "jobUnchanged": True}
                        or preflight_diagnostics.get("passed") is not True
                        or os.path.lexists(fixture.image)):
                    raise RuntimeError("Pre-image Format saved-job admission failed; image creation was not started")
                fixture.validate()
                report["preImageAdmission"] = True
                report["preImageEvidence"] = str(preflight_evidence)
            fixture.create()
        if not args.inspect_existing:
            # Normal Mount may choose a new mountpoint. Bind each run to the
            # exact retained image's current graph/owner, never its old spelling.
            write_json(evidence / "native-drive-receipt.json", fixture.run_receipt(evidence))
            env = environment(tooling=False)
            env["MAC_EXPLORER_TEST_ROOT"] = str(fixture.root)
            print("Running native drive coordination against the generated volume only.", flush=True)
            with log.open("xb") as stream:
                command = [str(APP / "Contents/MacOS/Mac Explorer"), "--verify-ui", "--offscreen",
                           "--verify-drive-lifecycle", "--fixture-root", str(fixture.root), "--evidence-root", str(evidence)]
                if args.apfs_ui or args.apfs_format:
                    command.append("--apfs-format" if args.apfs_format else "--apfs-ui")
                    # Never timeout/kill the App while either mutation child
                    # may be alive. The App owns actual drain and uncertainty.
                    uncertain_process = True
                    process = subprocess.Popen(command, env=env, cwd=ROOT, stdin=subprocess.DEVNULL,
                        stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                    write_json(evidence / "native-ui-process.json", {"pid": process.pid, "apfsUI": args.apfs_ui,
                        "apfsFormat": args.apfs_format, "addCallBudget": 1, "formatCallBudget": 1 if args.apfs_format else 0,
                        "preSubmissionWaitSeconds": 600 if args.apfs_ui else 0, "parentMutationTimeout": False})
                    process.wait()
                    uncertain_process = False
                else:
                    try:
                        process = subprocess.run(command, env=env, cwd=ROOT, stdin=subprocess.DEVNULL,
                            stdout=stream, stderr=subprocess.STDOUT, timeout=300, check=False)
                    except subprocess.TimeoutExpired:
                        uncertain_process = True
                        raise RuntimeError("Owned native process timed out; no automatic detach while OS request state is uncertain")
            result = read_json(evidence / "ui-verification.json")
            uncertain_process = any(result.get(key) for key in
                ("nativeRequestMayBePending", "driveCheckMayBePending", "readerAdmissionClosed"))
            diagnostics = inspect_runtime(log)
            write_json(evidence / "runtime-diagnostics.json", diagnostics)
            if process.returncode or not result.get("passed") or not diagnostics.get("passed"):
                raise RuntimeError("Native drive qualification did not pass; see retained evidence")
            if args.apfs_format:
                outcome = read_json(evidence / "apfs-format-result.json")
                if outcome.get("passed") is not True or outcome.get("submitted") is not True:
                    raise RuntimeError("Generated APFS Format did not return an exact verified result")
                graph = fixture.two_member_owned(original_uuid=outcome["siblingUUID"], target_uuid=outcome["formattedUUID"])
                if (graph["outer"] != outcome["outerDevice"]
                        or graph["members"][outcome["siblingUUID"]]["device"] != outcome["siblingDevice"]
                        or graph["members"][outcome["formattedUUID"]]["name"] != outcome["formattedName"]):
                    raise RuntimeError("Generated APFS Format post-graph changed after native verification")
                sibling_mount = graph["members"][outcome["siblingUUID"]]["mount"]
                target_mount = graph["members"][outcome["formattedUUID"]]["mount"]
                sibling = graph["members"][outcome["siblingUUID"]]
                target = graph["members"][outcome["formattedUUID"]]
                sibling_marker = fixture.member_marker(sibling_mount, ".mac-explorer-drive-owner",
                    expected_device=sibling["device"], expected_uuid=outcome["siblingUUID"],
                    expected_mount_device=sibling["mountDevice"])
                target_marker = fixture.member_marker(target_mount, ".mac-explorer-format-target",
                    expected_device=target["device"], expected_uuid=outcome["formattedUUID"],
                    expected_mount_device=target["mountDevice"])
                if (sibling_marker != (graph["members"][outcome["siblingUUID"]]["mountDevice"], outcome["siblingMarkerInode"])
                        or target_marker is not None):
                    raise RuntimeError("Generated APFS sibling marker or erased target marker changed")
                report["twoMemberPostcheck"] = True
                # Read the durable unresolved job in a separate app process
                # while the same image remains attached. Its evidence is a
                # sibling directory because the native report is exclusive.
                cold_evidence = local_directory("evidence") / ("drive-lifecycle-cold-" + fixture.job)
                cold_evidence.mkdir(mode=0o700)
                write_json(cold_evidence / "native-drive-receipt.json",
                           read_json(evidence / "native-drive-receipt.json"))
                cold_log = cold_evidence / "native.log"
                cold_command = [str(APP / "Contents/MacOS/Mac Explorer"), "--verify-ui", "--offscreen",
                                "--verify-drive-lifecycle", "--apfs-format-cold",
                                "--fixture-root", str(fixture.root), "--evidence-root", str(cold_evidence)]
                with cold_log.open("xb") as stream:
                    cold_process = subprocess.run(cold_command, env=env, cwd=ROOT, stdin=subprocess.DEVNULL,
                                                  stdout=stream, stderr=subprocess.STDOUT, timeout=300, check=False)
                cold_report = read_json(cold_evidence / "ui-verification.json")
                cold_result = read_json(cold_evidence / "apfs-format-cold-result.json")
                cold_diagnostics = inspect_runtime(cold_log)
                write_json(cold_evidence / "runtime-diagnostics.json", cold_diagnostics)
                if (cold_process.returncode or cold_report.get("passed") is not True
                        or cold_report.get("mode") != "native-drive-format-cold"
                        or set(cold_result) != {"passed", "jobID", "unresolved", "admissionHeld",
                                                "recordUnchanged", "compatibleInspection"}
                        or cold_result.get("passed") is not True
                        or cold_result.get("jobID") != outcome["jobID"]
                        or cold_result.get("unresolved") is not True
                        or cold_result.get("admissionHeld") is not True
                        or cold_result.get("recordUnchanged") is not True
                        or type(cold_result.get("compatibleInspection")) is not bool
                        or cold_diagnostics.get("passed") is not True):
                    raise RuntimeError("Cold unresolved Format admission did not pass; see retained evidence")
                report["coldReadOnlyPostcheck"] = True
                report["coldEvidence"] = str(cold_evidence)
            if not args.apfs_ui and not args.apfs_format:
                deadline = time.monotonic() + 5
                while fixture.attachment() is not None and time.monotonic() < deadline:
                    time.sleep(0.1)
                if fixture.attachment() is not None:
                    raise RuntimeError("Native Eject did not detach the image's complete device graph")
            report["passed"] = True
    except Exception as error:
        report["failure"] = str(error)
    finally:
        report["imagePreserved"] = os.path.lexists(fixture.image)
        if (args.qualify_attached or args.apfs_ui or args.apfs_format) and not report["passed"]:
            if report["imagePreserved"]:
                report["retainedForDiagnosis"] = True
            else:
                report["stoppedBeforeImage"] = True
        elif fixture.image_id is not None and not uncertain_process:
            try:
                fixture.detach_owned()
                report["normallyDetached"] = True
            except Exception as error:
                report["cleanupFailure"] = str(error)
        write_json(evidence / "runner-report.json", report)
    print(json.dumps(report, indent=2), flush=True)
    print(f"Evidence: {evidence}", flush=True)
    return 0 if report["passed"] and report.get("normallyDetached") else 1


if __name__ == "__main__":
    raise SystemExit(main())
