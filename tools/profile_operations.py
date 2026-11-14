#!/usr/bin/env python3
"""Fresh-process generated-fixture profiles; no cache purge or system configuration."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

sys.dont_write_bytecode = True
from dev import ROOT, local_directory, stamp


def source_fingerprint() -> dict:
    package = ROOT / "Packages/ExplorerKit"
    paths = [package / "Package.swift", ROOT / "tools/dev.py", Path(__file__).resolve()]
    for directory in [package / "Sources", package / "Tests"]:
        paths.extend(directory.rglob("*.swift"))
    paths = sorted(set(paths))
    if len(paths) > 10000:
        raise RuntimeError("Unexpected source input count")
    aggregate = hashlib.sha256()
    inputs = []
    total_bytes = 0
    for path in paths:
        if path.is_symlink() or path.resolve() != path:
            raise RuntimeError("Refusing redirected profile source input")
        relative = path.relative_to(ROOT).as_posix()
        data = path.read_bytes()
        total_bytes += len(data)
        if total_bytes > 64 * 1024 * 1024:
            raise RuntimeError("Unexpected source input size")
        digest = hashlib.sha256(data).hexdigest()
        aggregate.update(relative.encode() + b"\0" + digest.encode() + b"\n")
        inputs.append({"path": relative, "sha256": digest})
    return {"sha256": aggregate.hexdigest(), "inputCount": len(inputs), "inputs": inputs}


def runtime_configuration(configuration: str) -> dict:
    version = subprocess.run(["xcrun", "swift", "--version"], cwd=ROOT,
                             capture_output=True, text=True, timeout=20, check=True)
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], cwd=ROOT,
                         capture_output=True, text=True, timeout=20, check=True)
    return {"buildConfiguration": "SwiftPM " + configuration.title(), "requestedConfiguration": configuration,
            "swiftVersion": version.stdout.strip(), "macOSVersion": platform.mac_ver()[0],
            "kernelVersion": platform.release(), "architecture": platform.machine(),
            "sdkVersion": sdk.stdout.strip()}


def optimization_evidence(configuration: str) -> dict:
    """Capture configured optimization plus the actual worker artifact, not an inferred label."""
    scratch = ROOT / ".build" / ("swift-tests" if configuration == "debug" else "swift-tests-release")
    pif = scratch / "manifest.pif"
    if not pif.is_file() or pif.is_symlink() or pif.stat().st_size > 16 * 1024 * 1024:
        raise RuntimeError("Expected bounded SwiftBuild configuration evidence")
    projects = json.loads(pif.read_text())
    settings = []
    for entry in projects:
        for build in entry.get("contents", {}).get("buildConfigurations", []):
            value = build.get("buildSettings", {}).get("SWIFT_OPTIMIZATION_LEVEL")
            if build.get("name") == configuration.title() and value is not None:
                settings.append(value)
    expected = {"-Onone"} if configuration == "debug" else {"-O", "-Osize", "-Owholemodule"}
    if not settings or any(value not in expected for value in settings):
        raise RuntimeError("Compiler configuration disagrees with requested optimization mode")
    worker = scratch / "out/Products" / configuration.title() / "FileOperationsTests.xctest/Contents/MacOS/FileOperationsTests"
    if not worker.is_file() or worker.resolve() != worker:
        raise RuntimeError("Expected an unredirected FileOperations profile worker")
    objects = scratch / "out/Intermediates.noindex/ExplorerKit.build" / configuration.title() / "FileOperations-t.build/Objects-normal"
    candidates = list(objects.glob("*/FileOperations.o")) or list(objects.glob("*/VerifiedTree.o"))
    if len(candidates) != 1 or candidates[0].resolve() != candidates[0]:
        raise RuntimeError("Expected one unredirected FileOperations optimization object")
    dwarf = subprocess.run(["xcrun", "dwarfdump", "--debug-info", "--recurse-depth=0", str(candidates[0])],
                           cwd=ROOT, capture_output=True, text=True, timeout=20, check=True)
    if len(dwarf.stdout) > 1024 * 1024:
        raise RuntimeError("Unexpected optimization evidence size")
    units = [part for part in dwarf.stdout.split("DW_TAG_compile_unit") if "DW_LANG_Swift" in part]
    if not units:
        raise RuntimeError("Expected Swift compilation-unit optimization evidence")
    optimized = ["DW_AT_APPLE_optimized\t(true)" in unit for unit in units]
    if any(value != (configuration == "release") for value in optimized):
        raise RuntimeError("Actual Swift object optimization disagrees with requested mode")
    digest = hashlib.sha256()
    with worker.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {"swiftOptimizationLevels": settings, "configurationManifest": str(pif.relative_to(ROOT)),
            "configurationManifestSHA256": hashlib.sha256(pif.read_bytes()).hexdigest(),
            "object": str(candidates[0].relative_to(ROOT)), "swiftCompilationUnitsOptimized": optimized,
            "worker": str(worker.relative_to(ROOT)), "workerSHA256": digest.hexdigest(),
            "limit": "SwiftBuild configured settings and worker artifact; not a signed compiler dependency manifest."}


def run() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["large", "fanout", "deep", "batch", "cycles"], action="append")
    parser.add_argument("--repeat", type=int, default=1, choices=range(1, 4))
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug",
                        help="Measure one explicit SwiftPM configuration; never combine modes as a speedup.")
    parser.add_argument("--batch-inputs", type=int, choices=[64, 128, 256, 512, 1024], default=1024,
                        help="Generated top-level inputs for the batch workload; default retains qualification size.")
    parser.add_argument("--observer", choices=["plain", "observed", "both"], default="both",
                        help="Run without callback probes, with probes, or matched pairs (default).")
    parser.add_argument("--journal-metrics", action="store_true", help="Opt-in fixed journal timing buckets and numeric work counters.")
    parser.add_argument("--held-depth", action="store_true", help="Only depth33, observer on; sample FDs/RSS at each held-node copy hook")
    args = parser.parse_args()
    cases = ["deep"] if args.held_depth else list(dict.fromkeys(args.case or ["large", "fanout", "deep", "batch", "cycles"]))
    output = local_directory("evidence") / ("integrity-profile-" + stamp())
    output.mkdir(mode=0o700)
    configuration = runtime_configuration(args.configuration)
    initial_sources = source_fingerprint()
    (output / "configuration.json").write_text(json.dumps({"configuration": configuration,
        "sourcesAtDriverStart": initial_sources, "requestedRun": {"batchInputs": args.batch_inputs,
            "observer": args.observer, "repeat": args.repeat, "heldDepth": args.held_depth, "journalMetrics": args.journal_metrics}}, indent=2) + "\n")
    receipts = []
    for workload in cases:
        for repetition in range(args.repeat):
            observers = [True] if args.held_depth else {"plain": [False], "observed": [True], "both": [False, True]}[args.observer]
            for observer in observers:
                env = os.environ.copy()
                env.update({"MAC_EXPLORER_RUN_INTEGRITY_PROFILE": "1",
                            "MAC_EXPLORER_INTEGRITY_PROFILE_CASE": workload,
                            "MAC_EXPLORER_INTEGRITY_PROFILE_BATCH_INPUTS": str(args.batch_inputs),
                            "MAC_EXPLORER_INTEGRITY_PROFILE_JOURNAL": "1" if args.journal_metrics else "0",
                            "MAC_EXPLORER_INTEGRITY_PROFILE_OBSERVER": "1" if observer else "0",
                            "MAC_EXPLORER_INTEGRITY_PROFILE_HELD_PROBES": "1" if args.held_depth else "0"})
                sources = source_fingerprint()
                result = subprocess.run([sys.executable, str(ROOT / "tools/dev.py"), "test", "--configuration", args.configuration, "--filter",
                                         "IntegrityProfileTests/generatedFixtureWorker"], cwd=ROOT, env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                        timeout=330, check=False)
                receipt_name = f"{workload}-{repetition + 1}-{'observed' if observer else 'plain'}"
                (output / (receipt_name + ".log")).write_text(result.stdout)
                print(result.stdout, end="", flush=True)
                if result.returncode:
                    raise RuntimeError(f"Profile worker failed; evidence: {output}")
                paths = [Path(line.split("; log ", 1)[1].strip()) for line in result.stdout.splitlines()
                         if line.startswith("test: passed in ") and "; log " in line]
                if len(paths) != 1:
                    raise RuntimeError("Expected one completed test log")
                path = paths[0]
                if path.parent != ROOT / ".build/logs" or path.is_symlink():
                    raise RuntimeError("Unexpected test log location")
                reports = [json.loads(line.split("INTEGRITY_PROFILE_JSON ", 1)[1])
                           for line in path.read_text().splitlines() if "INTEGRITY_PROFILE_JSON " in line]
                if len(reports) != 1 or reports[0]["disposition"] != "succeeded":
                    raise RuntimeError("Expected exactly one successful profile receipt")
                report = reports[0]
                if report["workload"] != workload or report["profiling"] != observer:
                    raise RuntimeError("Profile worker receipt does not match requested case")
                if workload == "batch" and (report["regularFileCount"] != args.batch_inputs
                                             or report["topLevelInputCount"] != args.batch_inputs):
                    raise RuntimeError("Batch receipt does not match requested input count")
                if (report.get("journalMetrics") is not None) != args.journal_metrics:
                    raise RuntimeError("Journal measurement receipt does not match requested mode")
                report["repetition"] = repetition + 1
                report["testLog"] = str(path.relative_to(ROOT))
                report["configuration"] = configuration
                report["optimizationEvidence"] = optimization_evidence(args.configuration)
                report["sourcesBeforeLaunch"] = sources
                report["sourceChangesDuringWorker"] = source_fingerprint()["sha256"] != sources["sha256"]
                report["provenanceLimit"] = "Source inputs hashed before launch and worker artifact hashed after completion; not a signed compiler dependency manifest. Uses SwiftPM " + args.configuration + " incremental build."
                receipts.append(report)
                (output / (receipt_name + ".json")).write_text(json.dumps(report, indent=2) + "\n")
    summary = {"schema": 1, "freshProcessPerSample": True, "cacheState": "uncontrolled",
               "samples": receipts}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Profile evidence: {output}")


if __name__ == "__main__":
    run()
