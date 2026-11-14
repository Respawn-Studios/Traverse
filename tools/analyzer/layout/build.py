#!/usr/bin/env python3
"""Build the isolated layout candidate without changing frozen artifacts."""
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
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/analyzer"))
from packet import budget, create_directory, directory_fd, put
from verify_derivation import verify

OUTPUT = REPO / ".build/b06-analyzer/layout-build"
NATIVE_OBJECT = REPO / ".build/b06-analyzer/tool-build/AnalyzerNative.o"
FROZEN = {
    "tools/analyzer/AnalyzerScanner.swift": "fbb4d95a7db73e5abadc381d91077301de240d13e0eeacd6861a825e639dd795",
    "tools/analyzer/AnalyzerNative.c": "73169e27f8a994da50d7c17d7e604a18a36407542c70492086d055c469229d5c",
    "tools/analyzer/AnalyzerNative.h": "d3e31660adb87a8f3b8637ae075aa2533fdc495222a1420bd1689aad052eb819",
    ".build/b06-analyzer/tool-build/AnalyzerNative.o": "6d0dfafca8910568b684316717469ca0015ddb99aa8b96a77673ea3a5e7e1a60",
    ".build/b06-analyzer/tool-build/b06-swift-scanner": "7deeb8acd2606cb467a0927fde4de0be0a36c5d4716f94c4b52222e3af98ef0b",
}
PROJECTED = dict(entries=1500, logical=64 << 20, allocated=128 << 20)
TOOLS_LIMIT = 2 << 30


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def allocation(root: Path) -> dict:
    if not root.exists(): return dict(entries=0, logical=0, allocated=0)
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
            finally: os.close(descriptor)
        elif stat.S_ISREG(observed.st_mode): counts["logical"] += observed.st_size
    return counts


def verify_frozen() -> None:
    for relative, expected in FROZEN.items():
        path = REPO / relative
        if path.resolve() != path or sha(path) != expected:
            raise ValueError("Frozen scanner or syscall artifact changed: " + relative)


def main() -> None:
    verify_frozen(); verify()
    initial = budget(PROJECTED["entries"], PROJECTED["logical"], PROJECTED["allocated"])
    tooling_roots = [REPO / ".build/b06-toolchain", REPO / ".build/b06-analyzer/tool-build", OUTPUT]
    before_tools = {str(path.relative_to(REPO)): allocation(path) for path in tooling_roots}
    if sum(value["allocated"] for value in before_tools.values()) + PROJECTED["allocated"] > TOOLS_LIMIT:
        raise ValueError("Layout build exceeds the independent tooling ceiling")
    if not OUTPUT.exists(): create_directory(OUTPUT)
    for name in ["tmp", "module-cache"]:
        path = OUTPUT / name
        if not path.exists(): create_directory(path)
        descriptor = directory_fd(path); os.close(descriptor)
    env = dict(os.environ, TMPDIR=str(OUTPUT / "tmp"))
    compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    sources = [REPO / "tools/analyzer/layout/ValueLayout.swift", REPO / "tools/analyzer/layout/main.swift"]
    binary = OUTPUT / "b06-swift-layout-scanner"
    if binary.exists() or binary.is_symlink():
        existing = binary.lstat()
        if not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1:
            raise ValueError("Refusing a redirected or shared candidate binary output")
    argv = [compiler, "-O", "-whole-module-optimization", "-target", "arm64-apple-macosx15.0", "-sdk", sdk,
            "-import-objc-header", str(REPO / "tools/analyzer/AnalyzerNative.h"), *map(str, sources),
            str(NATIVE_OBJECT), "-o", str(binary), "-module-cache-path", str(OUTPUT / "module-cache")]
    receipt = OUTPUT / ("build-" + uuid.uuid4().hex + ".json")
    started = time.monotonic_ns()
    result = subprocess.run(argv, cwd=REPO, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    verify_frozen()
    after_tools = {str(path.relative_to(REPO)): allocation(path) for path in tooling_roots}
    observed = budget()
    candidate_storage = after_tools[str(OUTPUT.relative_to(REPO))]
    # Preserve a failed build/projection as evidence. Do not enlarge an allowance
    # or clean files to obtain a passing observation.
    limits_pass = (candidate_storage["logical"] <= PROJECTED["logical"]
                   and candidate_storage["allocated"] <= PROJECTED["allocated"]
                   and candidate_storage["entries"] <= PROJECTED["entries"]
                   and sum(value["allocated"] for value in after_tools.values()) <= TOOLS_LIMIT)
    record = dict(schema=1, complete=result.returncode == 0 and limits_pass, returncode=result.returncode,
                  limits_pass=limits_pass, argv=argv, sdk=sdk,
                  compiler_version=subprocess.check_output([compiler, "--version"], text=True).strip(),
                  sources={str(path.relative_to(REPO)): sha(path) for path in sources}, frozen=FROZEN,
                  stdout=result.stdout, stderr=result.stderr, elapsed_ns=time.monotonic_ns() - started,
                  projected=PROJECTED, before_tools=before_tools, after_tools=after_tools,
                  initial_budget=initial, final_budget=observed,
                  binary_sha256=sha(binary) if result.returncode == 0 else None)
    put(receipt, record)
    print(json.dumps(dict(receipt=str(receipt), complete=record["complete"], storage=candidate_storage)))
    if not record["complete"]: raise SystemExit(2)


if __name__ == "__main__": main()
