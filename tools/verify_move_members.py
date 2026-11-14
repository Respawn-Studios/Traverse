#!/usr/bin/env python3
"""Fresh-process private-v4 member receipt boundaries; generated cases only."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

os.environ["MAC_EXPLORER_B07_CONTINUITY_MANAGEMENT"] = "1"
from verify_move_continuity import ROOT, MIB, admit, archive_before_recovery, child, usage, write
from dev import environment


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", action="append")
    parser.add_argument("--audit", action="store_true")
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--compat", action="store_true")
    args = parser.parse_args()
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    if args.compat:
        case = admit(size=32*MIB, entries=128)
        revision = subprocess.check_output(["git", "rev-parse", "57e0db5^{commit}"], cwd=ROOT, text=True).strip()
        prefix = "Packages/ExplorerKit/Sources/FileMemory/"
        files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", revision, prefix], cwd=ROOT, text=True).splitlines()
        frozen = case/"frozen-v3-sources"; frozen.mkdir(mode=0o700)
        sources, hashes = [], {}
        for file in files:
            if not file.startswith(prefix) or not file.endswith(".swift"): raise RuntimeError("Unexpected frozen source")
            data = subprocess.check_output(["git", "show", revision+":"+file], cwd=ROOT)
            destination = frozen/Path(file).name; destination.write_bytes(data)
            sources.append(str(destination)); hashes[file] = hashlib.sha256(data).hexdigest()
        products = ROOT/".build/swift-tests/out/Products/Debug"
        binary = case/"frozen-v3-probe"
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-warnings-as-errors", "-module-name", "FrozenV3FileMemory",
            "-I", str(products), "-L", str(products), "-lLocalStorage", "-lExplorerCore", "-lFileOperations", "-lsqlite3",
            "-module-cache-path", str(ROOT/".build/compiler-cache/swift"), *sources,
            str(ROOT/"tools/qualification/FrozenV3NameStoreProbe.swift"), "-o", str(binary)]
        with (case/"frozen-compile.log").open("xb") as log:
            subprocess.run(command, cwd=ROOT, env=environment(), stdout=log, stderr=subprocess.STDOUT, timeout=90, check=True)
        child(case, "compat", "seed", worker="b074cMemberProcessWorker")
        with (case/"frozen-run.log").open("xb") as log:
            subprocess.run([str(binary), str(case)], cwd=ROOT, env=environment(tooling=False), stdout=log, stderr=subprocess.STDOUT, timeout=30, check=True)
        report = json.loads((case/"frozen-v3.json").read_bytes())
        if not all(report.values()): raise RuntimeError("Frozen v3 refusal failed")
        write(case/"compatibility.json", dict(passed=True, revision=revision, sources=hashes,
            binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), result=report, usage=usage()))
        print(f"Frozen v3 refusal passed: {case.relative_to(ROOT)}"); return 0
    if args.native:
        case = admit(size=4*MIB, entries=96)
        folder = case/"source/Project/Nested"; folder.mkdir(parents=True)
        (folder/"Document.txt").write_bytes(b"Generated native member document\n")
        app = ROOT/".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
        env = environment(tooling=False)
        env.update(MAC_EXPLORER_STATE_ROOT=str(case/"state"), MAC_EXPLORER_CACHE_ROOT=str(case/"cache"),
            MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(MIB))
        with (case/"native.log").open("xb") as log:
            result = subprocess.run([str(app), "-ApplePersistenceIgnoreState", "YES", "--verify-ui",
                "--check-private-move-members", "--analysis-source", str(case), "--offscreen"],
                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        write(case/"exit.json", dict(exit=result.returncode))
        if result.returncode or not (case/"native.json").is_file():
            raise RuntimeError(f"Native member workflow failed: {case.relative_to(ROOT)}")
        report = json.loads((case/"native.json").read_bytes())
        if not report.get("passed"): raise RuntimeError("Native member report did not pass")
        print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=report, usage=usage()), indent=2)); return 0
    scenarios = args.scenario or ["memberUpgradeRows", "memberUpgradeCommit", "memberFileCommit", "memberReceiptRows",
        "memberReceiptCommit", "memberReferenceRows", "memberReferenceCommit", "memberUndoIntentRows", "memberUndoIntentCommit",
        "memberFileUndoCommit", "memberUndoReferenceRows", "memberUndoReferenceCommit", "faultMemberReceiptWrite", "faultMemberReceiptSync"]
    inputs = sorted((ROOT/"Packages/ExplorerKit/Sources/FileMemory").glob("*.swift"))
    inputs += sorted((ROOT/"Packages/ExplorerKit/Sources/FileOperations").glob("*.swift"))
    inputs += [ROOT/"Packages/ExplorerKit/Tests/FileMemoryTests/MoveMemberProcessTests.swift", Path(__file__).resolve(),
        ROOT/".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    report_root = admit(size=MIB, entries=12)
    report = dict(passed=False, inputs=hashes, cases=[])
    try:
        for scenario in scenarios:
            if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
                raise RuntimeError("Qualification inputs changed")
            case = admit(size=2*MIB, entries=64)
            row = dict(scenario=scenario, root=str(case.relative_to(ROOT)), phases=[]); report["cases"].append(row)
            for phase in ("seed", "fault" if scenario.startswith("fault") else "crash", "inspect", "recover", "cold"):
                if phase == "recover": row["beforeRecovery"] = archive_before_recovery(case)
                row["phases"].append(child(case, scenario, phase, worker="b074cMemberProcessWorker"))
            print(f"{scenario}: qualified", flush=True)
        if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
            raise RuntimeError("Qualification inputs changed")
        report["passed"] = True; report["usage"] = usage()
    finally:
        write(report_root/"report.json", report)
    print(f"Report: {report_root.relative_to(ROOT)}/report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
