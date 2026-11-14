#!/usr/bin/env python3
"""Native launch-profile acceptance in one admitted generated app profile."""
from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True
os.environ["MAC_EXPLORER_B07_CONTINUITY_MANAGEMENT"] = "1"
from verify_move_continuity import ROOT, MIB, admit, usage, write
from dev import environment

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--foreground", action="store_true")
    parser.add_argument("--drive-picker", action="store_true")
    args = parser.parse_args()
    case = admit(size=16*MIB, entries=256)
    print(f"Generated profile case: {case.relative_to(ROOT)}", flush=True)
    for name in ("Folder A", "Folder B"): (case/"source"/name).mkdir(mode=0o700)
    binary = ROOT/".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
    env = environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(case/"state"), MAC_EXPLORER_CACHE_ROOT=str(case/"cache"),
        MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB), MAC_EXPLORER_TEST_ROOT=str(case))
    with (case/"native.log").open("xb") as log:
        result = subprocess.run([str(binary), "-ApplePersistenceIgnoreState", "YES", "--verify-ui", "--check-launch-profiles",
            "--analysis-source", str(case)] + (["--drive-startup-picker"] if args.drive_picker else []) + ([] if args.foreground else ["--offscreen"]),
            cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=330 if args.drive_picker else 120)
    write(case/"exit.json", dict(exit=result.returncode))
    if result.returncode or not (case/"native.json").is_file(): raise RuntimeError(f"Profile acceptance failed; preserve {case.relative_to(ROOT)}")
    report = json.loads((case/"native.json").read_bytes())
    print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=report, usage=usage()), indent=2))
    if not report.get("passed"): raise RuntimeError("Profile acceptance did not pass")
    return 0

if __name__ == "__main__": raise SystemExit(main())
