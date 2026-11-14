#!/usr/bin/env python3
"""Retained, bounded genuine SQLite-hot-journal no-write qualification."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory, stamp


def main() -> int:
    run = stamp()
    source_files = sorted((ROOT / "Packages/ExplorerKit/Sources/FileOperations").glob("*.swift")) + sorted((ROOT / "Packages/ExplorerKit/Tests/FileOperationsTests").glob("*.swift")) + [Path(__file__).resolve()]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
    def check_sources() -> None:
        if any(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != expected for path, expected in hashes.items()):
            raise RuntimeError("Qualification inputs changed during the run")
    report = {"passed": False, "cases": [], "sourceHashes": hashes,
              "scope": "Generated real SQLite-hot and activation-commit process crashes, read-only inspection, explicit recovery; not power loss"}
    for version, activation in ((2, None), (3, None), (4, None), (3, "before"), (3, "after")):
        package = ROOT / "Packages/ExplorerKit/.build/test-fixtures"
        if not package.is_dir() or package.resolve() != package:
            raise RuntimeError("Unredirected package fixture root is required")
        root = package / ("history-process-" + str(uuid.uuid4()).upper())
        case = {"version": version, "activation": activation, "phases": [], "passed": False}
        report["cases"].append(case)
        try:
            pids = set()
            crash = "activateBefore" if activation == "before" else "activateAfter" if activation == "after" else "crash"
            for phase in ("seed", crash, "inspect1", "inspect2", "recover", "cold"):
                check_sources()
                env = environment()
                env.update(MAC_EXPLORER_HISTORY_PROCESS_ROOT=str(root), MAC_EXPLORER_HISTORY_PROCESS_PHASE=phase,
                           MAC_EXPLORER_HISTORY_PROCESS_VERSION=str(version))
                if activation is not None:
                    env["MAC_EXPLORER_HISTORY_PROCESS_ACTIVATION"] = activation
                else:
                    env.pop("MAC_EXPLORER_HISTORY_PROCESS_ACTIVATION", None)
                log = local_directory("logs") / f"history-process-{run}-{version}-{activation or 'sqlite'}-{phase}.log"
                with log.open("xb") as output:
                    result = subprocess.run([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter",
                                             "historyInspectionProcessQualificationWorker"], cwd=ROOT, env=env,
                                            stdout=output, stderr=subprocess.STDOUT, timeout=180, check=False)
                os.chmod(log, 0o600)
                check_sources()
                receipt_path = root / (phase + ".json")
                if receipt_path.is_symlink() or receipt_path.stat().st_size > 4096:
                    raise RuntimeError("Invalid worker receipt")
                raw = receipt_path.read_bytes()
                value = json.loads(raw)
                if result.returncode != (1 if phase == crash else 0) or value.get("phase") != phase:
                    raise RuntimeError("Unexpected process outcome")
                pid = int(value["pid"])
                if pid in pids or pid <= 0:
                    raise RuntimeError("Expected fresh independent processes")
                pids.add(pid)
                if phase == "crash" and (value.get("terminationCode") != "86" or value.get("realHotHeader") != "true"):
                    raise RuntimeError("Genuine hot-journal boundary was not reached")
                if phase == crash and activation is not None and (value.get("activationBoundary") != phase or value.get("terminationCode") != "86"):
                    raise RuntimeError("Activation crash boundary was not reached")
                if phase in ("inspect1", "inspect2", "cold") and value.get("unchanged") != "true":
                    raise RuntimeError("Inspection changed retained history")
                case["phases"].append({"phase": phase, "worker": value, "receiptSHA256": hashlib.sha256(raw).hexdigest(),
                                       "log": str(log.relative_to(ROOT)), "wrapperExit": result.returncode})
            case["passed"] = True
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            case["failure"] = str(error)
            break
    report["passed"] = len(report["cases"]) == 5 and all(case["passed"] for case in report["cases"])
    path = local_directory("evidence") / ("history-process-" + run + ".json")
    with path.open("x") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
    path.chmod(0o600)
    print(f"History process qualification {'passed' if report['passed'] else 'FAILED'}: {path}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
