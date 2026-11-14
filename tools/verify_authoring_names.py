#!/usr/bin/env python3
"""B07.3 generated-only native authoring and process qualification."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from dev import ROOT, environment
import verify_private_names_process as packet

packet.BASE = ROOT / ".build/b07-authoring-search"
packet.LIMIT = 512 * 1024**2
packet.ENTRY_LIMIT = 8192


def child(case: Path, scenario: str, phase: str, *, crash: bool = False) -> dict:
    env = environment()
    env.update(MAC_EXPLORER_B07_AUTHORING_PACKET="1", MAC_EXPLORER_B073_ROOT=str(case),
               MAC_EXPLORER_B073_SCENARIO=scenario, MAC_EXPLORER_B073_PHASE=phase)
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    env["DYLD_FRAMEWORK_PATH"] = str(platform / "Library/Frameworks")
    env["DYLD_LIBRARY_PATH"] = str(platform / "usr/lib")
    binary = ROOT / ".build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests"
    log = case / (phase + ".log")
    with log.open("xb") as output:
        result = subprocess.run([str(helper), "--test-bundle-path", str(binary), "--testing-library", "swift-testing",
                                 "--filter", "b073AuthoringProcessWorker"], env=env, cwd=ROOT,
                                stdout=output, stderr=subprocess.STDOUT, timeout=60)
    receipt = case / (phase + ".json")
    if result.returncode != (86 if crash else 0) or not receipt.is_file() or receipt.stat().st_size > 4096:
        raise RuntimeError(f"Authoring child did not prove {scenario}/{phase}; see {log.relative_to(ROOT)}")
    value = json.loads(receipt.read_bytes())
    if value.get("phase") != phase or (crash and value.get("terminationCode") != "86"):
        raise RuntimeError("Requested boundary was not proved")
    packet.usage()
    return dict(phase=phase, exit=result.returncode, receipt=hashlib.sha256(receipt.read_bytes()).hexdigest(), result=value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--review", action="store_true")
    args = parser.parse_args()
    if args.native or args.review:
        case = packet.admit(entries=256, size=4 * 1024**2)
        files = case / "Files"; files.mkdir(mode=0o700)
        for name in ("Actual report.txt", "Second report.txt", "Outside.txt"):
            (files / name).write_bytes(b"Generated private names UI fixture\n")
        (files / "Folder").mkdir(mode=0o700)
        (files / "Scope").mkdir(mode=0o700)
        (files / "Scope/Scoped.txt").write_bytes(b"Generated scoped file\n")
        app = ROOT / ".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
        command = [str(app), "-ApplePersistenceIgnoreState", "YES", "--verify-ui", "--check-private-names", "--analysis-source", str(case)]
        if args.review: command += ["--show-private-names-review"]
        else: command += ["--offscreen"]
        env = environment(tooling=False)
        log = case / "native.log"
        with log.open("xb") as output:
            if args.review:
                process = subprocess.Popen(command, env=env, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                packet.write_json(case / "launch.json", dict(pid=process.pid, generated=True))
                print(f"Generated review: {case}"); return 0
            result = subprocess.run(command, env=env, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=120)
        packet.write_json(case / "native-exit.json", dict(exit=result.returncode))
        if result.returncode or not (case / "native.json").is_file():
            raise RuntimeError(f"Native checks failed (exit {result.returncode}); see {log.relative_to(ROOT)}")
        value = json.loads((case / "native.json").read_bytes())
        if not value.get("passed"): raise RuntimeError("Native checks did not pass")
        print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=value, usage=packet.usage()), indent=2)); return 0
    report_case = packet.admit(entries=6, size=1024**2)
    report = dict(passed=False, cases=[])
    try:
        for scenario in ("beforeFlag", "afterFlag", "committedNames", "faultSync"):
            case = packet.admit(entries=32, size=4 * 1024**2)
            row = dict(scenario=scenario, root=str(case.relative_to(ROOT)), phases=[]); report["cases"].append(row)
            for phase in ("seed", "fault" if scenario == "faultSync" else "crash", "inspect", "recover", "cold"):
                row["phases"].append(child(case, scenario, phase, crash=phase == "crash"))
        report["passed"] = True; report["usage"] = packet.usage()
    finally:
        packet.write_json(report_case / "process-report.json", report)
    print(f"Authoring process checks passed: {report_case.relative_to(ROOT)}/process-report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
