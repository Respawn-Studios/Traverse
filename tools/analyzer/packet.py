#!/usr/bin/env python3
"""Batch06 generated-fixture admission, independent oracle and paired runner.

No cleanup path, real-root scan or production application integration. Failed
cases remain on disk. The scanner never reads this generator's manifest.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import resource
import re
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
BASE = REPO / ".build/b06-analyzer"
LIMITS = {"entries": 220_000, "logical": 1 << 30, "allocated": 2 << 30}
FLOOR = 4 << 30
# Public Darwin fcntl.h, verified in the active SDK; Python omits this flag.
NOFOLLOW_ANY = 0x20000000


def directory_fd(path: Path) -> int:
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | NOFOLLOW_ANY)


def owned_path(path: Path) -> None:
    if not path.is_absolute() or ".." in path.parts or path == BASE or BASE not in path.parents:
        raise ValueError("Path is outside generated Batch06 ownership")


def create_directory(path: Path) -> None:
    owned_path(path)
    parent = directory_fd(path.parent)
    try:
        os.mkdir(path.name, mode=0o700, dir_fd=parent)
    finally:
        os.close(parent)


def create_file(path: Path):
    owned_path(path)
    parent = directory_fd(path.parent)
    try:
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        return os.fdopen(fd, "wb", buffering=0)
    finally:
        os.close(parent)


def read_owned(path: Path, maximum: int) -> bytes:
    owned_path(path)
    parent = directory_fd(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(fd, "rb") as source:
        observed = os.fstat(source.fileno())
        if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1 or observed.st_size > maximum:
            raise ValueError("Untrusted generated control file")
        result = source.read(maximum + 1)
        if len(result) > maximum: raise ValueError("Generated control file grew")
        return result


def put(path: Path, value: object) -> None:
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > 16 << 20:
        raise ValueError("Oversized generated evidence")
    with create_file(path) as output:
        output.write(data)


def anchored(path: Path) -> None:
    if not path.is_absolute() or path != path.absolute() or ".." in path.parts:
        raise ValueError("Noncanonical generated path")
    cursor = Path(path.anchor)
    for part in path.parts[1:]:
        cursor /= part
        observed = cursor.lstat()
        if not stat.S_ISDIR(observed.st_mode):
            raise ValueError("Redirected generated ancestor")


def identity(path: Path) -> tuple[int, int]:
    observed = path.lstat()
    if not stat.S_ISDIR(observed.st_mode):
        raise ValueError("Expected owned directory")
    return observed.st_dev, observed.st_ino


def inventory(root: Path) -> dict:
    """Metadata only; counts every namespace edge, including hard-link edges."""
    entries = logical = allocated = 0
    pending = [(root, identity(root))]
    while pending:
        folder, expected = pending.pop()
        fd = directory_fd(folder)
        try:
            initial = os.fstat(fd)
            if (initial.st_dev, initial.st_ino) != expected: raise ValueError("Budget directory changed")
            with os.scandir(fd) as children:
                for child in children:
                    observed = child.stat(follow_symlinks=False)
                    entries += 1
                    allocated += observed.st_blocks * 512
                    if stat.S_ISDIR(observed.st_mode):
                        pending.append((folder / child.name, (observed.st_dev, observed.st_ino)))
                    elif stat.S_ISREG(observed.st_mode):
                        logical += observed.st_size
                    if entries > LIMITS["entries"] or logical > LIMITS["logical"] or allocated > LIMITS["allocated"]:
                        raise ValueError("Batch06 aggregate quota exceeded; evidence preserved")
        finally:
            os.close(fd)
    return dict(entries=entries, logical=logical, allocated=allocated)


def budget(projected_entries: int = 0, projected_logical: int = 0, projected_allocated: int = 0) -> dict:
    anchored(BASE)
    totals = inventory(BASE)
    for key, addition in zip(LIMITS, [projected_entries, projected_logical, projected_allocated]):
        if totals[key] + addition > LIMITS[key]:
            raise ValueError("Batch06 aggregate admission refused: " + key)
    available = os.statvfs(BASE)
    if available.f_bavail * available.f_frsize < FLOOR + projected_allocated:
        raise ValueError("Insufficient remaining-volume headroom")
    return totals


def admit(run: str | None) -> Path:
    if run is None:
        for path in [REPO / ".build", BASE]:
            path.mkdir(mode=0o700, exist_ok=True)
            anchored(path)
        root = BASE / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:10])
        create_directory(root)
        for name in ["fixtures", "manifests", "evidence"]: create_directory(root / name)
        dev, ino = identity(root)
        put(root / "owner.json", dict(schema=1, run=root.name, dev=dev, ino=ino, limits=LIMITS, created_ns=time.time_ns()))
        return root
    root = Path(run).absolute()
    if root.parent != BASE or not root.name or root.resolve() != root:
        raise ValueError("Only an existing marked Batch06 run is accepted")
    anchored(root)
    owner = json.loads(read_owned(root / "owner.json", 4096))
    if owner.get("schema") != 1 or owner.get("run") != root.name or owner.get("limits") != LIMITS:
        raise ValueError("Unrecognized Batch06 ownership record")
    if identity(root) != (owner.get("dev"), owner.get("ino")):
        raise ValueError("Batch06 root was replaced")
    for name in ["fixtures", "manifests", "evidence"]:
        fd = directory_fd(root / name); os.close(fd)
    return root


def corpus_root(run: Path, name: str) -> Path:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", name):
        raise ValueError("Corpus must be one generated component")
    admit(str(run))
    root = run / "fixtures" / name
    fd = directory_fd(root)
    try: observed = os.fstat(fd)
    finally: os.close(fd)
    receipt = json.loads(read_owned(run / "manifests" / (name + ".json"), 65536))
    if receipt.get("root") != str(root) or (receipt.get("dev"), receipt.get("ino")) != (observed.st_dev, observed.st_ino):
        raise ValueError("Generated corpus identity was replaced")
    return root


class Generator:
    def __init__(self, run: Path, corpus: str, projected: tuple[int, int, int]):
        budget(*projected)
        self.root = run / "fixtures" / corpus
        create_directory(self.root)
        self.original = identity(self.root)
        import io
        self.manifest = io.TextIOWrapper(create_file(run / "manifests" / (corpus + ".ndjson")), encoding="utf-8")
        self.count = 0
        self.logical = 0

    def record(self, relative: bytes, expected: str, data_length: int | None = None) -> None:
        parent, _, leaf = relative.rpartition(b"/")
        fd = directory_fd(self.root / os.fsdecode(parent))
        try: observed = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        finally: os.close(fd)
        self.count += 1
        if expected == "regular":
            self.logical += int(data_length)
        record = dict(relative_b64=base64.b64encode(relative).decode(), type=expected,
                      dev=str(observed.st_dev), ino=str(observed.st_ino),
                      data_logical=str(data_length) if data_length is not None else None)
        self.manifest.write(json.dumps(record, separators=(",", ":")) + "\n")
        if self.count % 5000 == 0:
            self.manifest.flush()
            if identity(self.root) != self.original:
                raise ValueError("Generated corpus root replaced")
            budget(5000, 1 << 20, 32 << 20)

    def directory(self, name: bytes) -> None:
        create_directory(self.root / os.fsdecode(name))
        self.record(name, "directory")

    def file(self, name: bytes, body: bytes = b"", logical: int | None = None) -> None:
        path = self.root / os.fsdecode(name)
        with create_file(path) as output:
            if body:
                output.write(body)
            if logical is not None:
                output.truncate(logical)
        self.record(name, "regular", len(body) if logical is None else logical)

    def finish(self) -> dict:
        self.manifest.close()
        result = dict(root=str(self.root), dev=self.original[0], ino=self.original[1],
                      entries=self.count, logical=self.logical, budget=budget())
        put(self.root.parent.parent / "manifests" / (self.root.name + ".json"), result)
        return result


def generate(run: Path, corpus: str) -> dict:
    if corpus in ("smoke", "wide", "mixed"):
        target = 10_000 if corpus == "smoke" else 100_000
        g = Generator(run, corpus, (target + 20, target * 300, target * 768))
        count = 10 if corpus == "smoke" else 100
        parents = []
        for index in range(count):
            name = f"block-{index:03d}".encode()
            g.directory(name); parents.append(name)
        if corpus == "mixed":
            deep = b"deep"
            for depth in range(64):
                g.directory(deep); parents.append(deep)
                deep += b"/d"
        for index in range(target - len(parents)):
            parent = parents[index % len(parents)]
            prefix = "Café_資料_" if corpus == "mixed" and index % 17 == 0 else "item-"
            name = parent + b"/" + (prefix + f"{index:06d}.txt").encode()
            g.file(name, b"x" * 64 if index % 16 == 0 else b"")
        return g.finish()
    if corpus in ("edges", "edges-v2"):
        g = Generator(run, corpus, (300, 400 << 20, 96 << 20))
        for directory in [b"a", b"b", b"Example.app", b"Example.app/Contents", b"selected", b"outside-selected"]:
            g.directory(directory)
        for name in [b"zero", b".hidden", "emoji-🧪.txt".encode(), b"Example.app/Contents/known"]:
            g.file(name)
        try:
            g.file(b"raw-\xff-name")
        except OSError as error:
            import errno
            if error.errno != errno.EILSEQ:
                raise
            put(run / "evidence" / (corpus + "-non-utf8-fixture.json"), {"supported": False, "errno": error.errno,
                "reason": "APFS rejects non-UTF8 names; raw-byte parser controls remain synthetic"})
        g.file(b"a/original", b"owned synthetic data")
        for name in [b"a/link", b"b/shared", b"selected/inside", b"outside-selected/outside"]:
            os.link(os.fsencode(g.root) + b"/a/original", os.fsencode(g.root) + b"/" + name)
            g.record(name, "regular", len(b"owned synthetic data"))
        for name, target in [(b"loop", b"."), (b"outside", b"../../"), (b"broken", b"absent")]:
            os.symlink(target, os.fsencode(g.root) + b"/" + name); g.record(name, "symlink")
        for index in range(4):
            g.file(f"large-{index}".encode(), bytes([65 + index]) * (8 << 20))
        g.file(b"sparse", logical=256 << 20)
        g.file(b"forked", b"data-fork")
        libc = ctypes.CDLL(None, use_errno=True)
        set_attribute = libc.setxattr
        set_attribute.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                                  ctypes.c_uint32, ctypes.c_int]
        set_attribute.restype = ctypes.c_int
        resource_fork = b"generated resource metadata fixture"
        if set_attribute(os.fsencode(g.root / "forked"), b"com.apple.ResourceFork", resource_fork,
                         len(resource_fork), 0, 2) != 0:
            raise OSError(ctypes.get_errno(), "Generated resource fork creation failed")
        # Only the generator may clone generated payloads. No scanner body access.
        clone = libc.clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
        clone.restype = ctypes.c_int
        for name in [b"clone-full", b"clone-diverged"]:
            if clone(os.fsencode(g.root / "large-0"), os.fsencode(g.root) + b"/" + name, 0) != 0:
                raise OSError(ctypes.get_errno(), "Generated clone creation failed")
            g.record(name, "regular", 8 << 20)
        with open(g.root / "clone-diverged", "r+b", buffering=0) as output:
            output.seek(4096); output.write(b"different generated extent")
        return g.finish()
    raise ValueError("Unknown fixed corpus")


def oracle(run: Path, corpus: str) -> dict:
    root = corpus_root(run, corpus)
    expected = {}
    manifest = read_owned(run / "manifests" / (corpus + ".ndjson"), 128 << 20)
    for line in manifest.splitlines():
        item = json.loads(line); key = item["relative_b64"]
        if key in expected:
            raise ValueError("Duplicate generator manifest edge")
        expected[key] = item
    seen = {}; objects = {}; data_total = 0
    pending = [(root, b"", identity(root))]
    while pending:
        directory, parent, expected_directory = pending.pop()
        fd = directory_fd(directory)
        try:
            observed_directory = os.fstat(fd)
            if (observed_directory.st_dev, observed_directory.st_ino) != expected_directory:
                raise ValueError("Independent oracle directory changed")
            with os.scandir(fd) as children:
              for entry in children:
                name = os.fsencode(entry.name)
                relative = parent + b"/" + name if parent else name
                observed = entry.stat(follow_symlinks=False)
                kind = ("directory" if stat.S_ISDIR(observed.st_mode) else "regular" if stat.S_ISREG(observed.st_mode)
                        else "symlink" if stat.S_ISLNK(observed.st_mode) else "other")
                key = base64.b64encode(relative).decode()
                item = dict(relative_b64=key, type=kind, dev=str(observed.st_dev), ino=str(observed.st_ino),
                            data_logical=str(observed.st_size) if kind == "regular" else None)
                if expected.get(key) != item:
                    raise ValueError("Fixture no longer agrees with independent generator manifest")
                seen[key] = item
                if kind == "directory":
                    pending.append((directory / entry.name, relative, (observed.st_dev, observed.st_ino)))
                elif kind == "regular":
                    data_total += observed.st_size
                    objects[(observed.st_dev, observed.st_ino)] = observed.st_size
        finally:
            os.close(fd)
    if seen != expected:
        raise ValueError("Missing manifest edge")
    return dict(entries=len(seen), objects=len(objects), data_logical=data_total,
                object_data_logical=sum(objects.values()), manifest_sha256=hashlib.sha256(manifest).hexdigest())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["init", "generate", "oracle", "budget"])
    parser.add_argument("--run")
    parser.add_argument("--corpus", choices=["smoke", "wide", "mixed", "edges", "edges-v2"])
    args = parser.parse_args()
    if args.action != "init" and args.run is None:
        parser.error("existing --run is required")
    root = admit(args.run)
    with (BASE / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == "init": result = dict(run=str(root), budget=budget())
        elif args.action == "budget": result = budget()
        elif args.action == "generate": result = generate(root, args.corpus)
        else: result = oracle(root, args.corpus)
        print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
