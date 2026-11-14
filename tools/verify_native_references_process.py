#!/usr/bin/env python3
"""B07.2 generated-only native references, crash/failure and frozen-v1 refusal."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment

BASE = ROOT / ".build/b07-native-references"
MIB = 1024**2


def write(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf8") as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write("\n")
    path.chmod(0o600)


def observed(root: Path) -> tuple[int, int, int]:
    stack, size, count, logs = [root], 0, 0, 0
    while stack:
        path = stack.pop()
        info = path.lstat()
        charge = max(info.st_size, info.st_blocks * 512)
        size += charge; count += 1
        if stat.S_ISDIR(info.st_mode):
            stack.extend(path.iterdir())
        elif path.suffix in (".log", ".json"):
            logs += charge
    return size, count, logs


def usage() -> dict:
    if BASE.resolve() != BASE:
        raise RuntimeError("Redirected packet")
    result = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, logs=0)
    for case in BASE.iterdir():
        if case.name == ".budget.lock":
            continue
        if not case.is_dir() or case.is_symlink():
            raise RuntimeError("Unexpected generated namespace")
        reservation = json.loads((case / "reservation.json").read_bytes())
        size, entries, logs = observed(case)
        if size > reservation["bytes"] or entries > reservation["entries"] or reservation["bytes"] > 64 * MIB:
            raise RuntimeError("Preserved case exceeds its reservation")
        if os.path.lexists(case / "internal-root.json"):
            # Preserve old external evidence at full reservation cost without
            # inspecting or replaying the retired side of the case.
            size, entries = reservation["bytes"], reservation["entries"]
        result["bytes"] += size; result["entries"] += entries; result["logs"] += logs
        result["reservedBytes"] += reservation["bytes"]; result["reservedEntries"] += reservation["entries"]
    if result["reservedBytes"] > 512 * MIB or result["reservedEntries"] > 3584 or result["logs"] > 16 * MIB:
        raise RuntimeError("Approved packet exhausted")
    return result


def admit(size: int = 8 * MIB, entries: int = 32) -> Path:
    BASE.mkdir(mode=0o700, exist_ok=True)
    with (BASE / ".budget.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = usage()
        if current["reservedBytes"] + size > 512 * MIB or current["reservedEntries"] + entries > 3584:
            raise RuntimeError("Insufficient unreserved headroom")
        case = BASE / str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        write(case / "reservation.json", {"bytes": size, "entries": entries})
        return case


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", action="append", choices=["referenceRows", "referenceCommit", "accessFenceRows", "accessFenceCommit",
        "accessPurgeRows", "accessPurgeCommit", "upgradeRows", "upgradeCommit", "faultReferenceWrite", "faultReferenceSync",
        "faultAccessFence", "faultAccessPurge"])
    args = parser.parse_args()
    report_root = admit(size=2 * MIB, entries=8)
    binary = ROOT / ".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"
    sources = sorted((ROOT / "Packages/ExplorerKit/Sources/FileMemory").glob("*.swift"))
    sources += sorted((ROOT / "Packages/ExplorerKit/Tests/FileMemoryTests").glob("*.swift"))
    sources += [Path(__file__).resolve()]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    report = {"passed": False, "sourceHashes": hashes, "binarySHA256": binary_hash, "before": usage(), "cases": []}
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    helper = developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    env = environment()
    platform = developer / "Platforms/MacOSX.platform/Developer"
    env.update(DYLD_FRAMEWORK_PATH=str(platform / "Library/Frameworks"), DYLD_LIBRARY_PATH=str(platform / "usr/lib"),
               MAC_EXPLORER_B07_NATIVE_PACKET="1")

    def worker(case: Path, scenario: str, phase: str) -> dict:
        if os.path.lexists(case / "internal-root.json"):
            raise RuntimeError("Retired external-root case cannot be replayed")
        if hashlib.sha256(binary.read_bytes()).hexdigest() != binary_hash or any(
                hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != value for path, value in hashes.items()):
            raise RuntimeError("Frozen inputs changed")
        child_env = env | dict(MAC_EXPLORER_B07_REFERENCE_ROOT=str(case), MAC_EXPLORER_B07_REFERENCE_SCENARIO=scenario,
                               MAC_EXPLORER_B07_REFERENCE_PHASE=phase)
        log = case / (phase + ".log")
        with log.open("xb") as output:
            process = subprocess.run([str(helper), "--test-bundle-path", str(binary), "--testing-library", "swift-testing",
                                      "--filter", "b07ReferenceProcessWorker"], cwd=ROOT, env=child_env,
                                     stdout=output, stderr=subprocess.STDOUT, timeout=90, check=False)
        value = json.loads((case / (phase + ".json")).read_bytes())
        if process.returncode != (86 if phase == "crash" else 0) or value["phase"] != phase:
            raise RuntimeError(f"Failed {scenario}/{phase}; retained {log.relative_to(ROOT)}")
        if phase == "crash" and (value.get("exit") != "86" or scenario == "referenceRows" and value.get("hot") != "true"):
            raise RuntimeError("Crash/hot boundary not exercised")
        if phase.startswith("inspect") and value.get("unchanged") != "true":
            raise RuntimeError("Passive inspection changed catalog")
        usage()
        return {"receipt": value, "returnCode": process.returncode, "log": str(log.relative_to(ROOT))}

    scenarios = ["referenceRows", "referenceCommit", "accessFenceRows", "accessFenceCommit", "accessPurgeRows", "accessPurgeCommit",
                 "upgradeRows", "upgradeCommit", "faultReferenceWrite", "faultReferenceSync", "faultAccessFence", "faultAccessPurge"]
    try:
        for scenario in scenarios:
            if args.scenario and scenario not in args.scenario:
                continue
            case = admit()
            row = {"scenario": scenario, "root": str(case.relative_to(ROOT)), "passed": False, "actions": []}
            report["cases"].append(row)
            for phase in ["seed", "fault" if scenario.startswith("fault") else "crash", "inspect", "inspectAgain"]:
                row["actions"].append(worker(case, scenario, phase))
            archive = case / "original"; archive.mkdir(mode=0o700)
            archived = {}
            for path in (case / "catalog").iterdir():
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 2 * MIB:
                    raise RuntimeError("Unsafe archive input")
                shutil.copyfile(path, archive / path.name); (archive / path.name).chmod(0o600)
                archived[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
            row["originalSHA256"] = archived
            for phase in ["recover", "cold"]:
                row["actions"].append(worker(case, scenario, phase))
            row["passed"] = True
            print(f"{scenario}: six fresh-process actions passed", flush=True)
        report["after"] = usage(); report["passed"] = True
    finally:
        write(report_root / "report.json", report)
        print(f"Report: {report_root.relative_to(ROOT) / 'report.json'}", flush=True)
    if not report["passed"]:
        raise RuntimeError("Native reference process qualification incomplete")


if __name__ == "__main__":
    main()
