#!/usr/bin/env python3
"""B07.5 export/Forget interruptions in bounded generated cases only."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

os.environ["MAC_EXPLORER_B07_CONTINUITY_MANAGEMENT"] = "1"
from verify_move_continuity import ROOT, MIB, admit, archive_before_recovery, child, usage, write
from dev import environment


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--native-import", action="store_true")
    parser.add_argument("--foreground", action="store_true")
    parser.add_argument("--imports", action="store_true")
    parser.add_argument("--import-faults", action="store_true")
    parser.add_argument("--audit", action="store_true")
    parser.add_argument("--scenario", action="append")
    args = parser.parse_args()
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    if args.native or args.native_import:
        case = admit(size=4*MIB, entries=96)
        (case/"source/Report.txt").write_bytes(b"Generated report body, never in saved names\n")
        if args.native_import:
            write(case/"source/import.json", dict(format="MacExplorer.PrivateNames", version=1, includesLocations=True,
                records=[dict(id=str(uuid.uuid4()).upper(), nickname=title, alternateNames=[], labels=["generated"],
                    lastKnownLocation=str(case/"source/Never opened")) for title in ("Orion imported report", "Imported folder")]))
        binary = ROOT/".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
        env = environment(tooling=False)
        env.update(MAC_EXPLORER_STATE_ROOT=str(case/"state"), MAC_EXPLORER_CACHE_ROOT=str(case/"cache"),
            MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(MIB))
        with (case/"native.log").open("xb") as log:
            result = subprocess.run([str(binary), "-ApplePersistenceIgnoreState", "YES", "--verify-ui",
                "--check-private-import" if args.native_import else "--check-private-management", "--analysis-source", str(case)] + ([] if args.foreground else ["--offscreen"]),
                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        write(case/"exit.json", dict(exit=result.returncode))
        if result.returncode or not (case/"native.json").is_file():
            raise RuntimeError(f"Native management workflow failed: {case.relative_to(ROOT)}")
        report = json.loads((case/"native.json").read_bytes())
        if not report.get("passed"): raise RuntimeError("Native management did not pass")
        print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=report, usage=usage()), indent=2)); return 0
    if args.import_faults: args.imports = True
    scenarios = args.scenario or (["existingfaultWrite", "existingfaultJournalSync", "existingfaultDatabaseSync"] if args.import_faults else [prefix+stage for prefix in ("initial", "existing")
        for stage in ("rows", "beforeCommit", "commitAdmitted", "committed", "acknowledged")] if args.imports else ["exportadmitted", "exportbeforeCreate", "exportcreated", "exportwriting",
        "exportwritten", "exportsynchronized", "revocationRows", "revocationCommit", "purgeRows", "purgeCommit", "acknowledged", "realWriteLimit"]
    )
    inputs = sorted((ROOT/"Packages/ExplorerKit/Sources/FileMemory").glob("*.swift"))
    inputs += [ROOT/"Packages/ExplorerKit/Tests/FileMemoryTests/NameExportProcessTests.swift", Path(__file__).resolve(),
        ROOT/".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"]
    if args.imports: inputs += [ROOT/"Packages/ExplorerKit/Tests/FileMemoryTests/NameImportProcessTests.swift", ROOT/"Packages/ExplorerKit/Tests/FileMemoryTests/NameImportTests.swift"]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    report_root = admit(size=MIB, entries=12); report = dict(passed=False, inputs=hashes, cases=[])
    try:
        for scenario in scenarios:
            if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
                raise RuntimeError("Export qualification inputs changed")
            case = admit(size=2*MIB, entries=64)
            row = dict(scenario=scenario, root=str(case.relative_to(ROOT)), phases=[]); report["cases"].append(row)
            for phase in ("seed", "fault" if scenario == "realWriteLimit" or "fault" in scenario else "crash", "inspect", "recover", "cold"):
                if phase == "recover": row["beforeRecovery"] = archive_before_recovery(case)
                row["phases"].append(child(case, scenario, phase, worker="b075ImportProcessWorker" if args.imports else "b075ExportProcessWorker"))
            print(f"{scenario}: qualified", flush=True)
        if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
            raise RuntimeError("Export qualification inputs changed")
        report["passed"] = True; report["usage"] = usage()
    finally:
        write(report_root/"report.json", report)
    print(f"Report: {report_root.relative_to(ROOT)}/report.json"); return 0


if __name__ == "__main__":
    raise SystemExit(main())
