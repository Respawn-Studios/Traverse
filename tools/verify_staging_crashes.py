#!/usr/bin/env python3
"""Inspect staging seal boundaries in fresh disposable test processes."""
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
    receipt = local_directory("evidence") / f"staging-process-crash-{run}.json"
    cases: list[dict] = []
    report = {
        "passed": False,
        "cases": cases,
        "scope": "Dedicated generated-fixture worker exits itself after payload sync before seal, or after durable seal. A fresh process only inspects staging eligibility. No application or shared process is stopped.",
        "limits": ["Process interruption, not power loss", "Completed staged copy boundaries; half-written leaves remain protected", "No automatic cleanup, resumption or rollback"],
    }
    try:
        for boundary in ("before-seal", "after-seal"):
            root = local_directory("test-fixtures") / f"staging-crash-{str(uuid.uuid4()).upper()}"
            case: dict = {"boundary": boundary, "fixture": str(root.relative_to(ROOT)), "phases": [], "passed": False}
            cases.append(case)
            summaries: list[dict[str, str]] = []
            for phase in (boundary, "inspect"):
                env = environment()
                env["MAC_EXPLORER_STAGING_CRASH_ROOT"] = str(root)
                env["MAC_EXPLORER_STAGING_CRASH_PHASE"] = phase
                env["MAC_EXPLORER_STAGING_CRASH_BOUNDARY"] = boundary
                log = local_directory("logs") / f"staging-process-{run}-{boundary}-{phase}.log"
                with log.open("xb") as output:
                    result = subprocess.run([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter", "stagingCrashQualificationWorker"],
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
            expected_seal = "true" if boundary == "after-seal" else "false"
            if ended["pid"] == inspected["pid"] or ended.get("recordID") != inspected.get("recordID"):
                raise RuntimeError("Inspection did not use an independent process for the same job")
            if (inspected.get("hasSeal") != expected_seal or inspected.get("canCleanup") != expected_seal
                    or inspected.get("payloadPresent") != "true" or inspected.get("sourcePresent") != "true"
                    or inspected.get("publishedPresent") != "false" or inspected.get("trashCount") != "0"):
                raise RuntimeError("Fresh inspection lost the expected staging proof boundary")
            case["passed"] = True
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
    with receipt.open("x") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"Staging process qualification {'passed' if report['passed'] else 'FAILED'}: {receipt}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
