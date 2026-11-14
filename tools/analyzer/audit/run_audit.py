#!/usr/bin/env python3
"""Untimed, generated-fixture-only dyld read audit; never inject into the app.

Retains aggregate receipts, not hooked paths or body bytes. Positive controls
read only a newly generated sentinel; scanner negative controls use that same
immutable owned fixture. No cleanup, privilege, global environment or OS changes.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
SOURCE = REPO / "tools/analyzer/audit"
OUTPUT = REPO / ".build/b06-toolchain/audit"
KEYS = ("regular_opens", "read_calls", "read_bytes", "pread_calls", "pread_bytes",
        "readv_calls", "readv_bytes", "mmap_calls", "mmap_bytes", "io_failures", "classification_failures")


def write_json(path: Path, value: object) -> None:
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")


def environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items()
            if not key.startswith("DYLD_") and not key.startswith("B06_AUDIT_")}


def build() -> tuple[Path, Path]:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in ("tmp", "module-cache"):
        (OUTPUT / name).mkdir(exist_ok=True)
    # Refuse redirected build outputs before compiler writes.
    if OUTPUT.resolve() != OUTPUT or any(not stat.S_ISDIR(path.lstat().st_mode)
        for path in [REPO / ".build", REPO / ".build/b06-toolchain", OUTPUT]):
        raise ValueError("Redirected audit build directory")
    env = environment()
    env["CLANG_MODULE_CACHE_PATH"] = str(OUTPUT / "module-cache")
    env["TMPDIR"] = str(OUTPUT / "tmp")
    library, positive = OUTPUT / "libB06FileReadAudit.dylib", OUTPUT / "b06-audit-positive"
    for filename, destination, extra in [("FileReadAudit.c", library, ["-dynamiclib"]),
                                         ("PositiveControl.c", positive, [])]:
        subprocess.run(["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        *extra, str(SOURCE / filename), "-o", str(destination)],
                       cwd=REPO, env=env, check=True, capture_output=True, timeout=60)
    return library, positive


def load_packet():
    spec = importlib.util.spec_from_file_location("b06_packet", REPO / "tools/analyzer/packet.py")
    packet = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packet)
    return packet


def validate_fixture(packet, run: Path, root: Path, expected: tuple[int, int]) -> None:
    packet.admit(str(run))
    packet.anchored(root)
    if root.parent != run / "fixtures" or packet.identity(root) != expected:
        raise ValueError("Audit fixture identity changed")
    observed = (root / "sentinel").lstat()
    if not stat.S_ISREG(observed.st_mode) or observed.st_size != 4096 or observed.st_nlink != 1:
        raise ValueError("Audit sentinel metadata changed")


def invoke(packet, run: Path, scope: Path, identity: tuple[int, int], library: Path,
           label: str, command: list[str], expected: dict[str, int], evidence: Path) -> dict:
    validate_fixture(packet, run, scope, identity)
    env = environment()
    env.update(DYLD_INSERT_LIBRARIES=str(library), B06_AUDIT_ROOT=str(scope),
               B06_AUDIT_DEV=str(identity[0]), B06_AUDIT_INO=str(identity[1]))
    process = subprocess.run(command, cwd=REPO, env=env, capture_output=True, timeout=60)
    # Neither non-receipt stderr nor scanner namespace records are persisted.
    receipts = []
    other_lines = 0
    for line in process.stderr.splitlines():
        try:
            item = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            other_lines += 1
            continue
        if isinstance(item, dict) and item.get("b06_file_read_audit") == 1:
            receipts.append(item)
        else:
            other_lines += 1
    result = dict(schema=1, label=label, exit_code=process.returncode,
                  receipt_count=len(receipts), other_stderr_line_count=other_lines,
                  expected=expected, passed=False)
    if len(receipts) == 1:
        receipt = receipts[0]
        # Strict aggregate-only shape rejects accidental path/content additions.
        if set(receipt) == {"b06_file_read_audit", "configured", *KEYS}:
            result["receipt"] = receipt
            result["passed"] = process.returncode == 0 and receipt["configured"] == 1 and all(
                receipt.get(key) == count for key, count in expected.items())
    write_json(evidence / (label + ".json"), result)
    validate_fixture(packet, run, scope, identity)
    if not result["passed"]:
        raise ValueError("Audit control failed: " + label + "; aggregate evidence preserved")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, help="Existing standalone generated-fixture Swift scanner")
    parser.add_argument("--rust", type=Path, help="Existing standalone generated-fixture Rust scanner")
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    library, positive = build()
    if args.build_only:
        print("Audit dylib and positive control built in repository-local audit output")
        return
    if args.swift is None:
        parser.error("--swift is required for scanner negative qualification")
    binaries = [("swift", args.swift)] + ([("rust", args.rust)] if args.rust else [])
    for _, binary in binaries:
        binary = binary.absolute()
        if not binary.is_file() or binary.resolve() != binary or not binary.is_relative_to(REPO / ".build"):
            raise ValueError("Only existing repository-local standalone scanner binaries are accepted")
        if any(part.endswith(".app") for part in binary.parts):
            raise ValueError("Never inject audit into an application bundle")
        if binary.name != "b06-" + _ + "-scanner":
            raise ValueError("Only explicitly named standalone analyzer scanners are accepted")
    packet = load_packet()
    run = packet.admit(None)
    root = run / "fixtures/audit-scope"
    outside = run / "fixtures/audit-scope-other"
    # Share packet admission's lock only while allocating owned fixture bytes;
    # scanner execution and these audit artifacts remain outside timed runs.
    with (packet.BASE / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        packet.budget(16, 8192, 65536)
        for folder in (root, outside):
            folder.mkdir(mode=0o700)
            descriptor = os.open(folder / "sentinel", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                body = b"A" * 4096  # Explicitly generated positive-control bytes only.
                if os.write(descriptor, body) != len(body):
                    raise ValueError("Generated sentinel publication incomplete")
            finally:
                os.close(descriptor)
    identity = packet.identity(root)
    evidence = run / "evidence/audit"
    evidence.mkdir(mode=0o700)
    controls = []
    zero = dict.fromkeys(KEYS, 0)
    positive_expected = dict(zero, regular_opens=2, read_calls=1, read_bytes=4, pread_calls=1,
                             pread_bytes=4, readv_calls=1, readv_bytes=4, mmap_calls=1, mmap_bytes=4096)
    for mode in ("public", "nocancel"):
        controls.append(invoke(packet, run, root, identity, library, "positive-" + mode,
                               [str(positive), mode, str(root)], positive_expected, evidence))
    controls.append(invoke(packet, run, root, identity, library, "positive-threaded",
                           [str(positive), "threads", str(root)],
                           dict(zero, regular_opens=400, read_calls=400, read_bytes=400), evidence))
    controls.append(invoke(packet, run, root, identity, library, "positive-failed-read",
                           [str(positive), "failure", str(root)],
                           dict(zero, regular_opens=1, read_calls=1, io_failures=1), evidence))
    controls.append(invoke(packet, run, root, identity, library, "negative-directory",
                           [str(positive), "metadata", str(root)], zero, evidence))
    controls.append(invoke(packet, run, root, identity, library, "negative-prefix-sibling",
                           [str(positive), "public", str(outside)], zero, evidence))
    for label, binary in binaries:
        for lane in (["bulk", "foundation"] if label == "swift" else ["rust"]):
            command = [str(binary.absolute()), "--lane", lane, "--root", str(root),
                       "--expected-dev", str(identity[0]), "--expected-ino", str(identity[1]),
                       "--session", "b06-audit-" + label + "-" + lane, "--summary-only"]
            controls.append(invoke(packet, run, root, identity, library, "negative-scanner-" + lane,
                                   command, zero, evidence))
    exports = subprocess.run(["xcrun", "nm", "-gU", "/usr/lib/system/libsystem_kernel.dylib"],
                             cwd=REPO, env=environment(), capture_output=True, check=True, timeout=30)
    prefixes = ("_open", "_openat", "_read", "_pread", "_readv", "_mmap", "___open", "___read", "___pread", "___mmap")
    symbols = sorted(line.split()[-1] for line in exports.stdout.decode().splitlines()
                     if line.split() and line.split()[-1].startswith(prefixes))
    write_json(evidence / "symbol-inventory.json", dict(schema=1, symbols=symbols,
               source="qualified-host-libsystem-kernel-export-table", all_exports_intercepted=False))
    summary = dict(schema=1, passed=True, untimed=True, controlled_generated_fixture=True,
                   coverage="dyld-public-and-known-nocancel-alias-entrypoints-only",
                   control_count=len(controls), labels=[control["label"] for control in controls],
                   artifact_sha256={"audit": hashlib.sha256(library.read_bytes()).hexdigest(),
                                    "positive": hashlib.sha256(positive.read_bytes()).hexdigest(),
                                    **{label + "_scanner": hashlib.sha256(binary.read_bytes()).hexdigest() for label, binary in binaries}},
                   source_sha256={name: hashlib.sha256((SOURCE / name).read_bytes()).hexdigest()
                                  for name in ("FileReadAudit.c", "PositiveControl.c", "run_audit.py")},
                   not_proven=["Direct syscalls or uninstrumented/private entrypoints", "File-descriptor race freedom",
                               "Kernel-wide or other-process access", "Reads before constructor or after final receipt",
                               "Nonregular files, data copied without intercepted calls, or page-fault bytes actually consumed"])
    write_json(evidence / "summary.json", summary)
    print(json.dumps({"passed": True, "controls": len(controls), "evidence": str(evidence.relative_to(REPO))}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Audit qualification failed; generated evidence preserved: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
