#!/usr/bin/env python3
"""Resolve/fetch/build only one approved standalone candidate at a time."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from packet import TOOLING_LIMIT, MIB, PACKET, PINS, REPO, TOOLCHAIN, TOOLING, digest, directory, environment, put, usage, reserve


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", choices=[*PINS, "smb2-auth"])
    parser.add_argument("action", choices=["resolve", "fetch", "build", "test", "metadata"])
    args = parser.parse_args()
    directory(PACKET)
    before = usage(TOOLING, TOOLING_LIMIT)
    # Locked offline incremental actions require 112 MiB of starting room;
    # monitor a 96 MiB stop margin while compiling the small additional crate.
    # Acquisition/resolution still requires the larger 256 MiB reserve.
    headroom = (112 if args.action in ["build", "test"] else 256) * MIB
    if before["bytes"] + headroom > TOOLING_LIMIT:
        raise RuntimeError("No B10 build headroom")
    source_candidate = "smb2" if args.candidate == "smb2-auth" else args.candidate
    revision = PINS[source_candidate][1]
    acquired = TOOLING / (source_candidate + "-" + revision)
    receipt = json.loads((acquired / "acquisition.json").read_bytes())
    if receipt["revision"] != revision or digest(acquired / "upstream.tar.gz") != receipt["sha256"]:
        raise RuntimeError("Changed immutable upstream archive")
    authenticated = args.candidate == "smb2-auth"
    if authenticated and args.action in ["resolve", "fetch"]:
        raise RuntimeError("Auth experiment reuses the frozen offline dependency graph")
    qualified = acquired / ("qualified-auth" if authenticated else "qualified")
    if not qualified.exists():
        if authenticated: raise RuntimeError("Prepare the recorded authenticated fork first")
        shutil.copytree(acquired / "source", qualified)
    delta = acquired / ("auth-delta.json" if authenticated else "qualification-delta.json")
    for item in json.loads(delta.read_bytes())["changes"]:
        if digest(qualified / item["path"]) != item["qualifiedSHA256"]:
            raise RuntimeError("Recorded experimental source changed")
    case = reserve(args.action, candidate=args.candidate, amount=(4 if authenticated else 16) * MIB)
    manifest = REPO / "tools/smb_reader" / args.candidate / "Cargo.toml"
    command = [str(TOOLCHAIN / "bin/cargo")]
    command += ["generate-lockfile"] if args.action == "resolve" else [args.action]
    command += ["--manifest-path", str(manifest)]
    if args.action != "resolve":
        command += ["--locked"]
    if args.action in ["build", "test"]:
        command += ["--release", "--offline", "--jobs", "4"]
    if authenticated and args.action == "test":
        command += ["--no-run", "--message-format=json"] # Separate runner owns loopback permission.
    if args.action == "metadata":
        command += ["--format-version", "1", "--offline", "--filter-platform", "aarch64-apple-darwin"]
    env = environment()
    env["SDKROOT"] = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    env["CARGO_PROFILE_DEV_DEBUG"] = "0"
    started = time.monotonic()
    owned_sources = {str(path.relative_to(REPO)): path.read_text() for path in manifest.parent.rglob("*.rs")}
    owned_sources["tools/smb_reader/common.rs"] = (REPO / "tools/smb_reader/common.rs").read_text()
    if source_candidate == "smb2":
        owned_sources["tools/smb_reader/directory_validation.rs"] = (REPO / "tools/smb_reader/directory_validation.rs").read_text()
    if authenticated:
        owned_sources["tools/smb_reader/auth_security.rs"] = (REPO / "tools/smb_reader/auth_security.rs").read_text()
    put(case / "qualification-sources.json", dict(harness=owned_sources,
        delta=json.loads(delta.read_bytes())))
    put(case / "inputs.json", dict(command=command, manifest=digest(manifest), revision=revision, before=before, toolingHeadroom=headroom,
                                    compiler=subprocess.check_output([str(TOOLCHAIN / "bin/rustc"), "-vV"], env=env, text=True)))
    reason = None
    accounting_error = None
    with (case / "command.log").open("xb") as output:
        process = subprocess.Popen(command, cwd=manifest.parent, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        put(case / "process.json", dict(pid=process.pid, ownProcessGroup=process.pid))
        while process.poll() is None:
            time.sleep(1)
            try:
                current = usage(TOOLING, TOOLING_LIMIT, building=True)
                if current["bytes"] > (TOOLING_LIMIT) - 96 * MIB:
                    reason = "tooling safety margin reached"
                elif (case / "command.log").stat().st_size > (1 if authenticated else 8) * MIB:
                    reason = "log cap reached"
                elif time.monotonic() - started > 240:
                    reason = "build action deadline"
            except Exception as error:
                reason = "tooling accounting refused"
                accounting_error = type(error).__name__ + ": " + str(error)[:256]
            if reason:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        returncode = process.wait()
    lock = manifest.parent / "Cargo.lock"
    binary = TOOLING / "target/release" / ("macexplorer-" + args.candidate + "-qualification")
    result = dict(candidate=args.candidate, action=args.action, returncode=returncode,
                  interrupted=reason, elapsedSeconds=time.monotonic() - started,
                  accountingError=accounting_error,
                  after=usage(TOOLING, TOOLING_LIMIT), logBytes=(case / "command.log").stat().st_size,
                  lockSHA256=digest(lock) if lock.exists() else None)
    if args.action == "build" and returncode == 0 and reason is None:
        result["binarySHA256"] = digest(binary)
    if authenticated and args.action == "test" and returncode == 0 and reason is None:
        tests = []
        for line in (case / "command.log").read_text().splitlines():
            try: artifact = json.loads(line)
            except json.JSONDecodeError: continue
            if artifact.get("reason") == "compiler-artifact" and artifact.get("profile", {}).get("test") is True and artifact.get("executable"):
                test = Path(artifact["executable"])
                test.relative_to(TOOLING / "target/release/deps")
                if not test.is_file() or not os.access(test, os.X_OK): raise RuntimeError("Reported test executable missing")
                tests.append(test)
        if len(tests) != 1: raise RuntimeError("Ambiguous authenticated test executable")
        result.update(testBinarySHA256=digest(tests[0]), testExecutable=str(tests[0].relative_to(TOOLING)),
                      testExecution="compiled only; separate offline runner required")
    put(case / "result.json", result)
    print(json.dumps(dict(case=str(case.relative_to(REPO)), **result), sort_keys=True), flush=True)
    if returncode or reason:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
