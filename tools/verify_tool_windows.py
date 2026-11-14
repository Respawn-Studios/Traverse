#!/usr/bin/env python3
"""Small, generated-only native presentation checks; no operation fixtures."""
import argparse
import fcntl
import json
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment
from runtime_diagnostics import inspect

BASE = ROOT / ".build/tool-window-presentation"
MIB = 1024 * 1024

def write(path, value):
    with path.open("x", encoding="utf8") as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
    path.chmod(0o600)

def usage():
    total = entries = cases = 0
    for case in BASE.iterdir():
        if case.name == ".lock": continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir(): raise RuntimeError("Changed presentation fixture")
        paths, size, count = [case], 0, 0
        while paths:
            path = paths.pop(); info = path.lstat(); count += 1
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                raise RuntimeError("Unexpected presentation entry")
            size += max(info.st_size, info.st_blocks * 512)
            if stat.S_ISDIR(info.st_mode): paths.extend(path.iterdir())
            if size > 8*MIB or count > 128: raise RuntimeError("Presentation case exceeded allowance")
        cases += 1; total += size; entries += count
    return dict(cases=cases, observedBytes=total, observedEntries=entries)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", action="store_true")
    parser.add_argument("--offscreen", action="store_true")
    parser.add_argument("--render-case")
    parser.add_argument("--header-regression", action="store_true")
    parser.add_argument("--header-interactions-only", action="store_true")
    parser.add_argument("--force-header-redraw", action="store_true")
    args = parser.parse_args()
    if args.review and args.offscreen: raise RuntimeError("Visible review cannot be offscreen")
    if args.header_regression and not args.render_case: raise RuntimeError("Header checks reuse a completed read-only UI case")
    if args.header_interactions_only and not args.header_regression: raise RuntimeError("Focused header interaction mode needs the header regression")
    if args.force_header_redraw and not args.header_regression: raise RuntimeError("Redraw probe needs the header regression")
    BASE.mkdir(mode=0o700, exist_ok=True)
    if BASE.resolve() != BASE: raise RuntimeError("Redirected presentation root")
    with (BASE/".lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = usage()
        if args.render_case:
            if str(uuid.UUID(args.render_case)).upper() != args.render_case or args.offscreen:
                raise RuntimeError("Expected exact completed generated case")
            case = BASE/args.render_case
            if json.loads((case/"exit.json").read_bytes()) != dict(exit=0) or not json.loads((case/"native.json").read_bytes()).get("passed"):
                raise RuntimeError("Render needs a completed passed case")
            if (case/"Files/Report.txt").read_bytes() != b"Generated tool-window fixture.\n": raise RuntimeError("Changed generated source")
            for old in case.glob("render-*"):
                if not (old/"exit.json").is_file(): raise RuntimeError("Prior render has not drained")
            retained = list(case.rglob("*"))
            charged = sum(max(p.lstat().st_size, p.lstat().st_blocks * 512) for p in [case, *retained])
            if len(retained) > 100 or charged > 6*MIB: raise RuntimeError("Insufficient render headroom")
            output = case/("render-"+str(uuid.uuid4()).upper()); output.mkdir(mode=0o700)
            write(output/"render.json", dict(readOnlyCatalog=True, generatedOnly=True))
        else:
            if current["cases"] >= 4: raise RuntimeError("Presentation sessions fully reserved")
            case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
            write(case/"reservation.json", dict(version=1, bytes=8*MIB, entries=128, generatedOnly=True))
            files = case/"Files"; files.mkdir(mode=0o700)
            (files/"Folder").mkdir(mode=0o700)
            (files/"Report.txt").write_bytes(b"Generated tool-window fixture.\n")
            output = case
    app = ROOT/".build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer"
    command = [str(app), "-ApplePersistenceIgnoreState", "YES", "--verify-ui", "--check-tool-windows", "--analysis-source", str(case)]
    if args.render_case:
        command[command.index("--check-tool-windows")] = "--render-tool-window"
        command += ["--tool-output", str(output)]
    if args.review: command.append("--show-tool-window-review")
    if args.header_regression: command.append("--check-header-presentation")
    if args.header_interactions_only: command.append("--header-interactions-only")
    if args.force_header_redraw: command.append("--force-header-redraw")
    if args.offscreen: command.append("--offscreen")
    env = environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(output/"state"), MAC_EXPLORER_CACHE_ROOT=str(output/"cache"),
               MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
    print(f"Generated native tool-window check: {output}", flush=True)
    with (output/"native.log").open("xb") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        write(output/"launch.json", dict(pid=process.pid, generatedOnly=True))
        code = process.wait(timeout=None if args.review else 90)
    write(output/"exit.json", dict(exit=code))
    diagnostics = inspect(output/"native.log")
    write(output/"diagnostics.json", diagnostics)
    report = json.loads((output/"native.json").read_bytes()) if (output/"native.json").is_file() else {}
    if code or not report.get("passed") or not diagnostics["passed"]:
        raise RuntimeError(f"Native presentation checks failed; evidence preserved: {output}")
    print(json.dumps(dict(root=str(output.relative_to(ROOT)), report=report, usage=usage()), indent=2))

if __name__ == "__main__":
    main()
