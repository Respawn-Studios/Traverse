#!/usr/bin/env python3
"""One generated metadata scale run; retained reservations never recycle."""
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
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment

MIB = 1024**2
BASE = ROOT/".build/b07-integrated-acceptance"

def usage() -> dict:
    if BASE.resolve() != BASE: raise RuntimeError("Redirected packet root")
    total = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, metadata=0, evidence=0)
    for case in BASE.iterdir():
        if case.name == ".budget.lock": continue
        uuid.UUID(case.name)
        if case.resolve() != case or not case.is_dir(): raise RuntimeError("Unknown case")
        reservation = json.loads((case/"reservation.json").read_bytes())
        size, entries, metadata, evidence, pending = 0, 0, 0, 0, [case]
        while pending:
            path = pending.pop(); info = path.lstat()
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)): raise RuntimeError("Unexpected fixture node")
            amount = max(info.st_size, info.st_blocks*512); size += amount; entries += 1
            if stat.S_ISDIR(info.st_mode): pending.extend(path.iterdir())
            elif path.parent == case/"metadata": metadata += amount
            elif path.suffix in (".json", ".log", ".png"): evidence += amount
        if size > reservation["bytes"] or entries > reservation["entries"] or reservation["bytes"] > 256*MIB:
            raise RuntimeError("Case exceeded admission")
        for name, value in dict(bytes=size, entries=entries, reservedBytes=reservation["bytes"],
                reservedEntries=reservation["entries"], metadata=metadata, evidence=evidence).items(): total[name] += value
    if total["reservedBytes"] > 1024*MIB or total["reservedEntries"] > 4096 or total["metadata"] > 64*MIB or total["evidence"] > 16*MIB:
        raise RuntimeError("Integrated acceptance allowance exhausted")
    return total

def admit() -> Path:
    BASE.mkdir(mode=0o700, exist_ok=True)
    with (BASE/".budget.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); before = usage()
        if before["reservedBytes"]+256*MIB > 1024*MIB or before["reservedEntries"]+128 > 4096 or before["metadata"]+16*MIB > 64*MIB:
            raise RuntimeError("Insufficient scale headroom")
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/"reservation.json").write_text(json.dumps(dict(bytes=256*MIB, entries=128)))
        for name in ("metadata", "evidence"): (case/name).mkdir(mode=0o700)
        return case

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--count", type=int, choices=(10000, 100000), default=100000)
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--audit", action="store_true"); args = parser.parse_args()
    if args.audit: print(json.dumps(usage(), indent=2)); return 0
    case = admit(); namespace = uuid.uuid4()
    with (case/"metadata/input.json").open("x", encoding="utf8") as output:
        output.write('{"format":"MacExplorer.PrivateNames","version":1,"includesLocations":false,"records":[')
        for i in range(args.count):
            if i: output.write(",")
            json.dump(dict(id=str(uuid.uuid5(namespace, str(i))).upper(), nickname=f"Project {i:06}", alternateNames=[], labels=[]), output, separators=(",", ":"))
        output.write("]}")
    for path in case.rglob("*"):
        if path.is_file(): path.chmod(0o600)
    usage()
    if args.native:
        if args.count != 100000: raise RuntimeError("Native scale requires100k")
        binary = ROOT/".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
        env = environment(tooling=False)
        env.update(MAC_EXPLORER_STATE_ROOT=str(case/"state"), MAC_EXPLORER_CACHE_ROOT=str(case/"cache"))
        with (case/"evidence/native.log").open("xb") as log:
            result = subprocess.run([str(binary), "-ApplePersistenceIgnoreState", "YES", "--verify-ui", "--offscreen",
                "--check-private-import-scale", "--analysis-source", str(case)], cwd=ROOT, env=env,
                stdout=log, stderr=subprocess.STDOUT, timeout=180)
        (case/"evidence/exit.json").write_text(json.dumps(dict(exit=result.returncode)))
        if result.returncode or not (case/"evidence/native.json").is_file(): raise RuntimeError(f"Native scale failed: {case}")
        report = json.loads((case/"evidence/native.json").read_bytes())
        print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=report, usage=usage()), indent=2))
        if not report.get("passed"): raise RuntimeError("Native scale gates not met")
        return 0
    env = environment(); env.update(MAC_EXPLORER_B075_SCALE_ROOT=str(case), MAC_EXPLORER_B075_SCALE_COUNT=str(args.count))
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    platform = developer/"Platforms/MacOSX.platform/Developer"
    env["DYLD_FRAMEWORK_PATH"] = str(platform/"Library/Frameworks"); env["DYLD_LIBRARY_PATH"] = str(platform/"usr/lib")
    binary = ROOT/".build/swift-tests-release/out/Products/Release/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"
    inputs = sorted((ROOT/"Packages/ExplorerKit/Sources/FileMemory").glob("*.swift")) + [binary,
        ROOT/"Packages/ExplorerKit/Tests/FileMemoryTests/NameImportScaleTests.swift", Path(__file__).resolve(), case/"metadata/input.json"]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    (case/"evidence/provenance.json").write_text(json.dumps(hashes, sort_keys=True))
    with (case/"evidence/process.log").open("xb") as log:
        result = subprocess.run([str(swift.parent.parent/"libexec/swift/pm/swiftpm-testing-helper"),
            "--test-bundle-path", str(binary), "--testing-library", "swift-testing", "--filter", "b075ImportScaleWorker"],
            cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    (case/"evidence/exit.json").write_text(json.dumps(dict(exit=result.returncode)))
    if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
        raise RuntimeError("Scale inputs changed during qualification")
    print(json.dumps(dict(root=str(case.relative_to(ROOT)), usage=usage()), indent=2))
    if result.returncode: raise RuntimeError(f"Scale run failed; preserve {case.relative_to(ROOT)}")
    metrics = json.loads((case/"evidence/metrics.json").read_bytes()); print(json.dumps(metrics, indent=2))
    if not metrics["passed"]: raise RuntimeError("Scale gates not met")
    return 0

if __name__ == "__main__": raise SystemExit(main())
