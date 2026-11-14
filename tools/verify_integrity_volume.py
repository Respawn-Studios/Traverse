#!/usr/bin/env python3
"""Opt-in integrity qualification on one owned 512 MiB RAW APFS image.

Default invocation describes the commands. --execute is the separately reviewed
action. No force-eject path exists. Image and generated receipts are retained.
"""
from __future__ import annotations

import argparse
import errno
import json
import math
import os
from pathlib import Path
import plistlib
import random
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory, stamp

IMAGE_BYTES = 512 * 1024 * 1024
SOURCE_BYTES = 16 * 1024 * 1024
OUTPUT_LIMIT = 4 * 1024 * 1024
LOG_LIMIT = 16 * 1024 * 1024
ROOT_MARKER = ".integrity-volume-owner-v1.json"


def identity(path: Path, *, require_owner: bool = True) -> tuple[int, int]:
    value = path.lstat()
    if stat.S_ISLNK(value.st_mode) or (require_owner and value.st_uid != os.geteuid()):
        raise RuntimeError("Owned fixture identity refused")
    return value.st_dev, value.st_ino


def write_json(path: Path, value: dict) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        data = json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
        if len(data) > OUTPUT_LIMIT:
            raise RuntimeError("Receipt limit exceeded")
        offset = 0
        while offset < len(data):
            count = os.write(fd, data[offset:])
            if count <= 0: raise RuntimeError("Receipt made no write progress")
            offset += count
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path: Path) -> dict:
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_uid != os.geteuid() or value.st_size > OUTPUT_LIMIT:
        raise RuntimeError("Owned receipt refused")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        data = os.read(fd, OUTPUT_LIMIT + 1)
        if (os.fstat(fd).st_dev, os.fstat(fd).st_ino) != (value.st_dev, value.st_ino):
            raise RuntimeError("Receipt changed")
        parsed = json.loads(data)
        if not isinstance(parsed, dict):
            raise RuntimeError("Receipt schema refused")
        return parsed
    finally:
        os.close(fd)


def stop_owned_child(child: subprocess.Popen) -> None:
    """Only the process group created by this exact Popen invocation."""
    if child.poll() is not None:
        return
    if os.getpgid(child.pid) != child.pid:
        raise RuntimeError("Child ownership changed; no signal sent")
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if child.poll() is None and os.getpgid(child.pid) == child.pid:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)


class OwnedToolFailure(RuntimeError):
    """Fixed process facts only; never command arguments or captured output."""
    def __init__(self, reason: str, *, returncode: int | None, stdout_eof: bool, stderr_eof: bool,
                 stdout_bytes: int, stderr_bytes: int, elapsed: float, timeout: float, started: bool = True) -> None:
        state = "notStarted" if not started else "running" if returncode is None else (
            "exited" if stdout_eof and stderr_eof else "exitedWithOpenPipes")
        self.facts = {"reason": reason, "childState": state, "returnCode": returncode,
                      "stdoutEOF": stdout_eof, "stderrEOF": stderr_eof,
                      "stdoutBytes": stdout_bytes, "stderrBytes": stderr_bytes,
                      "elapsedSeconds": round(elapsed, 6), "timeoutSeconds": timeout}
        super().__init__("Owned device-tool failure: " + json.dumps(self.facts, sort_keys=True, separators=(",", ":")))


def tool(argv: list[str], timeout: int = 60) -> bytes:
    """Bound tool output in memory; never persist other images' paths from info."""
    if not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("Owned device-tool deadline must be finite and positive")
    started = time.monotonic()
    try:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        raise OwnedToolFailure("launch", returncode=None, stdout_eof=False, stderr_eof=False,
            stdout_bytes=0, stderr_bytes=0, elapsed=time.monotonic() - started, timeout=timeout, started=False) from None
    selector = selectors.DefaultSelector()
    buffers = {"out": bytearray(), "err": bytearray()}
    eof = {"out": False, "err": False}
    for stream, key in [(child.stdout, "out"), (child.stderr, "err")]:
        assert stream is not None
        selector.register(stream, selectors.EVENT_READ, key)
    deadline = started + timeout

    def failure(reason: str) -> OwnedToolFailure:
        # Snapshot before owned-child cleanup: exit0 plus undrained pipes is
        # materially different from a process still running at the deadline.
        return OwnedToolFailure(reason, returncode=child.poll(), stdout_eof=eof["out"], stderr_eof=eof["err"],
            stdout_bytes=len(buffers["out"]), stderr_bytes=len(buffers["err"]),
            elapsed=time.monotonic() - started, timeout=timeout)

    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise failure("timeout")
            for key, _ in selector.select(timeout=min(0.1, remaining)):
                try:
                    block = os.read(key.fileobj.fileno(), 65536)
                except OSError as error:
                    if error.errno == errno.EINTR:
                        continue
                    raise failure("outputRead") from None
                if not block:
                    eof[key.data] = True
                    selector.unregister(key.fileobj)
                    continue
                buffers[key.data].extend(block)
                if sum(map(len, buffers.values())) > OUTPUT_LIMIT:
                    raise failure("outputLimit")
        try:
            code = child.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise failure("timeout") from None
        if code:
            # Deliberately omit raw output containing device or unrelated image paths.
            raise failure("nonzeroExit")
        return bytes(buffers["out"])
    finally:
        if child.poll() is None:
            stop_owned_child(child)
        selector.close()
        if child.stdout: child.stdout.close()
        if child.stderr: child.stderr.close()


class FixtureVolume:
    def __init__(self) -> None:
        self.job_id = str(uuid.uuid4()).upper()
        base = local_directory("integrity-volumes")
        self.root = base / self.job_id
        self.root.mkdir(mode=0o700)
        self.root_identity = identity(self.root)
        self.image = self.root / "fixture.dmg"
        self.mount = self.root / "mount"
        self.image_identity: tuple[int, int] | None = None
        self.manifest: dict | None = None
        self.filler_identity: tuple[int, int] | None = None
        self.child: subprocess.Popen | None = None
        self.child_log = None
        self.log_paths: list[Path] = []
        write_json(self.root / ROOT_MARKER, {"version": 1, "jobID": self.job_id, "imageBytes": IMAGE_BYTES})
        # OperationJournal must create its own missing directory and ownership marker.
        # An unrelated pre-existing empty directory is correctly refused by the engine.
        for name in ("source", "control"):
            (self.root / name).mkdir(mode=0o700)

    def check_root(self) -> None:
        if self.root.resolve() != self.root or identity(self.root) != self.root_identity:
            raise RuntimeError("Fixture root changed")
        marker = read_json(self.root / ROOT_MARKER)
        if marker != {"version": 1, "jobID": self.job_id, "imageBytes": IMAGE_BYTES}:
            raise RuntimeError("Fixture marker changed")
        if self.image_identity is not None:
            value = self.image.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size != IMAGE_BYTES or identity(self.image) != self.image_identity:
                raise RuntimeError("Fixed image identity/size changed")

    def attachment(self) -> dict | None:
        self.check_root()
        info = plistlib.loads(tool(["/usr/bin/hdiutil", "info", "-plist"]))
        matches = [item for item in info.get("images", [])
                   if item.get("image-path") == str(self.image)]
        if not matches:
            return None
        if len(matches) != 1:
            raise RuntimeError("Ambiguous owned image attachment")
        entities = matches[0].get("system-entities", [])
        roots = [item["dev-entry"] for item in entities
                 if re.fullmatch(r"/dev/disk[0-9]+", item.get("dev-entry", ""))]
        mounts = [item for item in entities if item.get("mount-point") == str(self.mount)]
        # APFS may include a synthesized whole-device entity as well. The first
        # entity is the backing-image device; every candidate belongs to this image.
        first = entities[0].get("dev-entry") if entities else None
        if not roots or first not in roots or len(mounts) != 1:
            raise RuntimeError("Owned image device graph refused")
        return {"device": first, "volumeDevice": mounts[0].get("dev-entry")}

    def validate_mounted(self) -> dict:
        attachment = self.attachment()
        if attachment is None:
            raise RuntimeError("Owned image is unavailable; no fallback")
        details = plistlib.loads(tool(["/usr/sbin/diskutil", "info", "-plist", str(self.mount)]))
        mount_identity = identity(self.mount, require_owner=False)
        volume_uuid = str(uuid.UUID(details.get("VolumeUUID", ""))).upper()
        if details.get("MountPoint") != str(self.mount) or details.get("DeviceNode") != attachment["volumeDevice"]:
            raise RuntimeError("Mountpoint/device graph mismatch")
        if str(details.get("FilesystemType", "")).lower() != "apfs" or mount_identity[0] == self.root_identity[0]:
            raise RuntimeError("Refusing host or non-APFS destination")
        current = {"device": attachment["device"], "volumeDevice": attachment["volumeDevice"],
                   "volumeUUID": volume_uuid, "mountDev": mount_identity[0], "mountIno": mount_identity[1]}
        if self.manifest is not None and any(current[key] != self.manifest[key] for key in current):
            raise RuntimeError("Owned mounted identity changed")
        return current

    def create_and_attach(self) -> None:
        self.check_root()
        available = os.statvfs(self.root)
        if available.f_bavail * available.f_frsize < 2 * 1024**3:
            raise RuntimeError("Conservative host headroom unavailable")
        tool(["/usr/sbin/diskutil", "image", "--plist", "create", "blank", "--format", "RAW",
              "--size", "512MiB", "--volumeName", "MacExplorerFixture-" + self.job_id,
              "-fs", "APFS", str(self.image)])
        self.image_identity = identity(self.image)
        self.check_root()
        tool(["/usr/sbin/diskutil", "image", "--plist", "attach", "--nobrowse", "--mountPoint",
              str(self.mount), str(self.image)])
        current = self.validate_mounted()
        self.manifest = {"version": 1, "jobID": self.job_id, "imageBytes": IMAGE_BYTES,
                         "imageDev": self.image_identity[0], "imageIno": self.image_identity[1],
                         "rootDev": self.root_identity[0], "rootIno": self.root_identity[1], **current}
        write_json(self.root / "control" / "manifest.json", self.manifest)

    def fill(self) -> dict:
        self.validate_mounted()
        directory = self.open_mount_directory()
        fd = -1
        total = 0
        failure = None
        stage = "write"
        started = time.monotonic()
        try:
            fd = os.open("owned-filler.bin", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
            value = os.fstat(fd)
            self.filler_identity = (value.st_dev, value.st_ino)
            generator = random.Random(self.job_id)
            while total < IMAGE_BYTES:
                if time.monotonic() - started > 60:
                    raise RuntimeError("Filler timeout; no extra allocation")
                host = os.statvfs(self.root)
                if host.f_bavail * host.f_frsize < 1024**3:
                    raise RuntimeError("Host headroom fell below 1 GiB; image-full case stopped")
                if identity(self.mount, require_owner=False) != (self.manifest["mountDev"], self.manifest["mountIno"]) or os.fstat(fd).st_dev != self.manifest["mountDev"]:
                    raise RuntimeError("Filler destination changed; no fallback")
                block = generator.randbytes(min(1024 * 1024, IMAGE_BYTES - total))
                try:
                    offset = 0
                    while offset < len(block):
                        count = os.write(fd, block[offset:])
                        if count <= 0: raise RuntimeError("Filler made no progress")
                        offset += count; total += count
                except OSError as error:
                    failure = error.errno
                    break
            if failure is None:
                stage = "fsync"
                try: os.fsync(fd)
                except OSError as error: failure = error.errno
            if failure != errno.ENOSPC:
                raise RuntimeError("Filler did not observe ENOSPC within fixed bounds")
            self.validate_mounted()
            return {"errno": failure, "stage": stage, "logicalBytesWritten": total}
        finally:
            if fd >= 0: os.close(fd)
            os.close(directory)

    def remove_filler(self) -> None:
        self.validate_mounted()
        directory = self.open_mount_directory()
        try:
            value = os.stat("owned-filler.bin", dir_fd=directory, follow_symlinks=False)
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or (value.st_dev, value.st_ino) != self.filler_identity:
                raise RuntimeError("Owned filler changed; preserved")
            os.unlink("owned-filler.bin", dir_fd=directory)
            os.fsync(directory)
            self.filler_identity = None
        finally:
            os.close(directory)

    def release_filler_tail(self) -> dict:
        """Free only 8 MiB of this owned filler for a 16 MiB native-copy case."""
        self.validate_mounted()
        directory = self.open_mount_directory()
        fd = -1
        try:
            fd = os.open("owned-filler.bin", os.O_RDWR | os.O_NOFOLLOW, dir_fd=directory)
            value = os.fstat(fd)
            entry = os.stat("owned-filler.bin", dir_fd=directory, follow_symlinks=False)
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size < 8 * 1024**2 or (value.st_dev, value.st_ino) != self.filler_identity or (entry.st_dev, entry.st_ino) != self.filler_identity:
                raise RuntimeError("Owned filler truncation refused")
            os.ftruncate(fd, value.st_size - 8 * 1024**2)
            os.fsync(fd); os.fsync(directory)
            self.validate_mounted()
            available = os.fstatvfs(fd)
            return {"fillerBytesReleased": 8 * 1024**2,
                    "observedAvailableBytes": available.f_bavail * available.f_frsize}
        finally:
            if fd >= 0: os.close(fd)
            os.close(directory)

    def open_mount_directory(self) -> int:
        """Validate the opened anchor BEFORE any child create/truncate/unlink."""
        if self.manifest is None:
            raise RuntimeError("Mounted manifest is unavailable")
        fd = os.open(self.mount, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        value = os.fstat(fd)
        if not stat.S_ISDIR(value.st_mode) or (value.st_dev, value.st_ino) != (self.manifest["mountDev"], self.manifest["mountIno"]):
            os.close(fd)
            raise RuntimeError("Opened mount anchor changed; no child mutation")
        return fd

    def launch_worker(self, phase: str) -> None:
        self.check_root()
        if self.child is not None:
            raise RuntimeError("Concurrent worker refused")
        path = self.root / "control" / f"{phase}.log"
        self.log_paths.append(path)
        self.child_log = path.open("xb")
        env = environment()
        env["MAC_EXPLORER_INTEGRITY_VOLUME_ROOT"] = str(self.root)
        env["MAC_EXPLORER_INTEGRITY_VOLUME_PHASE"] = phase
        self.child = subprocess.Popen([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter", "integrityVolumeQualificationWorker"],
                                      cwd=ROOT, env=env, stdout=self.child_log, stderr=subprocess.STDOUT,
                                      stdin=subprocess.DEVNULL, start_new_session=True)

    def check_log_bound(self) -> None:
        if sum(path.stat().st_size for path in self.log_paths) > LOG_LIMIT:
            raise RuntimeError("Owned worker log ceiling exceeded")

    def wait_worker(self, phase: str, timeout: int = 180) -> dict:
        assert self.child is not None
        deadline = time.monotonic() + timeout
        try:
            while self.child.poll() is None:
                self.check_log_bound()
                if time.monotonic() >= deadline:
                    raise RuntimeError("Owned worker timeout")
                time.sleep(0.1)
            if self.child.returncode != 0:
                raise RuntimeError(f"Owned {phase} worker failed")
            receipt = read_json(self.root / "control" / f"{phase}.json")
            if receipt.get("jobID") != self.job_id or receipt.get("phase") != phase:
                raise RuntimeError("Worker receipt ownership mismatch")
            return receipt
        finally:
            if self.child.poll() is None: stop_owned_child(self.child)
            self.child = None
            if self.child_log: self.child_log.close(); self.child_log = None

    def worker(self, phase: str) -> dict:
        self.launch_worker(phase)
        return self.wait_worker(phase)

    def eject(self) -> None:
        mounted = self.validate_mounted()
        # NO force flag, physical target, mountpoint fallback, or guessed identifier.
        tool(["/usr/sbin/diskutil", "eject", mounted["device"]])
        if self.attachment() is not None:
            raise RuntimeError("Owned image remains attached")

    def detached_case(self) -> dict:
        self.validate_mounted()
        self.launch_worker("prepared-detach")
        deadline = time.monotonic() + 180
        ready = self.root / "control" / "detach-ready.json"
        while not ready.exists():
            self.check_log_bound()
            if self.child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("Prepared-detach barrier unavailable")
            time.sleep(0.1)
        if read_json(ready).get("jobID") != self.job_id:
            raise RuntimeError("Prepared-detach barrier ownership mismatch")
        try:
            self.eject()
        except Exception:
            write_json(self.root / "control" / "detach-abort.json", {"jobID": self.job_id})
            self.wait_worker("prepared-detach")
            raise RuntimeError("Normal owned ejection refused; forced simulation requires separate review")
        write_json(self.root / "control" / "detach-release.json", {"jobID": self.job_id})
        return self.wait_worker("prepared-detach", timeout=max(1, int(deadline - time.monotonic())))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="Run the reviewed owned-image qualification.")
    args = parser.parse_args()
    if not args.execute:
        print("Review only: fixed512MiB RAW APFS image; diskutil image --plist create blank; image --plist attach --nobrowse --mountPoint <owned>; diskutil info -plist <owned>; hdiutil info -plist; bounded owned filler; diskutil eject <verified owned image device>. No force path. Use --execute only after driver review.")
        return 0
    fixture = FixtureVolume()
    report = {"passed": False, "fixtureLabel": fixture.job_id, "imageBytes": IMAGE_BYTES,
              "cases": {}, "forcedDetachExercised": False, "imageRetained": True,
              "limits": ["APFS disk-image behavior only", "No physical disconnect or power-loss qualification"]}
    try:
        fixture.create_and_attach()
        report["cases"]["prepare"] = fixture.worker("prepare")
        report["cases"]["destinationFill"] = fixture.fill()
        report["cases"]["destinationFull"] = fixture.worker("destination-full")
        report["cases"]["nativeCopyHeadroom"] = fixture.release_filler_tail()
        report["cases"]["nativeCopyFull"] = fixture.worker("mid-copy-full")
        fixture.remove_filler()
        report["cases"]["explicitRetry"] = fixture.worker("retry-copy")
        report["cases"]["journalOnImage"] = {"qualification": "not-exercised",
            "reason": "Requires expected-parent guard at journal directory creation; no host fallback permitted"}
        report["cases"]["unavailableDestination"] = fixture.detached_case()
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
        report["failure"] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
    finally:
        if fixture.child is not None:
            stop_owned_child(fixture.child)
            fixture.child = None
        if fixture.child_log: fixture.child_log.close()
        try:
            if fixture.image_identity is not None and fixture.attachment() is not None:
                # Fill cleanup removes only the exact generated filler, never job data.
                if fixture.filler_identity is not None: fixture.remove_filler()
                fixture.eject()
            report["detachedAtEnd"] = fixture.image_identity is None or fixture.attachment() is None
        except Exception:
            report["detachedAtEnd"] = False
            report["cleanupRequiresReview"] = True
        report["imageRetained"] = fixture.image.is_file() and not fixture.image.is_symlink()
        write_json(fixture.root / "report.json", report)
    print(f"Integrity volume qualification {'passed' if report['passed'] else 'FAILED'}: .build/integrity-volumes/{fixture.job_id}/report.json")
    return 0 if report["passed"] and report.get("detachedAtEnd") else 1


if __name__ == "__main__":
    raise SystemExit(main())
