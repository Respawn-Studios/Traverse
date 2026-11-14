#!/usr/bin/env python3
"""B07.4 bounded generated-only process and native workspace qualification."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
import shutil
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment

EXTENDED = os.environ.get("MAC_EXPLORER_B07_CONTINUITY_MANAGEMENT") == "1"
BASE = ROOT / (".build/b07-continuity-management" if EXTENDED else ".build/b07-move-continuity")
MIB = 1024**2
MAX_BYTES = (2048 if EXTENDED else 512)*MIB
MAX_ENTRIES = 65536 if EXTENDED else 10240
MAX_EVIDENCE = (32 if EXTENDED else 16)*MIB

def write(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf8") as output:
        json.dump(value, output, sort_keys=True, indent=2); output.write("\n")
    path.chmod(0o600)

def observed(root: Path) -> tuple[int, int, int]:
    stack, size, entries, evidence = [root], 0, 0, 0
    while stack:
        path = stack.pop(); info = path.lstat()
        # Hostile source/reference controls may contain symlinks or special
        # nodes. Count their own lstat allocation, never follow/open them.
        charge = max(info.st_size, info.st_blocks * 512)
        size += charge; entries += 1
        if size > MAX_BYTES or entries > MAX_ENTRIES: raise RuntimeError("Bounded scan exhausted")
        if stat.S_ISDIR(info.st_mode): stack.extend(path.iterdir())
        elif stat.S_ISREG(info.st_mode) and path.suffix in (".json", ".log", ".png"): evidence += charge
    return size, entries, evidence

def usage() -> dict:
    if BASE.resolve() != BASE: raise RuntimeError("Redirected qualification root")
    result = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, evidence=0)
    for case in BASE.iterdir():
        if case.name == ".budget.lock": continue
        uuid.UUID(case.name)
        if case.resolve() != case or not case.is_dir(): raise RuntimeError("Unknown qualification entry")
        reservation = json.loads((case / "reservation.json").read_bytes())
        size, entries, evidence = observed(case)
        if size > reservation["bytes"] or entries > reservation["entries"] or reservation["bytes"] > 64*MIB:
            raise RuntimeError("A preserved case exceeds admission")
        if os.path.lexists(case / "internal-root.json"):
            # The retired external side is not inspected. Keep its entire
            # saved reservation charged while reporting local evidence only.
            size, entries = reservation["bytes"], reservation["entries"]
        result["bytes"] += size; result["entries"] += entries; result["evidence"] += evidence
        result["reservedBytes"] += reservation["bytes"]; result["reservedEntries"] += reservation["entries"]
    if result["reservedBytes"] > MAX_BYTES or result["reservedEntries"] > MAX_ENTRIES or result["evidence"] > MAX_EVIDENCE:
        raise RuntimeError("B07.4 allowance exhausted")
    return result

def admit(size: int = 4*MIB, entries: int = 64) -> Path:
    BASE.mkdir(mode=0o700, exist_ok=True)
    with (BASE/".budget.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = usage()
        if size > 64*MIB or before["reservedBytes"]+size > MAX_BYTES or before["reservedEntries"]+entries > MAX_ENTRIES:
            raise RuntimeError("Insufficient B07.4 headroom")
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        write(case/"reservation.json", dict(bytes=size, entries=entries))
        for name in ("source", "destination"): (case/name).mkdir(mode=0o700)
        return case

def tab_replay(case_id: str) -> tuple[Path, Path]:
    """Reuse only unchanged read-only UI inputs; preserve every earlier output."""
    token = uuid.UUID(case_id)
    if str(token).upper() != case_id: raise RuntimeError("Expected exact generated case ID")
    with (BASE/".budget.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); usage()
        case = BASE/case_id
        report = json.loads((case/"native.json").read_bytes())
        if not report.get("passed") or "motionEnabled" not in report or json.loads((case/"exit.json").read_bytes()) != dict(exit=0):
            raise RuntimeError("Only a completed tab-only case can be replayed")
        if any(os.path.lexists(case/name) for name in ("names", "history", "internal-root.json")):
            raise RuntimeError("Catalog/operation cases cannot be replayed")
        for previous in case.iterdir():
            if previous.name.startswith("tab-replay-") and (previous.resolve()!=previous or not (previous/"exit.json").is_file()):
                raise RuntimeError("A prior tab replay has not drained")
        source = case/"source"
        if source.resolve() != source or {p.name for p in source.iterdir()} != {"Document.txt", "Second.txt", "Folder"}:
            raise RuntimeError("Changed read-only tab fixture")
        identities = {}
        for name in ("Document.txt", "Second.txt"):
            path=source/name; info=path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or path.read_bytes() != b"Generated B07.4 workspace fixture\n":
                raise RuntimeError("Changed generated tab file")
            identities[name]=dict(device=info.st_dev,inode=info.st_ino,bytes=info.st_size)
        for path in (source/"Folder", case/"destination"):
            if path.resolve()!=path or not path.is_dir() or any(path.iterdir()): raise RuntimeError("Changed generated tab directory")
        reserved=json.loads((case/"reservation.json").read_bytes()); size,entries,_=observed(case)
        if reserved["bytes"]-size < 768*1024 or reserved["entries"]-entries < 16:
            raise RuntimeError("Insufficient retained-case headroom")
        output=case/("tab-replay-"+str(uuid.uuid4()).upper()); output.mkdir(mode=0o700)
        write(output/"replay.json",dict(version=1,case=case_id,source=identities,readOnlyInputs=True))
        return case,output

def child(case: Path, scenario: str, phase: str, *, worker: str = "b074MoveProcessWorker") -> dict:
    if os.path.lexists(case / "internal-root.json"):
        raise RuntimeError("Retired external-root case cannot be replayed")
    env = environment()
    env.update(MAC_EXPLORER_B07_MOVE_PACKET="1", MAC_EXPLORER_B074_ROOT=str(case),
               MAC_EXPLORER_B074_SCENARIO=scenario, MAC_EXPLORER_B074_PHASE=phase)
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    helper = swift.parent.parent/"libexec/swift/pm/swiftpm-testing-helper"
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer/"Platforms/MacOSX.platform/Developer"
    env["DYLD_FRAMEWORK_PATH"] = str(platform/"Library/Frameworks")
    env["DYLD_LIBRARY_PATH"] = str(platform/"usr/lib")
    binary = ROOT/".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"
    with (case/(phase+".log")).open("xb") as output:
        result = subprocess.run([str(helper), "--test-bundle-path", str(binary), "--testing-library", "swift-testing",
            "--filter", worker], cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=60)
    receipt = case/(phase+".json")
    expected = 86 if phase == "crash" else 0
    if result.returncode != expected or not receipt.is_file() or receipt.stat().st_size > 8192:
        raise RuntimeError(f"Boundary not proved: {scenario}/{phase}; see {case.relative_to(ROOT)}/{phase}.log")
    value = json.loads(receipt.read_bytes())
    if value.get("phase") != phase or value.get("scenario") != scenario: raise RuntimeError("Mismatched child receipt")
    usage()
    return dict(phase=phase, exit=result.returncode, result=value, sha256=hashlib.sha256(receipt.read_bytes()).hexdigest())

def archive_before_recovery(case: Path) -> dict:
    archive = case/"before-recovery"; archive.mkdir(mode=0o700)
    result = {}
    for path in (case/"names").iterdir():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 4*MIB:
            raise RuntimeError("Unsafe generated archive input")
        before = path.read_bytes()
        shutil.copyfile(path, archive/path.name); (archive/path.name).chmod(0o600)
        after = path.lstat()
        if before != (archive/path.name).read_bytes() or before != path.read_bytes() or (info.st_ino, info.st_mtime_ns, info.st_ctime_ns) != (after.st_ino, after.st_mtime_ns, after.st_ctime_ns):
            raise RuntimeError("Changed archive input")
        result[path.name] = dict(sha256=hashlib.sha256(before).hexdigest(), inode=info.st_ino, bytes=info.st_size)
    write(archive/"receipt.json", result); usage()
    return result

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--review", action="store_true")
    parser.add_argument("--audit", action="store_true")
    parser.add_argument("--compat", action="store_true")
    parser.add_argument("--tracking-candidate", action="store_true")
    parser.add_argument("--tracking", action="store_true")
    parser.add_argument("--integration", action="store_true")
    parser.add_argument("--motion", action="store_true")
    parser.add_argument("--tabs", action="store_true")
    parser.add_argument("--replay-tab-case")
    parser.add_argument("--scenario", action="append")
    args = parser.parse_args()
    if args.tracking_candidate or args.tracking or args.integration or args.motion:
        raise RuntimeError("Retired cross-drive tracking and integration routes cannot run")
    if args.replay_tab_case and not args.tabs: parser.error("Read-only replay requires --tabs")
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    if args.compat:
        case = admit(size=32*MIB, entries=128)
        revision = subprocess.check_output(["git", "rev-parse", "258fb2a^{commit}"], cwd=ROOT, text=True).strip()
        prefix = "Packages/ExplorerKit/Sources/FileMemory/"
        files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", revision, prefix], cwd=ROOT, text=True).splitlines()
        source_root = case/"frozen-v2-sources"; source_root.mkdir(mode=0o700)
        sources, hashes = [], {}
        for file in files:
            if not file.startswith(prefix) or not file.endswith(".swift"): raise RuntimeError("Unexpected frozen source")
            data = subprocess.check_output(["git", "show", revision+":"+file], cwd=ROOT)
            destination = source_root/Path(file).name
            destination.write_bytes(data); sources.append(str(destination)); hashes[file] = hashlib.sha256(data).hexdigest()
        products = ROOT/".build/swift-tests/out/Products/Debug"
        binary = case/"frozen-v2-probe"
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-warnings-as-errors", "-module-name", "FrozenV2FileMemory",
            "-I", str(products), "-L", str(products), "-lLocalStorage", "-lExplorerCore", "-lsqlite3",
            "-module-cache-path", str(ROOT/".build/compiler-cache/swift"), *sources,
            str(ROOT/"tools/qualification/FrozenV2NameStoreProbe.swift"), "-o", str(binary)]
        with (case/"frozen-compile.log").open("xb") as output:
            subprocess.run(command, cwd=ROOT, env=environment(), stdout=output, stderr=subprocess.STDOUT, check=True, timeout=90)
        child(case, "compat", "seed")
        with (case/"frozen-run.log").open("xb") as output:
            subprocess.run([str(binary), str(case)], cwd=ROOT, env=environment(tooling=False), stdout=output, stderr=subprocess.STDOUT, check=True, timeout=30)
        result = json.loads((case/"frozen-v2.json").read_bytes())
        if not all(result.values()): raise RuntimeError("Frozen v2 refusal failed")
        write(case/"compatibility.json", dict(passed=True, revision=revision, sources=hashes,
            binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), result=result, usage=usage()))
        print(f"Frozen v2 inspection/writable refusal: passed; {case.relative_to(ROOT)}"); return 0
    if args.native or args.review or args.tabs:
        # The first tab case reserved 2 MiB; observed native evidence was below
        # 128 KiB. A fresh presentation-only regression fits in 1 MiB without
        # discounting that retained reservation or changing the packet ceiling.
        if args.replay_tab_case:
            case,output = tab_replay(args.replay_tab_case)
        else:
            case = admit(size=MIB if args.tabs else 8*MIB, entries=64)
            output=case
            for name in ("Document.txt", "Second.txt"): (case/"source"/name).write_bytes(b"Generated B07.4 workspace fixture\n")
            (case/"source/Folder").mkdir()
        app = ROOT/".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
        mode = "--check-tab-motion" if args.tabs else "--check-move-workspace"
        command = [str(app), "-ApplePersistenceIgnoreState", "YES", "--verify-ui", mode, "--analysis-source", str(case)]
        if args.replay_tab_case: command += ["--tab-output",str(output)]
        command += ["--show-move-workspace-review"] if args.review else ["--offscreen"]
        env = environment(tooling=False)
        env.update(MAC_EXPLORER_STATE_ROOT=str(output/"state"), MAC_EXPLORER_CACHE_ROOT=str(output/"cache"),
            MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(MIB//2 if args.tabs else 4*MIB))
        with (output/"native.log").open("xb") as log:
            if args.review:
                process = subprocess.Popen(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                write(output/"launch.json", dict(pid=process.pid, generated=True))
                print(f"Generated workspace review: {output}", flush=True)
                code = process.wait()
                write(output/"exit.json", dict(exit=code))
                if code or not (output/"native.json").is_file(): raise RuntimeError("Generated review closed before checks passed")
                usage()
                return 0
            result = subprocess.run(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        write(output/"exit.json", dict(exit=result.returncode))
        if result.returncode or not (output/"native.json").is_file(): raise RuntimeError(f"Native checks failed: {output.relative_to(ROOT)}")
        report = json.loads((output/"native.json").read_bytes())
        if not report.get("passed"): raise RuntimeError("Native checks did not pass")
        print(json.dumps(dict(root=str(output.relative_to(ROOT)), report=report, usage=usage()), indent=2)); return 0
    report_case = admit(size=MIB, entries=12)
    inputs = sorted((ROOT/"Packages/ExplorerKit/Sources/FileMemory").glob("*.swift"))
    inputs += sorted((ROOT/"Packages/ExplorerKit/Sources/FileOperations").glob("*.swift"))
    inputs += [ROOT/"Packages/ExplorerKit/Tests/FileMemoryTests/MoveProcessTests.swift", Path(__file__).resolve()]
    binary = ROOT/".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"
    inputs += [binary]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    stamps = {path: (path.stat().st_ino, path.stat().st_size, path.stat().st_mtime_ns) for path in inputs}
    report = dict(passed=False, inputs=hashes, cases=[])
    scenarios = args.scenario or ["moveUpgradeRows", "moveUpgradeCommit", "moveIntentRows", "moveIntentCommit", "fileMoveCommit",
        "moveReferenceRows", "moveReferenceCommit", "moveUndoIntentRows", "moveUndoIntentCommit", "fileUndoCommit",
        "undoReferenceRows", "undoReferenceCommit", "faultIntentWrite", "faultIntentSync", "faultReferenceSync"]
    try:
        for scenario in scenarios:
            if any((path.stat().st_ino, path.stat().st_size, path.stat().st_mtime_ns) != stamp for path, stamp in stamps.items()):
                raise RuntimeError("Qualification inputs changed during run")
            # Measured tiny catalogs + their exact pre-recovery archive fit
            # below 1 MiB / 48 entries. Larger reservations remain charged.
            case = admit(size=MIB, entries=48); row = dict(scenario=scenario, root=str(case.relative_to(ROOT)), phases=[]); report["cases"].append(row)
            for phase in ("seed", "fault" if scenario.startswith("fault") else "crash", "inspect", "recover", "cold"):
                if phase == "recover": row["beforeRecovery"] = archive_before_recovery(case)
                row["phases"].append(child(case, scenario, phase))
            print(f"{scenario}: qualified", flush=True)
        if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
            raise RuntimeError("Qualification inputs changed during run")
        report["passed"] = True; report["usage"] = usage()
    finally:
        write(report_case/"report.json", report)
    print(f"Report: {report_case.relative_to(ROOT)}/report.json"); return 0

if __name__ == "__main__":
    raise SystemExit(main())
