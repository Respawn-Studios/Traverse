#!/usr/bin/env python3
"""Isolated in-memory B06 consumer qualification; never changes app sources.

No corpus generation, personal traversal, cleanup, scanner protocol change or
adoption path. Every compiler/sample failure remains in its unique output root.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from packet import BASE, REPO, LIMITS, FLOOR, create_directory, inventory, put
from analysis_model_profile import CACHE, FROZEN, allocation, verify_frozen

MODELS = REPO / "Packages/ExplorerKit/Sources/StorageAnalysis/AnalysisModels.swift"
ORIGINAL = REPO / "Packages/ExplorerKit/Sources/StorageAnalysis/StorageAnalysisAccumulator.swift"
PROFILE = HERE.parent / "analysis_model_profile.swift"
PRECEDING = REPO / ".build/evidence/b06-final-native-receipts-866a2dfda08f419a9b1dbff092d57809.json"
PROJECTION = dict(entries=80, logical=6 << 20, allocated=12 << 20)
CACHE_PROJECTION = 64 << 20
BASELINE_PIN = "f43175f2990a05f18bf9c72f12af5db468396a36e9ed36860d5d1fd07f4b644a"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resources() -> dict:
    preceding = json.loads(PRECEDING.read_text())
    total = inventory(BASE)
    for name in preceding["supplement_roots"]:
        root = REPO / name
        value = inventory(root)
        value["entries"] += 1
        value["allocated"] += root.lstat().st_blocks * 512
        for key in total:
            total[key] += value[key]
    # Deliberately conservative: includes the analyzer's fixtures as tooling too.
    tooling = sum(inventory(REPO / name)["allocated"] + (REPO / name).lstat().st_blocks * 512
                  for name in preceding["conservative_tooling_union"])
    return dict(combined=total, tooling_allocated=tooling, cache=allocation(CACHE),
                free=os.statvfs(BASE).f_bavail * os.statvfs(BASE).f_frsize)


def percentile95(values: list[float]) -> float:
    return sorted(values)[int((len(values) - 1) * .95 + .99999)]


def main() -> None:
    verify_frozen()
    if sha(ORIGINAL) != BASELINE_PIN:
        raise ValueError("Original model changed; freeze a new comparison explicitly")
    sources = [MODELS, ORIGINAL, HERE / "Accumulator.swift", PROFILE, HERE / "Equivalence.swift", Path(__file__)]
    pins = {str(p.relative_to(REPO)): sha(p) for p in sources}
    before = resources()
    for key, value in PROJECTION.items():
        if before["combined"][key] + value > LIMITS[key]:
            raise ValueError("Combined B06 admission refused: " + key)
    if before["tooling_allocated"] + PROJECTION["allocated"] + CACHE_PROJECTION > 2 << 30:
        raise ValueError("B06 tooling admission refused")
    if before["free"] < FLOOR + PROJECTION["allocated"] + CACHE_PROJECTION:
        raise ValueError("B06 free-space admission refused")
    output = BASE / ("compact-qualification-" + uuid.uuid4().hex)
    create_directory(output)
    create_directory(output / "tmp")
    record = dict(schema=1, scope="pure in-memory model only; no scanner/UI/adoption qualification",
                  complete=False, before=before, projection=PROJECTION, cache_projection=CACHE_PROJECTION,
                  sources=pins, frozen=FROZEN, builds=[], controls=[], samples=[],
                  gates=dict(equivalent=True, stress_peak_reduction=.25, median_time_regression=.05,
                             p95_time_regression=.10),
                  sample_plan="One retained prime per lane/case, then 10 pairs per case, alternating original/candidate; all samples retained",
                  priming_samples=[])
    failure = None
    try:
        compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        record["compiler"] = subprocess.check_output([compiler, "--version"], text=True).strip()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "B06_", "AUDIT_", "SWIFT_"))}
        env["TMPDIR"] = str(output / "tmp")
        binaries = {}
        for lane, model in [("original", ORIGINAL), ("candidate", HERE / "Accumulator.swift")]:
            for mode, harness in [("controls", HERE / "Equivalence.swift"), ("profile", PROFILE)]:
                binary = output / (lane + "-" + mode)
                args = [compiler, "-O", "-whole-module-optimization", "-swift-version", "6",
                        "-strict-concurrency=complete", "-warnings-as-errors", "-module-name", "B06CompactComparison",
                        "-target", "arm64-apple-macosx15.0", "-sdk", sdk, "-module-cache-path", str(CACHE)]
                if mode == "profile":
                    args += ["-import-objc-header", str(REPO / "tools/analyzer/AnalyzerNative.h")]
                args += [str(MODELS), str(model), str(harness)]
                if mode == "profile":
                    args += [str(REPO / ".build/b06-analyzer/tool-build/AnalyzerNative.o")]
                args += ["-o", str(binary)]
                built = subprocess.run(args, env=env, cwd=REPO, capture_output=True, timeout=120)
                record["builds"].append(dict(lane=lane, mode=mode, argv=args, returncode=built.returncode,
                    stdout=built.stdout[:65536].decode(errors="replace"), stderr=built.stderr[:65536].decode(errors="replace")))
                if built.returncode or built.stderr:
                    raise ValueError("Model compilation failed: " + lane + "/" + mode)
                binaries[(lane, mode)] = binary
        record["binaries"] = {p.name: sha(p) for p in binaries.values()}
        for case in ["ordinary", "folder-record-limit", "raw-path-limit"]:
            for lane in ["original", "candidate"]:
                started = time.monotonic_ns()
                child = subprocess.run([str(binaries[(lane, "profile")]), case], env=env, cwd=REPO,
                                       capture_output=True, timeout=30)
                item = dict(case=case, lane=lane, returncode=child.returncode, elapsed_ns=time.monotonic_ns()-started,
                            stdout=child.stdout[:65536].decode(errors="replace"), stderr=child.stderr[:65536].decode(errors="replace"))
                record["priming_samples"].append(item)
                if child.returncode or child.stderr or len(child.stdout)>65536 or json.loads(child.stdout).get("passed") is not True:
                    raise ValueError("Model prime failed")
        controls = []
        for lane in ["original", "candidate"]:
            child = subprocess.run([str(binaries[(lane, "controls")])], env=env, cwd=REPO, capture_output=True, timeout=30)
            if len(child.stdout) > 2 << 20 or len(child.stderr) > 65536:
                raise ValueError("Bounded model control output exceeded")
            value = json.loads(child.stdout) if child.returncode == 0 else None
            record["controls"].append(dict(lane=lane, returncode=child.returncode,
                stderr=child.stderr.decode(errors="replace"), output_sha256=hashlib.sha256(child.stdout).hexdigest(), result=value))
            if child.returncode or child.stderr or value.get("passed") is not True:
                raise ValueError("Model control failure: " + lane)
            controls.append(value)
        if controls[0] != controls[1]:
            raise ValueError("Model differential mismatch")
        # Store the shared exact result once; both stream hashes prove equality.
        shared = record["controls"][0].pop("result")
        record["controls"][1].pop("result")
        put(output / "equivalent-streams.json", shared)
        record["control_cases"] = len(shared["cases"])
        for case in ["ordinary", "folder-record-limit", "raw-path-limit"]:
            for pair in range(10):
                for lane in (["original", "candidate"] if pair % 2 == 0 else ["candidate", "original"]):
                    started = time.monotonic_ns()
                    child = subprocess.run([str(binaries[(lane, "profile")]), case], env=env, cwd=REPO,
                                           capture_output=True, timeout=30)
                    sample = dict(case=case, pair=pair, lane=lane, elapsed_ns=time.monotonic_ns()-started,
                                  returncode=child.returncode, stderr=child.stderr[:65536].decode(errors="replace"))
                    record["samples"].append(sample)
                    if len(child.stdout) > 65536 or child.returncode or child.stderr:
                        sample["stdout"] = child.stdout[:65536].decode(errors="replace")
                        raise ValueError("Model profile failed")
                    sample["result"] = json.loads(child.stdout)
                    if sample["result"].get("passed") is not True:
                        raise ValueError("Model profile invariant failed")
            print("Completed model cohort: " + case, flush=True)
        summaries = {}
        for case in ["ordinary", "folder-record-limit", "raw-path-limit"]:
            lane_summaries = {}
            for lane in ["original", "candidate"]:
                samples = [s for s in record["samples"] if s["case"] == case and s["lane"] == lane]
                durations = [s["elapsed_ns"] for s in samples]
                peaks = [max(int(r["peak_rss"]) for r in s["result"]["resources"]) for s in samples]
                lane_summaries[lane] = dict(median_ns=statistics.median(durations), p95_ns=percentile95(durations),
                                            median_peak=statistics.median(peaks), max_peak=max(peaks))
            a,b = lane_summaries["original"],lane_summaries["candidate"]
            lane_summaries.update(peak_reduction=1-b["median_peak"]/a["median_peak"],
                median_ratio=b["median_ns"]/a["median_ns"], p95_ratio=b["p95_ns"]/a["p95_ns"])
            summaries[case] = lane_summaries
        record["summary"] = summaries
        record["gates_passed"] = (summaries["folder-record-limit"]["peak_reduction"] >= .25
            and all(s["median_ratio"] <= 1.05 and s["p95_ratio"] <= 1.10 for s in summaries.values()))
        verify_frozen()
        if pins != {str(p.relative_to(REPO)): sha(p) for p in sources}:
            raise ValueError("Source changed during qualification")
        if record["binaries"] != {p.name: sha(p) for p in binaries.values()}:
            raise ValueError("Binary changed during qualification")
        record["complete"] = True
    except Exception as error:
        failure = error
        record["failure"] = dict(type=type(error).__name__, message=str(error)[:4096])
    finally:
        record["after"] = resources()
        record["output_storage"] = inventory(output)
        record["cache_growth"] = {k: max(0, record["after"]["cache"][k]-before["cache"][k]) for k in before["cache"]}
        record["projection_passed"] = all(record["output_storage"][k] <= PROJECTION[k] for k in PROJECTION)
        record["budgets_passed"] = (all(record["after"]["combined"][k] <= LIMITS[k] for k in LIMITS)
            and record["after"]["tooling_allocated"]+record["cache_growth"]["allocated"] <= 2 << 30
            and record["cache_growth"]["allocated"] <= CACHE_PROJECTION)
        record["complete"] &= record["projection_passed"] and record["budgets_passed"]
        put(output / "receipt.json", record)
    print(json.dumps(dict(complete=record["complete"], gates_passed=record.get("gates_passed"), receipt=str(output / "receipt.json"))))
    if failure:
        raise failure
    if not record["complete"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
