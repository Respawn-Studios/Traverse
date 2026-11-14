#!/usr/bin/env python3
"""Qualify incremental journal COMMIT boundaries in fresh owned workers."""
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
    receipt = local_directory("evidence") / f"journal-process-crash-{run}.json"
    cases = []
    report = {"passed": False, "cases": cases,
              "scope": "Owned worker exits itself immediately before or after journal COMMIT; a separate process validates durable state.",
              "limits": ["Process interruption, not power loss", "No automatic operation resumption or cleanup"]}
    try:
        for boundary in ("before-commit", "after-commit"):
            root = local_directory("test-fixtures") / f"journal-edit-crash-{str(uuid.uuid4()).upper()}"
            case = {"boundary": boundary, "fixture": str(root.relative_to(ROOT)), "phases": [], "passed": False}
            cases.append(case)
            summaries = []
            for phase in (boundary, "inspect"):
                env = environment()
                env.update({"MAC_EXPLORER_JOURNAL_CRASH_ROOT": str(root),
                            "MAC_EXPLORER_JOURNAL_CRASH_PHASE": phase,
                            "MAC_EXPLORER_JOURNAL_CRASH_BOUNDARY": boundary})
                log = local_directory("logs") / f"journal-process-{run}-{boundary}-{phase}.log"
                with log.open("xb") as output:
                    result = subprocess.run([sys.executable, str(ROOT / "tools/dev.py"), "test", "--filter",
                                             "journalEditCrashQualificationWorker"], cwd=ROOT, env=env,
                                            stdout=output, stderr=subprocess.STDOUT, timeout=300, check=False)
                summary = read_summary(root / ("inspect-summary.json" if phase == "inspect" else "termination-summary.json"))
                summaries.append(summary)
                case["phases"].append({"phase": phase, "wrapperExit": result.returncode,
                                       "log": str(log.relative_to(ROOT)), "worker": summary})
                if phase == boundary:
                    if result.returncode != 1 or summary.get("terminationCode") != "86":
                        raise RuntimeError(f"Worker missed requested {boundary} boundary")
                elif result.returncode != 0:
                    raise RuntimeError(f"Fresh inspection failed after {boundary}")
                if summary.get("phase") != phase or not summary.get("pid", "").isdigit():
                    raise RuntimeError("Invalid worker identity/phase receipt")
            ended, inspected = summaries
            expected = "2" if boundary == "after-commit" else "1"
            state = "mutating" if boundary == "after-commit" else "preparing"
            if ended["pid"] == inspected["pid"] or ended.get("recordID") != inspected.get("recordID"):
                raise RuntimeError("Inspection was not independent for the same job")
            if inspected.get("revision") != expected or inspected.get("locations") != expected or inspected.get("state") != state:
                raise RuntimeError("Fresh durable journal state disagrees with COMMIT boundary")
            case["passed"] = True
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
    with receipt.open("x") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"Journal process qualification {'passed' if report['passed'] else 'FAILED'}: {receipt}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
