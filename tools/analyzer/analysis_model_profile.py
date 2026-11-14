#!/usr/bin/env python3
"""Build and observe the pure accounting model; create no filesystem fixtures."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
from packet import BASE, REPO, budget, create_directory, directory_fd, put

PROJECTION = dict(entries=100, logical=8 << 20, allocated=16 << 20)
TOOLS_LIMIT = 2 << 30
CACHE = REPO / ".build/compiler-cache/swift"
FROZEN = {
    "tools/analyzer/AnalyzerNative.h": "d3e31660adb87a8f3b8637ae075aa2533fdc495222a1420bd1689aad052eb819",
    ".build/b06-analyzer/tool-build/AnalyzerNative.o": "6d0dfafca8910568b684316717469ca0015ddb99aa8b96a77673ea3a5e7e1a60",
}
SOURCES = [REPO / "Packages/ExplorerKit/Sources/StorageAnalysis/AnalysisModels.swift",
           REPO / "Packages/ExplorerKit/Sources/StorageAnalysis/StorageAnalysisAccumulator.swift",
           REPO / "tools/analyzer/analysis_model_profile.swift"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def allocation(root: Path) -> dict:
    counts = dict(entries=0, logical=0, allocated=0)
    pending = [root]
    while pending:
        path = pending.pop()
        observed = path.lstat()
        counts["entries"] += 1
        counts["allocated"] += observed.st_blocks * 512
        if stat.S_ISDIR(observed.st_mode):
            descriptor = directory_fd(path)
            try:
                with os.scandir(descriptor) as children:
                    pending.extend(path / entry.name for entry in children)
            finally:
                os.close(descriptor)
        elif stat.S_ISREG(observed.st_mode):
            counts["logical"] += observed.st_size
        else:
            raise ValueError("Unexpected redirected tooling entry")
    return counts


def tools_usage() -> dict:
    roots = [REPO / ".build/b06-toolchain"]
    descriptor = directory_fd(BASE)
    try:
        with os.scandir(descriptor) as children:
            for entry in children:
                if entry.name.endswith("-build") or entry.name.startswith("model-profile-"):
                    if not entry.is_dir(follow_symlinks=False):
                        raise ValueError("Redirected analyzer tooling root")
                    roots.append(BASE / entry.name)
    finally:
        os.close(descriptor)
    return {str(root.relative_to(REPO)): allocation(root) for root in roots}


def verify_frozen() -> None:
    for relative, expected in FROZEN.items():
        path = REPO / relative
        if path.resolve() != path or sha(path) != expected:
            raise ValueError("Frozen metric helper changed: " + relative)


def main() -> None:
    verify_frozen()
    initial_budget = budget(**{"projected_" + key: value for key, value in PROJECTION.items()})
    before_cache = allocation(CACHE)
    before_tools = tools_usage()
    if sum(value["allocated"] for value in before_tools.values()) + PROJECTION["allocated"] > TOOLS_LIMIT:
        raise ValueError("Pure model tooling admission exceeded")
    output = BASE / ("model-profile-" + uuid.uuid4().hex)
    create_directory(output)
    create_directory(output / "tmp")
    receipt = output / "receipt.json"
    record = dict(schema=1, complete=False, scope="pure in-memory model only", projected=PROJECTION,
                  initial_budget=initial_budget, before_cache=before_cache, before_tools=before_tools,
                  frozen=FROZEN, sources={str(path.relative_to(REPO)): sha(path) for path in SOURCES},
                  runner_sha256=sha(Path(__file__).resolve()), observations=[])
    failed: Exception | None = None
    try:
        compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "swiftc"], text=True).strip()
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
        binary = output / "analysis-model-profile"
        argv = [compiler, "-O", "-whole-module-optimization", "-target", "arm64-apple-macosx15.0",
                "-sdk", sdk, "-import-objc-header", str(REPO / "tools/analyzer/AnalyzerNative.h"),
                *map(str, SOURCES), str(REPO / ".build/b06-analyzer/tool-build/AnalyzerNative.o"),
                "-o", str(binary), "-module-cache-path", str(CACHE)]
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("DYLD_", "B06_", "AUDIT_", "SWIFT_"))}
        env["TMPDIR"] = str(output / "tmp")
        started = time.monotonic_ns()
        result = subprocess.run(argv, cwd=REPO, env=env, capture_output=True, timeout=120)
        record["build"] = dict(argv=argv, sdk=sdk, returncode=result.returncode,
                               stdout=result.stdout[:65536].decode(errors="replace"),
                               stderr=result.stderr[:65536].decode(errors="replace"),
                               elapsed_ns=time.monotonic_ns() - started,
                               compiler_version=subprocess.check_output([compiler, "--version"], text=True).strip())
        if result.returncode:
            raise ValueError("Pure model profile did not compile")
        record["binary_sha256"] = sha(binary)
        # Preserve a build projection failure before running a profile process.
        post_build = allocation(output)
        cache_after_build = allocation(CACHE)
        if any(post_build[key] + max(0, cache_after_build[key] - before_cache[key]) > PROJECTION[key]
               for key in PROJECTION):
            raise ValueError("Pure model profile build projection exceeded")
        for name in ["ordinary", "folder-record-limit", "raw-path-limit"]:
            started = time.monotonic_ns()
            child = subprocess.run([str(binary), name], cwd=REPO, env=env, capture_output=True, timeout=60)
            observation = dict(case=name, returncode=child.returncode,
                               elapsed_ns=time.monotonic_ns() - started,
                               stderr=child.stderr[:65536].decode(errors="replace"))
            record["observations"].append(observation)
            if len(child.stdout) > 65536:
                raise ValueError("Oversized pure profile output")
            observation["result"] = json.loads(child.stdout)
            if child.returncode or child.stderr or observation["result"].get("passed") is not True:
                raise ValueError("Pure model profile invariant failed: " + name)
        verify_frozen()
        if record["sources"] != {str(path.relative_to(REPO)): sha(path) for path in SOURCES}:
            raise ValueError("Pure model source changed during observation")
        record["complete"] = True
    except Exception as error:
        failed = error
        record["failure"] = dict(type=type(error).__name__, message=str(error)[:4096])
    finally:
        try:
            record["after_cache"] = allocation(CACHE)
            record["after_tools"] = tools_usage()
            record["output_storage"] = allocation(output)
            record["cache_growth"] = {key: max(0, record["after_cache"][key] - before_cache[key])
                                      for key in PROJECTION}
            record["projection_passed"] = all(record["output_storage"][key] + record["cache_growth"][key]
                                               <= PROJECTION[key] for key in PROJECTION)
            record["tooling_limit_passed"] = (sum(value["allocated"] for value in record["after_tools"].values())
                                               + record["cache_growth"]["allocated"] <= TOOLS_LIMIT)
            record["final_budget"] = budget()
            record["complete"] &= record["projection_passed"] and record["tooling_limit_passed"]
        except Exception as accounting_error:
            record["complete"] = False
            record["accounting_failure"] = dict(type=type(accounting_error).__name__,
                                                message=str(accounting_error)[:4096])
            if failed is None:
                failed = accounting_error
        put(receipt, record)
    print(json.dumps(dict(complete=record["complete"], receipt=str(receipt))))
    if failed is not None:
        raise failed
    if not record["complete"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
