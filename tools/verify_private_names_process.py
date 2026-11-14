#!/usr/bin/env python3
"""Generated-only B07.1 process-crash/native-VFS I/O qualification. No app UI."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment

BASE = ROOT / ".build/b07-private-store"
GIB = 1024**3
LIMIT = 2 * GIB
ENTRY_LIMIT = 2048


def usage() -> dict:
    total = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, receiptLogBytes=0)
    if BASE.resolve() != BASE:
        raise RuntimeError("Redirected qualification root")
    for case in BASE.iterdir():
        if case.name == ".budget.lock":
            continue
        if not case.is_dir() or case.is_symlink():
            raise RuntimeError("Unexpected qualification namespace")
        allocation = json.loads((case / "reservation.json").read_bytes())
        count, size = 0, 0
        stack = [case]
        while stack:
            path = stack.pop()
            info = path.lstat()
            count += 1
            charge = max(info.st_size, info.st_blocks * 512)
            size += charge
            if stat.S_ISDIR(info.st_mode):
                stack.extend(path.iterdir())
            elif path.suffix in (".json", ".log"):
                total["receiptLogBytes"] += charge
        if count > allocation["entries"] or size > allocation["bytes"] or size > GIB // 2:
            raise RuntimeError("A preserved case exceeded its reservation")
        total["bytes"] += size
        total["entries"] += count
        total["reservedBytes"] += allocation["bytes"]
        total["reservedEntries"] += allocation["entries"]
    if total["bytes"] > LIMIT or total["entries"] > ENTRY_LIMIT or total["receiptLogBytes"] > 16 * 1024**2:
        raise RuntimeError("Approved aggregate qualification limit exceeded")
    return total


def admit(*, entries: int = 32, size: int = 8 * 1024**2) -> Path:
    BASE.mkdir(exist_ok=True, mode=0o700)
    with (BASE / ".budget.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prior = usage()
        if prior["reservedBytes"] + size > LIMIT or prior["reservedEntries"] + entries > ENTRY_LIMIT:
            raise RuntimeError("No unreserved qualification headroom; previous evidence preserved")
        path = BASE / str(uuid.uuid4()).upper()
        path.mkdir(mode=0o700)
        write_json(path / "reservation.json", {"bytes": size, "entries": entries})
        return path


def write_json(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8") as file:
        json.dump(value, file, sort_keys=True, indent=2)
        file.write("\n")
    path.chmod(0o600)


def archive(case: Path, name: str = "original") -> dict:
    destination = case / name
    destination.mkdir(mode=0o700)
    result = {}
    for path in sorted((case / "catalog").iterdir()):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 4 * 1024**2:
            raise RuntimeError("Unsafe/oversized generated recovery input")
        data = path.read_bytes()
        output = destination / path.name
        with output.open("xb") as file:
            file.write(data)
        output.chmod(0o600)
        result[path.name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
                             "originalInode": info.st_ino, "originalDevice": info.st_dev}
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", help="Run one frozen scenario for focused iteration")
    args = parser.parse_args()
    sources = sorted((ROOT / "Packages/ExplorerKit/Sources/FileMemory").glob("*.swift"))
    sources += sorted((ROOT / "Packages/ExplorerKit/Tests/FileMemoryTests").glob("*.swift"))
    sources += sorted((ROOT / "Packages/ExplorerKit/Tests/NameStoreFaultSupport").rglob("*.c"))
    sources += sorted((ROOT / "Packages/ExplorerKit/Tests/NameStoreFaultSupport").rglob("*.h"))
    sources += [ROOT / "Packages/ExplorerKit/Package.swift", ROOT / "Packages/ExplorerKit/Sources/LocalStorage/PrivateStateDirectory.swift", Path(__file__).resolve()]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    report_root = admit(entries=8, size=4 * 1024**2)
    report = {"passed": False, "scope": "Generated SQLite process crashes and injected native VFS failures; not device ENOSPC or power loss",
              "sourceHashes": hashes, "cases": [], "before": usage()}

    def worker(case: Path, scenario: str, phase: str, *, crash: bool = False, op: int = 0, role: int = 0, direct: bool = False) -> dict:
        if any(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != value for path, value in hashes.items()):
            raise RuntimeError("Qualification sources changed during run")
        env = environment()
        env.update(MAC_EXPLORER_B07_PROCESS_ROOT=str(case), MAC_EXPLORER_B07_PROCESS_SCENARIO=scenario,
                   MAC_EXPLORER_B07_PROCESS_PHASE=phase, MAC_EXPLORER_B07_FAULT_OP=str(op), MAC_EXPLORER_B07_FAULT_ROLE=str(role))
        log = case / (phase + ".log")
        command = [sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter", "privateNamesProcessQualificationWorker"]
        if direct:
            # SwiftPM holds its build-directory lock while tests run. Launch its
            # actual built test bundle directly for the concurrent contender,
            # with Xcode runtime paths confined to this child environment.
            swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
            helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
            developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
            platform = developer / "Platforms/MacOSX.platform/Developer"
            env["DYLD_FRAMEWORK_PATH"] = str(platform / "Library/Frameworks")
            env["DYLD_LIBRARY_PATH"] = str(platform / "usr/lib")
            binary = ROOT / ".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"
            command = [str(helper), "--test-bundle-path", str(binary), "--testing-library", "swift-testing", "--filter", "privateNamesProcessQualificationWorker"]
        with log.open("xb") as output:
            process = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=90, check=False)
        log.chmod(0o600)
        receipt = case / (phase + ".json")
        if not receipt.is_file() or receipt.is_symlink() or receipt.stat().st_size > 4096:
            raise RuntimeError(f"Missing bounded worker receipt for {phase}; see {log.relative_to(ROOT)}")
        value = json.loads(receipt.read_bytes())
        if process.returncode != (1 if crash else 0) or value.get("phase") != phase:
            raise RuntimeError(f"Failed {scenario}/{phase}; see {log.relative_to(ROOT)}")
        if crash and (value.get("terminationCode") != "86" or scenario == "saveRows" and value.get("realHotHeader") != "true"):
            raise RuntimeError("Requested genuine process boundary was not proved")
        if phase.startswith("inspect") or phase == "faultInspect":
            if value.get("unchanged") != "true":
                raise RuntimeError("Passive inspection changed storage")
        usage()
        return {"worker": value, "wrapperExit": process.returncode,
                "receiptSHA256": hashlib.sha256(receipt.read_bytes()).hexdigest(), "log": str(log.relative_to(ROOT))}

    crashes = ["initRows", "initCommit", "ready", "saveRows", "saveCommit", "revocationRows", "revocationCommit", "purgeRows", "purgeCommit", "acknowledged"]
    faults = [("faultJournalWrite", 1, 2), ("faultJournalSync", 2, 2), ("faultMainWrite", 1, 1),
              ("faultMainSync", 2, 1), ("faultJournalDelete", 4, 2), ("faultFull", 0, 0),
              ("faultForgetFence", 2, 2), ("faultForgetPurge", 2, 2)]
    try:
        for scenario in crashes + [item[0] for item in faults] + ["truncateRecovery"]:
            if args.scenario and scenario != args.scenario:
                continue
            slots = 40 if scenario == "truncateRecovery" else 24 if scenario in ("initRows", "initCommit") else 28
            case = admit(entries=slots)
            row = {"scenario": scenario, "root": str(case.relative_to(ROOT)), "phases": [], "passed": False}
            report["cases"].append(row)
            if scenario == "truncateRecovery":
                row["phases"].append(worker(case, "saveRows", "seed"))
                row["phases"].append(worker(case, "saveRows", "crash", crash=True))
                row["original"] = archive(case)
                row["phases"].append(worker(case, "saveRows", "faultTruncate"))
                row["failedRecovery"] = archive(case, "failed-recovery")
                row["phases"].append(worker(case, "saveRows", "faultInspect"))
                row["phases"].append(worker(case, "saveRows", "recover"))
                row["phases"].append(worker(case, "saveRows", "cold"))
            elif scenario in crashes:
                for phase in ("seed", "crash", "inspect1", "inspect2"):
                    row["phases"].append(worker(case, scenario, phase, crash=phase == "crash"))
                row["original"] = archive(case)
                for phase in ("recover", "cold"):
                    row["phases"].append(worker(case, scenario, phase))
            else:
                _, op, role = next(item for item in faults if item[0] == scenario)
                row["phases"].append(worker(case, scenario, "seed"))
                row["phases"].append(worker(case, scenario, "fault", op=op, role=role))
                row["phases"].append(worker(case, scenario, "faultInspect"))
                row["original"] = archive(case)
                row["phases"].append(worker(case, scenario, "recover"))
                row["phases"].append(worker(case, scenario, "cold"))
            pids = [phase["worker"]["pid"] for phase in row["phases"]]
            if len(pids) != len(set(pids)):
                raise RuntimeError("Independent process identities were reused")
            row["passed"] = True
            print(f"Passed {scenario}: {len(row['phases'])} independent process actions", flush=True)
        if args.scenario in (None, "twoProcessLock"):
            case = admit(entries=20)
            row = {"scenario": "twoProcessLock", "root": str(case.relative_to(ROOT)), "phases": [], "passed": False}
            report["cases"].append(row)
            row["phases"].append(worker(case, "lock", "seed"))
            env = environment()
            env.update(MAC_EXPLORER_B07_PROCESS_ROOT=str(case), MAC_EXPLORER_B07_PROCESS_SCENARIO="lock", MAC_EXPLORER_B07_PROCESS_PHASE="hold")
            with (case / "hold.log").open("xb") as output:
                holder = subprocess.Popen([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter", "privateNamesProcessQualificationWorker"],
                                          cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 15
                    while not (case / "hold.json").is_file():
                        if holder.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError("Lock holder did not become ready")
                        time.sleep(0.05)
                    row["phases"].append(worker(case, "lock", "inspectBusy", direct=True))
                finally:
                    (case / "release").touch(exist_ok=False)
                    if holder.wait(timeout=25) != 0:
                        raise RuntimeError("Generated lock holder failed")
            row["phases"].append({"worker": json.loads((case / "hold.json").read_bytes()), "wrapperExit": holder.returncode,
                                  "log": str((case / "hold.log").relative_to(ROOT))})
            row["phases"].append(worker(case, "lock", "cold"))
            row["passed"] = True
            print("Passed twoProcessLock: independent owner, busy reader/writer, then clean reopening", flush=True)
        if not report["cases"]:
            raise RuntimeError("Unknown frozen scenario")
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
    finally:
        report["after"] = usage()
        write_json(report_root / "report.json", report)
    print(f"B07.1 process qualification {'passed' if report['passed'] else 'FAILED'}: {(report_root / 'report.json').relative_to(ROOT)}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
