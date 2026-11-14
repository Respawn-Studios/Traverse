#!/usr/bin/env python3
"""Qualify recovery in fresh test processes; never terminate the application."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory, stamp


def read_summary(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8192:
        raise RuntimeError(f"Missing or invalid owned worker receipt: {path}")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.items()):
        raise RuntimeError(f"Unexpected owned worker receipt: {path}")
    return data


def main() -> int:
    run = stamp()
    receipt = local_directory("evidence") / f"recovery-process-crash-{run}.json"
    cases: list[dict] = []
    report = {
        "passed": False,
        "cases": cases,
        "scope": "Dedicated test worker terminates itself after durable intent or filesystem rename. Each inspection and explicit recovery uses another process. Only new owned fixtures are mutated; no application or other process is stopped.",
        "limits": ["Process interruption, not power loss", "Same-volume rename boundaries; other crash permutations remain unqualified", "No automatic recovery, cleanup or resumption"],
    }
    try:
        for boundary in ("intent", "renamed"):
            root = local_directory("test-fixtures") / f"recovery-crash-{str(uuid.uuid4()).upper()}"
            case: dict = {"boundary": boundary, "fixture": str(root.relative_to(ROOT)), "phases": [], "passed": False}
            cases.append(case)
            summaries: list[dict[str, str]] = []
            for phase in (boundary, "inspect", "recover"):
                env = environment()
                env["MAC_EXPLORER_RECOVERY_CRASH_ROOT"] = str(root)
                env["MAC_EXPLORER_RECOVERY_CRASH_PHASE"] = phase
                log = local_directory("logs") / f"recovery-process-{run}-{boundary}-{phase}.log"
                with log.open("xb") as output:
                    result = subprocess.run([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter", "recoveryCrashQualificationWorker"],
                                            cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=300, check=False)
                summary = read_summary(root / ("termination-summary.json" if phase == boundary else f"{phase}-summary.json"))
                summaries.append(summary)
                case["phases"].append({"phase": phase, "wrapperExit": result.returncode, "log": str(log.relative_to(ROOT)), "nativeWorker": summary})
                if phase == boundary:
                    if result.returncode != 1 or summary.get("terminationCode") != "86":
                        raise RuntimeError(f"Worker did not reach the requested {boundary} interruption boundary")
                elif result.returncode != 0:
                    raise RuntimeError(f"Fresh {phase} worker failed after {boundary}; see {log}")
                if summary.get("phase") != phase or not summary.get("pid", "").isdigit():
                    raise RuntimeError("Worker phase/process receipt is invalid")
            if len({item["pid"] for item in summaries}) != 3:
                raise RuntimeError("Inspection/recovery did not use independent worker processes")
            inspected, recovered = summaries[1:]
            expected_source = "true" if boundary == "intent" else "false"
            expected_destination = "false" if boundary == "intent" else "true"
            if inspected.get("sourcePresent") != expected_source or inspected.get("destinationPresent") != expected_destination:
                raise RuntimeError("Fresh inspection did not observe the requested interruption state")
            if inspected.get("recordID") != recovered.get("recordID") or recovered.get("sourcePresent") != "true" or recovered.get("destinationPresent") != "false":
                raise RuntimeError("Fresh recovery did not restore the same operation's source")
            case["passed"] = True
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
    with receipt.open("x") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"Recovery process qualification {'passed' if report['passed'] else 'FAILED'}: {receipt}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
