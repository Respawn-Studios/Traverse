#!/usr/bin/env python3
"""Inspect explicit cleanup interruptions in independent disposable test processes."""
from __future__ import annotations

import json
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory, stamp
from verify_recovery_crashes import read_summary


def main() -> int:
    run = stamp()
    receipt = local_directory("evidence") / f"retention-process-crash-{run}.json"
    cases: list[dict] = []
    report = {
        "passed": False,
        "cases": cases,
        "scope": "Dedicated fixture worker exits itself at cleanup intent or native Trash fixture rename; a fresh process inspects preserved review state. No app or shared process is stopped.",
        "limits": ["Process interruption, not power loss", "Injected fixture Trash; real native Trash qualified separately", "No automatic cleanup, resumption or rollback"],
    }
    try:
        for boundary in ("intent", "renamed"):
            root = local_directory("test-fixtures") / f"retention-crash-{str(uuid.uuid4()).upper()}"
            case: dict = {"boundary": boundary, "fixture": str(root.relative_to(ROOT)), "phases": [], "passed": False}
            cases.append(case)
            summaries: list[dict[str, str]] = []
            for phase in (boundary, "inspect"):
                env = environment()
                env["MAC_EXPLORER_RETENTION_CRASH_ROOT"] = str(root)
                env["MAC_EXPLORER_RETENTION_CRASH_PHASE"] = phase
                log = local_directory("logs") / f"retention-process-{run}-{boundary}-{phase}.log"
                with log.open("xb") as output:
                    result = subprocess.run([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter", "retentionCrashQualificationWorker"],
                                            cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT,
                                            timeout=300, check=False)
                summary = read_summary(root / ("inspect-summary.json" if phase == "inspect" else "termination-summary.json"))
                summaries.append(summary)
                case["phases"].append({"phase": phase, "wrapperExit": result.returncode,
                                       "log": str(log.relative_to(ROOT)), "worker": summary})
                if phase == boundary:
                    if result.returncode != 1 or summary.get("terminationCode") != "86":
                        raise RuntimeError(f"Worker did not reach requested {boundary} boundary")
                elif result.returncode != 0:
                    raise RuntimeError(f"Fresh inspection failed after {boundary}; see {log}")
                if summary.get("phase") != phase or not summary.get("pid", "").isdigit():
                    raise RuntimeError("Worker phase/process receipt is invalid")
            ended, inspected = summaries
            expected_trash_count = "0" if boundary == "intent" else "1"
            if ended["pid"] == inspected["pid"] or ended.get("recordID") != inspected.get("recordID"):
                raise RuntimeError("Inspection did not use an independent process for the same job")
            if (inspected.get("state") != "cleanupReview" or inspected.get("canCleanup") != "false"
                    or inspected.get("trashCount") != expected_trash_count
                    or inspected.get("publishedPresent") != "true" or inspected.get("sourcePresent") != "true"):
                raise RuntimeError("Fresh inspection lost the expected protected cleanup boundary")
            case["passed"] = True
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
    with receipt.open("x") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"Retention process qualification {'passed' if report['passed'] else 'FAILED'}: {receipt}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
