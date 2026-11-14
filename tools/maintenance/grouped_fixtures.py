#!/usr/bin/env python3
"""Prepare a verified archive of old, exactly marked grouped-copy fixtures.

This tool only writes an archive, reports, and a proposed cleanup plan. It never
removes fixtures. The namespace, marker texts, and 12 November cutoff are fixed.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
from datetime import datetime, timezone
from decimal import Decimal
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tarfile
import uuid


REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / ".build"
BASE = BUILD / "grouped-copy-production"
REPORT_PARENT = BUILD / "maintenance"
ARCHIVE_PARENT = BUILD / "retained-evidence"
CUTOFF = datetime(2026, 11, 12, 21, 12, 15, tzinfo=timezone.utc)
CUTOFF_NS = int(CUTOFF.timestamp()) * 1_000_000_000
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
FACTS = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink",
         "st_size", "st_mtime_ns", "st_ctime_ns", "st_flags")
LIBC = ctypes.CDLL(None, use_errno=True)
FLISTXATTR = LIBC.flistxattr
FLISTXATTR.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int)
FLISTXATTR.restype = ctypes.c_ssize_t
FGETXATTR = LIBC.fgetxattr
FGETXATTR.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                     ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int)
FGETXATTR.restype = ctypes.c_ssize_t


class Ineligible(ValueError):
    """One case must remain untouched."""


def digest(stream) -> str:
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1 << 20), b""):
        value.update(block)
    return value.hexdigest()


def facts(info) -> dict:
    return {key[3:]: getattr(info, key) for key in FACTS}


def eligible(info) -> None:
    if (info.st_uid != os.geteuid() or info.st_mtime_ns > CUTOFF_NS
            or info.st_ctime_ns > CUTOFF_NS
            or getattr(info, "st_birthtime_ns", 0) > CUTOFF_NS):
        raise Ineligible("newer, changed, or not owned by this user")
    if info.st_flags:
        raise Ineligible("nondefault file flags need separate metadata review")


def exact_child(value: str, parent: Path, suffix: str = "") -> Path:
    path = Path(value).absolute()
    if path.parent != parent or not path.name or (suffix and not path.name.endswith(suffix)):
        raise ValueError(f"Output must be a direct child of {parent}")
    try:
        path.lstat()
    except FileNotFoundError:
        return path
    raise ValueError(f"Output already exists: {path}")


def fixed_directories() -> None:
    for path in (REPO, BUILD, BASE, REPORT_PARENT, ARCHIVE_PARENT):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or path.resolve() != path:
            raise ValueError(f"Missing or redirected fixed directory: {path}")


def canonical_uuid(value: str) -> bool:
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def marker(parent_fd: int, name: str, expected: bytes) -> dict:
    descriptor = os.open(name, FILE_FLAGS, dir_fd=parent_fd)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        eligible(before)
        if not stat.S_ISREG(before.st_mode) or stream.read(len(expected) + 1) != expected:
            raise Ineligible("unrecognized marker")
        after = os.fstat(stream.fileno())
    if facts(before) != facts(after):
        raise Ineligible("marker changed while read")
    return facts(after)


def case_facts(base_fd: int, name: str) -> dict:
    if not canonical_uuid(name):
        raise Ineligible("unrecognized case name")
    case_fd = os.open(name, DIR_FLAGS, dir_fd=base_fd)
    try:
        case = os.fstat(case_fd)
        eligible(case)
        with os.scandir(case_fd) as listing:
            if {item.name for item in listing} != {".qualification-owner", "fixtures"}:
                raise Ineligible("case has separate retained evidence or unknown entries")
        owner = marker(case_fd, ".qualification-owner",
                       f"MacExplorer grouped production qualification v1\n{name}\n".encode())
        root_fd = os.open("fixtures", DIR_FLAGS, dir_fd=case_fd)
        try:
            root = os.fstat(root_fd)
            eligible(root)
            children = {}
            with os.scandir(root_fd) as listing:
                names = sorted(item.name for item in listing)
            if not names:
                raise Ineligible("empty fixture root")
            for child in names:
                if not child.startswith("copy-") or not canonical_uuid(child[5:]):
                    raise Ineligible("unrecognized fixture child")
                child_fd = os.open(child, DIR_FLAGS, dir_fd=root_fd)
                try:
                    child_info = os.fstat(child_fd)
                    eligible(child_info)
                    child_marker = marker(child_fd, ".owned-grouped-production-fixture",
                                          f"MacExplorer generated grouped production fixture v1\n{child}\n".encode())
                    children[child] = {"directory": facts(child_info), "marker": child_marker}
                finally:
                    os.close(child_fd)
            if facts(root) != facts(os.fstat(root_fd)):
                raise Ineligible("fixture root changed")
        finally:
            os.close(root_fd)
        if facts(case) != facts(os.fstat(case_fd)):
            raise Ineligible("case changed")
        return {"case": facts(case), "owner": owner, "fixtures": facts(root), "children": children}
    finally:
        os.close(case_fd)


def open_cases() -> set[str]:
    """An uncertain open-file observation stops preparation altogether."""
    result = subprocess.run(["/usr/sbin/lsof", "-Fn", "+D", str(BASE)],
                            capture_output=True, timeout=120, check=False)
    if result.stderr or result.returncode not in (0, 1):
        raise ValueError("Cannot establish which generated cases are open")
    names = set()
    for line in result.stdout.decode("utf-8", "surrogateescape").splitlines():
        if not line.startswith("n"):
            continue
        path = Path(line[1:])
        try:
            relative = path.relative_to(BASE)
        except ValueError as exc:
            raise ValueError("Open-file location is outside the fixed namespace") from exc
        if not relative.parts or not canonical_uuid(relative.parts[0]):
            raise ValueError("Open-file case cannot be identified")
        names.add(relative.parts[0])
    if result.returncode == 0 and not names:
        raise ValueError("Open-file result cannot be attributed to cases")
    return names


def xattr_hashes(descriptor: int) -> dict[str, str]:
    def checked(value: int) -> int:
        if value < 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
        return value

    length = checked(FLISTXATTR(descriptor, None, 0, 0))
    if length > 1 << 20:
        raise Ineligible("extended attribute names exceed the review bound")
    if not length:
        return {}
    names_buffer = ctypes.create_string_buffer(length)
    if checked(FLISTXATTR(descriptor, names_buffer, length, 0)) != length:
        raise Ineligible("extended attribute names changed while read")
    names = names_buffer.raw[:length].rstrip(b"\0").split(b"\0")
    if len(names) != len(set(names)):
        raise Ineligible("repeated extended attribute name")
    hashes = {}
    for raw in sorted(names):
        size = checked(FGETXATTR(descriptor, raw, None, 0, 0, 0))
        if size > 1 << 20:
            raise Ineligible("extended attribute value exceeds the review bound")
        buffer = ctypes.create_string_buffer(max(size, 1))
        if checked(FGETXATTR(descriptor, raw, buffer, size, 0, 0)) != size:
            raise Ineligible("extended attribute changed while read")
        hashes[raw.decode("utf-8")] = hashlib.sha256(buffer.raw[:size]).hexdigest()
    return hashes


def snapshot(root: Path) -> dict[str, dict]:
    """Use no-follow directory descriptors for all file-content reads."""
    entries = {}

    def failed(error):
        raise error

    base_fd = os.open(BASE, DIR_FLAGS)
    try:
        case_fd = os.open(root.parent.name, DIR_FLAGS, dir_fd=base_fd)
        try:
            root_fd = os.open("fixtures", DIR_FLAGS, dir_fd=case_fd)
            try:
                for directory, dirs, files, fd in os.fwalk(".", dir_fd=root_fd,
                                                            follow_symlinks=False, onerror=failed):
                    dirs.sort()
                    for name in ["."] + sorted(files) + dirs:
                        path = root / directory if name == "." else root / directory / name
                        relative = path.relative_to(BUILD).as_posix()
                        if relative in entries:
                            continue
                        before = os.fstat(fd) if name == "." else os.stat(name, dir_fd=fd, follow_symlinks=False)
                        eligible(before)
                        row = facts(before)
                        if stat.S_ISREG(before.st_mode):
                            opened = os.open(name, FILE_FLAGS, dir_fd=fd)
                            with os.fdopen(opened, "rb") as stream:
                                if facts(os.fstat(stream.fileno())) != row:
                                    raise Ineligible("file changed before read")
                                row["sha256"] = digest(stream)
                                row["xattrs"] = xattr_hashes(stream.fileno())
                                after = os.fstat(stream.fileno())
                            row["type"] = "file"
                        elif stat.S_ISDIR(before.st_mode):
                            opened = fd if name == "." else os.open(name, DIR_FLAGS, dir_fd=fd)
                            try:
                                row["xattrs"] = xattr_hashes(opened)
                                after = os.fstat(opened)
                            finally:
                                if opened != fd:
                                    os.close(opened)
                            row["type"] = "directory"
                        else:
                            # Generated symbolic links may refer outside this fixture.
                            # Leave their entire case in place without reading them.
                            raise Ineligible("symbolic link or special fixture entry")
                        if facts(after) != facts(before):
                            raise Ineligible("fixture changed while read")
                        entries[relative] = row
            finally:
                os.close(root_fd)
        finally:
            os.close(case_fd)
    finally:
        os.close(base_fd)
    return entries


def verify_archive(archive: Path, manifest: dict[str, dict]) -> int:
    real, apple = set(), set()
    with tarfile.open(archive, "r|gz") as saved:
        for member in saved:
            name = member.name.rstrip("/")
            row = manifest.get(name)
            if row is None:
                path = PurePosixPath(name)
                target = str(path.with_name(path.name[2:])) if path.name.startswith("._") else ""
                if target not in manifest or target in apple or not member.isfile() or not 0 < member.size <= 1 << 20:
                    raise ValueError("Unexpected or repeated archive metadata")
                stream = saved.extractfile(member)
                if stream is None or stream.read(8) != bytes.fromhex("0005160700020000"):
                    raise ValueError("Unreadable AppleDouble metadata")
                while stream.read(1 << 20):
                    pass
                apple.add(target)
            else:
                if name in real or member.mode != stat.S_IMODE(row["mode"]) or member.uid != row["uid"] or member.gid != row["gid"]:
                    raise ValueError("Repeated or mismatched archive member")
                saved_mtime = Decimal(member.pax_headers.get("mtime", str(int(member.mtime))))
                if saved_mtime != Decimal(row["mtime_ns"]) / 1_000_000_000:
                    raise ValueError("Archive timestamp differs from source")
                attrs = {key[len("LIBARCHIVE.xattr."):]: hashlib.sha256(
                    base64.b64decode(value + "=" * (-len(value) % 4), validate=True)).hexdigest()
                         for key, value in member.pax_headers.items() if key.startswith("LIBARCHIVE.xattr.")}
                if attrs != row["xattrs"]:
                    raise ValueError("Archive extended attributes differ from source")
                if row["type"] == "file":
                    if member.islnk():
                        target = manifest.get(member.linkname)
                        if not target or target["type"] != "file" or (target["dev"], target["ino"], target["sha256"]) != (row["dev"], row["ino"], row["sha256"]):
                            raise ValueError("Archive hard link differs from source")
                    else:
                        stream = saved.extractfile(member)
                        if not member.isfile() or member.size != row["size"] or stream is None or digest(stream) != row["sha256"]:
                            raise ValueError("Archive file differs from source")
                elif row["type"] == "directory":
                    if not member.isdir():
                        raise ValueError("Archive directory differs from source")
                else:
                    raise ValueError("Unexpected archive source type")
                real.add(name)
            saved.members.clear()
    if real != set(manifest) or apple != real:
        raise ValueError("Archive is missing fixture data or AppleDouble metadata")
    return len(apple)


def prepare(report: Path, archive: Path) -> None:
    fixed_directories()
    report = exact_child(str(report), REPORT_PARENT)
    archive = exact_child(str(archive), ARCHIVE_PARENT, ".tar.gz")
    report.mkdir(mode=0o700)
    initial_live = open_cases()
    selected, selected_entries, manifest, excluded = {}, {}, {}, []
    base_fd = os.open(BASE, DIR_FLAGS)
    try:
        with os.scandir(base_fd) as listing:
            names = sorted(item.name for item in listing)
        for name in names:
            if name in initial_live:
                excluded.append({"case": name, "reason": "open"})
                continue
            try:
                before = case_facts(base_fd, name)
                root = BASE / name / "fixtures"
                entries = snapshot(root)
            except (Ineligible, OSError, ValueError) as exc:
                reason = str(exc) if isinstance(exc, Ineligible) else "inaccessible or redirected"
                excluded.append({"case": name, "reason": reason})
                continue
            selected[name] = before
            selected_entries[name] = entries
            manifest.update(entries)
    finally:
        os.close(base_fd)
    (report / "excluded-cases.json").write_text(json.dumps(excluded, indent=2) + "\n")
    if not selected:
        raise ValueError("No old, closed, exactly marked fixture roots are eligible")
    roots = [BASE / name / "fixtures" for name in sorted(selected)]
    with gzip.open(report / "manifest.json.gz", "wt") as stream:
        json.dump(manifest, stream, sort_keys=True, separators=(",", ":"))
    listing = report / "archive-inputs.txt"
    listing.write_text("".join(root.relative_to(BUILD).as_posix() + "\n" for root in roots))
    with archive.open("xb") as stream:
        os.fchmod(stream.fileno(), 0o600)
        result = subprocess.run(["/usr/bin/tar", "--format", "pax", "--acls", "--xattrs",
                                 "--mac-metadata", "-czf", "-", "-C", str(BUILD), "-T", str(listing)],
                                stdout=stream, stderr=subprocess.PIPE, timeout=600, check=False)
        stream.flush()
        os.fsync(stream.fileno())
    (report / "archive-stderr.txt").write_bytes(result.stderr)
    if result.returncode or result.stderr:
        raise ValueError("Archive creation failed; no cleanup plan was written")
    metadata_count = verify_archive(archive, manifest)
    if open_cases() & set(selected):
        raise ValueError("A selected fixture became open; no cleanup plan was written")
    base_fd = os.open(BASE, DIR_FLAGS)
    try:
        for name, before in selected.items():
            if case_facts(base_fd, name) != before or snapshot(BASE / name / "fixtures") != selected_entries[name]:
                raise ValueError("Source changed after archiving; no cleanup plan was written")
    finally:
        os.close(base_fd)
    with archive.open("rb") as stream:
        archive_sha = digest(stream)
    plan = {"repository": str(REPO), "ownerRequest": "Owner-authorized historical grouped fixture consolidation",
            "entries": [{"path": root.relative_to(BUILD).as_posix(), "device": selected[root.parent.name]["fixtures"]["dev"],
                         "inode": selected[root.parent.name]["fixtures"]["ino"],
                         "reason": "old exactly marked fixtures; content and archive metadata read back"}
                        for root in roots]}
    (report / "cleanup-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    summary = {"prepared": True, "cutoffUTC": CUTOFF.isoformat(), "roots": len(roots), "entries": len(manifest),
               "regularFiles": sum(row["type"] == "file" for row in manifest.values()),
               "logicalBytes": sum(row["size"] for row in manifest.values() if row["type"] == "file"),
               "archive": str(archive), "archiveBytes": archive.stat().st_size, "archiveSHA256": archive_sha,
               "verifiedAppleMetadataEntries": metadata_count, "excludedCases": len(excluded), "deleted": False}
    (report / "prepared.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-root", required=True, type=Path, help="New direct child of .build/maintenance")
    parser.add_argument("--archive", required=True, type=Path, help="New .tar.gz under .build/retained-evidence")
    args = parser.parse_args()
    prepare(args.report_root, args.archive)
