#!/usr/bin/env python3
"""Fresh-process schema-4 qualification using immutable schema-3 production code.

Only generated, marked fixtures beneath this repository's ignored .build root
are used. Process _exit and injected errors do not qualify power-loss recovery.
This runner deliberately does not clean up its evidence.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = "Packages/ExplorerKit/Sources/FileOperations"
BASELINE = "28089a583e62eee1b951f664485e190855e5c649"
HARNESS = ("LegacyCatalogCompatibilityWorker.swift", "GroupedCatalogQualificationWorker.swift", "verify_grouped_catalog.py")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_directory(path: Path, *, private: bool = True) -> None:
    value = path.lstat()
    if path.resolve() != path or not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid():
        raise RuntimeError("Unsafe qualification directory")
    if value.st_mode & (0o077 if private else 0o022):
        raise RuntimeError("Qualification directory permissions are unsafe")


def new_directory(path: Path) -> None:
    safe_directory(path.parent, private=False)
    path.mkdir(mode=0o700)
    safe_directory(path)


def exclusive_write(path: Path, data: bytes) -> None:
    safe_directory(path.parent)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def main() -> int:
    safe_directory(ROOT, private=False)
    build = ROOT / ".build"
    safe_directory(build, private=False)
    base = build / "grouped-catalog-qualification"
    if not base.exists():
        new_directory(base)
    safe_directory(base)
    run = base / str(uuid.uuid4())
    new_directory(run)
    exclusive_write(run / ".qualification-owner",
                    f"MacExplorer grouped catalog qualification v1\n{run.name}\n".encode())
    for name in ("fixtures", "modules", "clang-modules", "tmp", "current", "baseline", "harness", "logs"):
        new_directory(run / name)
    environment = os.environ.copy()
    environment.update({"TMPDIR": str(run / "tmp"), "CLANG_MODULE_CACHE_PATH": str(run / "clang-modules"),
                        "MAC_EXPLORER_GROUPED_CATALOG_RUN_ROOT": str(run)})
    # HOME/CODEX_HOME and shared toolchain state are never repurposed.
    report: dict = {"passed": False, "baselineCommit": BASELINE, "commands": [], "builds": {},
                    "sourceHashes": {}, "harnessHashes": {}, "cases": [],
                    "scope": ["Catalog migration and dispatch only; no grouped file execution",
                              "Generated local APFS fixtures only; no owner journal or shared process",
                              "Process interruption and injected errors; not power-loss qualification"]}
    sequence = 0
    frozen: dict[Path, str] = {}

    def check_frozen() -> None:
        for path, expected in frozen.items():
            value = path.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_uid != os.geteuid() or sha(path.read_bytes()) != expected:
                raise RuntimeError("Frozen qualification source changed")

    def command(argv: list[str], label: str, *, expected: int = 0, timeout: int = 120) -> subprocess.CompletedProcess:
        nonlocal sequence
        check_frozen()
        sequence += 1
        log_name = f"{sequence:03d}-{label}.json"
        start = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=environment, capture_output=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            receipt = {"argv": argv, "expectedExit": expected, "exit": "timeout",
                       "seconds": time.monotonic() - start, "log": f"logs/{log_name}"}
            report["commands"].append(receipt)
            exclusive_write(run / "logs" / log_name, json.dumps({**receipt,
                "stdout": (error.stdout or b"").decode("utf-8", errors="replace"),
                "stderr": (error.stderr or b"").decode("utf-8", errors="replace")}, indent=2).encode())
            raise RuntimeError(f"Qualification command timed out: {label}") from error
        receipt = {"argv": argv, "expectedExit": expected, "exit": result.returncode,
                   "seconds": time.monotonic() - start, "log": f"logs/{log_name}"}
        report["commands"].append(receipt)
        # All worker bodies are generated fixture data. Retain diagnostics locally;
        # public receipts contain only structured invariant evidence and digests.
        exclusive_write(run / "logs" / log_name, json.dumps({**receipt,
            "stdout": result.stdout.decode("utf-8", errors="replace"),
            "stderr": result.stderr.decode("utf-8", errors="replace")}, indent=2).encode())
        if result.returncode != expected:
            raise RuntimeError(f"Qualification command failed: {label} (exit {result.returncode})")
        check_frozen()
        return result

    def snapshot(label: str, name: str, data: bytes) -> None:
        target = run / label / name
        exclusive_write(target, data)
        frozen[target] = sha(data)
        report["sourceHashes"].setdefault(label, {})[name] = sha(data)

    def compile_worker(label: str, sources: str, current: bool) -> Path:
        binary = run / label
        argv = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                "-j", "2", "-num-threads", "2", "-module-cache-path", str(run / "modules"), "-o", str(binary)]
        if not current:
            argv += ["-DLEGACY_CATALOG_WORKER"]
        argv += [str(path) for path in sorted((run / sources).glob("*.swift"))]
        argv += [str(run / "harness" / HARNESS[0])]
        if current:
            argv += [str(run / "harness" / HARNESS[1])]
        command(argv, label + "-compile", timeout=600)
        report["builds"][label] = {"binarySHA256": sha(binary.read_bytes()), "snapshot": sources,
                                    "sourceCount": len(report["sourceHashes"][sources])}
        frozen[binary] = report["builds"][label]["binarySHA256"]
        return binary

    def invoke(binary: Path, phase: str, fixture: Path, *extra: str, expected: int = 0) -> dict:
        result = command([str(binary), phase, str(fixture), *extra], phase, expected=expected)
        value = json.loads(result.stdout)
        if not isinstance(value, dict) or not isinstance(value.get("pid"), int):
            raise RuntimeError("Worker did not return a structured process receipt")
        return value

    def different_processes(*receipts: dict) -> None:
        pids = [receipt["pid"] for receipt in receipts]
        if len(set(pids)) != len(pids):
            raise RuntimeError("Required independent worker processes were not distinct")

    try:
        commit = command(["git", "rev-parse", "--verify", f"{BASELINE}^{{commit}}"], "baseline-resolve").stdout.decode().strip()
        if commit != BASELINE:
            raise RuntimeError("Pinned baseline does not resolve exactly")
        names = command(["git", "ls-tree", "-r", "--name-only", BASELINE, SOURCE_PATH], "baseline-files").stdout.decode().splitlines()
        for name in names:
            if name.endswith(".swift"):
                if Path(name).parent.as_posix() != SOURCE_PATH:
                    raise RuntimeError("Unexpected nested baseline source")
                snapshot("baseline", Path(name).name,
                         command(["git", "show", f"{BASELINE}:{name}"], "baseline-source").stdout)
        for source in sorted((ROOT / SOURCE_PATH).glob("*.swift")):
            value = source.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size > 4_194_304:
                raise RuntimeError("Unsafe production source snapshot")
            snapshot("current", source.name, source.read_bytes())
        for name in HARNESS:
            source = ROOT / "tools" / name
            value = source.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size > 1_048_576:
                raise RuntimeError("Unsafe harness snapshot")
            data = source.read_bytes()
            target = run / "harness" / name
            exclusive_write(target, data)
            frozen[target] = report["harnessHashes"][name] = sha(data)
        legacy = compile_worker("legacy-worker", "baseline", False)
        current = compile_worker("current-worker", "current", True)
        matrix = [("none", "none"), ("injected_error", "before_commit"),
                  ("injected_error", "after_commit"), ("process_crash", "before_commit"),
                  ("process_crash", "after_commit"), ("lost_acknowledgement", "after_commit_before_ack")]
        grouped_fixture: Path | None = None
        for seed_kind in ("empty", "mixed"):
            for mechanism, boundary in matrix:
                fixture = run / "fixtures" / ("catalog-" + str(uuid.uuid4()))
                seeded = invoke(legacy, "seed-" + seed_kind, fixture)
                initial = invoke(current, "inspect", fixture, "3")
                stopped = invoke(current, "upgrade", fixture, mechanism, boundary,
                                 expected=86 if mechanism == "process_crash" else 0)
                expected_schema = 3 if boundary == "before_commit" else 4
                cold = invoke(current, "inspect", fixture, str(expected_schema))
                different_processes(seeded, initial, stopped, cold)
                case = {"seed": seed_kind, "mechanism": mechanism, "boundary": boundary,
                        "fixture": str(fixture.relative_to(run)), "seeded": seeded,
                        "ordinaryOpen": initial, "upgrade": stopped, "coldRead": cold}
                if expected_schema == 3:
                    retry = invoke(current, "upgrade", fixture, "none", "none")
                    final = invoke(current, "inspect", fixture, "4")
                    different_processes(cold, retry, final)
                    case.update({"explicitRetry": retry, "settledColdRead": final})
                else:
                    final = cold
                refused = invoke(legacy, "old-reader", fixture)
                different_processes(final, refused)
                case["pinnedOldReader"] = refused
                report["cases"].append(case)
                if seed_kind == "mixed" and mechanism == "none":
                    grouped_fixture = fixture
        if grouped_fixture is None:
            raise RuntimeError("Missing mixed fixture")
        grouped_seed = invoke(current, "grouped-seed", grouped_fixture)
        grouped_cold = invoke(current, "grouped-inspect", grouped_fixture)
        compact = invoke(current, "compact", grouped_fixture)
        compact_cold = invoke(current, "grouped-inspect", grouped_fixture)
        different_processes(grouped_seed, grouped_cold, compact, compact_cold)
        if len({grouped_cold["groupedHash"], compact["groupedHash"], compact_cold["groupedHash"]}) != 1:
            raise RuntimeError("Compaction changed current grouped evidence")
        grouped_old_reader = invoke(legacy, "old-reader", grouped_fixture)
        different_processes(compact_cold, grouped_old_reader)
        report["mixedGrouped"] = {"seeded": grouped_seed, "coldRead": grouped_cold,
                                   "compaction": compact, "compactedColdRead": compact_cold,
                                   "pinnedOldReader": grouped_old_reader}
        check_frozen()
        report["passed"] = True
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        exclusive_write(run / "report.json", json.dumps(report, indent=2, sort_keys=True).encode())
    print(json.dumps({"passed": report["passed"], "report": str(run / "report.json"),
                      "cases": len(report["cases"]), "baselineCommit": BASELINE}, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
