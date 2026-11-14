#!/usr/bin/env python3
"""Frozen, balanced standalone comparison; never creates or changes a corpus."""
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
from packet import REPO, admit, budget, corpus_root, create_directory, create_file, identity, put, read_owned
from qualify import RUST, SWIFT, collect, command

LANES = ("foundation", "bulk", "rust")
KEYS = ["entries", "regular_entries", "directory_entries", "symlink_entries", "other_entries", "objects",
        "entry_totals", "object_totals", "missing_fields", "digest_count", "digest_sum", "digest_xor",
        "object_accounting_state", "outside_link_objects"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]


def statistics_for(rows: list[dict]) -> dict:
    result = {}
    for key in ["wall_ns", "feedback_ns", "progress_ns", "summary_ns", "peak_rss_bytes",
                "incremental_peak_rss", "post_drain_rss", "scan_ns", "user_seconds", "system_seconds"]:
        values = [row[key] for row in rows if row.get(key) is not None]
        result[key] = dict(samples=len(values), median=statistics.median(values), p95=percentile(values, .95),
                           worst=max(values), minimum=min(values))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    parser.add_argument("--correctness-wide", required=True)
    parser.add_argument("--correctness-mixed", required=True)
    args = parser.parse_args()
    run = admit(args.run)
    budget(1000, 8 << 20, 32 << 20)
    evidence = run / "evidence" / ("benchmark-" + uuid.uuid4().hex)
    create_directory(evidence)
    frozen = evidence / "frozen"; create_directory(frozen)
    binaries = {}
    for lane, source in [("swift", SWIFT), ("rust", RUST)]:
        destination = frozen / (lane + "-scanner")
        with create_file(destination) as output, source.open("rb") as incoming:
            while True:
                part = incoming.read(65536)
                if not part: break
                output.write(part)
            os.fchmod(output.fileno(), 0o700)
        binaries[lane] = dict(path=str(destination), sha256=sha(destination), source_sha256=sha(source))
    expected = {}; scopes = {}
    for corpus, path in [("wide", args.correctness_wide), ("mixed", args.correctness_mixed)]:
        report = json.loads(read_owned(Path(path).absolute(), 16 << 20))
        if report.get("complete") is not True or report.get("corpus") != corpus or set(report["lanes"]) != set(LANES):
            raise ValueError("A fresh complete three-lane correctness receipt is required")
        for lane in LANES:
            original = RUST if lane == "rust" else SWIFT
            # A receipt is evidence only for the exact executable that ran.
            if report["lanes"][lane].get("binary_sha256") != sha(original):
                raise ValueError("Correctness receipt does not bind current binary")
        expected[corpus] = {key: report["lanes"]["bulk"]["summary"][key] for key in KEYS}
        root = corpus_root(run, corpus)
        scopes[corpus] = dict(root=str(root), dev=identity(root)[0], ino=identity(root)[1],
                              manifest_sha256=report["oracle"]["manifest_sha256"])
    permutations = list(itertools.permutations(LANES))
    schedule = []
    for profile in ["fresh-process-uncontrolled-cache", "identically-primed-warm"]:
        for corpus in ["wide", "mixed"]:
            for repeat in range(12):
                for lane in permutations[repeat % 6]:
                    schedule.append(dict(profile=profile, corpus=corpus, repeat=repeat, lane=lane))
    sources = {str(path.relative_to(REPO)): sha(path) for path in (REPO / "tools/analyzer").rglob("*")
               if path.is_file() and "__pycache__" not in path.parts}
    host = {}
    for name, argv in [
        ("os", ["/usr/bin/sw_vers"]), ("xcode", ["/usr/bin/xcodebuild", "-version"]),
        ("swift", ["/usr/bin/xcrun", "swiftc", "--version"]),
        ("rust", [str(REPO / ".build/b06-toolchain/rust-1.99.1/bin/rustc"), "-vV"]),
        ("hardware_model", ["/usr/sbin/sysctl", "-n", "hw.model"]),
        ("hardware_memory", ["/usr/sbin/sysctl", "-n", "hw.memsize"]),
        ("hardware_cpus", ["/usr/sbin/sysctl", "-n", "hw.physicalcpu", "hw.logicalcpu"]),
        ("thermal", ["/usr/bin/pmset", "-g", "therm"])]:
        observed = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        host[name] = dict(status=observed.returncode, stdout=observed.stdout.strip(), stderr=observed.stderr.strip())
    frozen_plan = dict(schema=1, schedule=schedule, binaries=binaries, sources=sources, scopes=scopes, expected=expected,
                       host=host, gates=dict(speed_improvement=.20, rust_memory_improvement=.25,
                                            memory_allowed_time_regression=.05, worst_allowed_regression=.10),
                       claims="One worker, process and result protocol included; no cold-cache claim or production adoption.")
    put(evidence / "frozen-plan.json", frozen_plan)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("DYLD_", "B06_AUDIT_"))}
    rows = []
    for index, item in enumerate(schedule):
        corpus, lane = item["corpus"], item["lane"]
        root = corpus_root(run, corpus)
        expected_id = scopes[corpus]["dev"], scopes[corpus]["ino"]
        if identity(root) != expected_id: raise ValueError("Frozen corpus replaced")
        if item["profile"] == "identically-primed-warm":
            session = f"prime-{index}"
            argv = command(root, "bulk", session, ["--summary-only"], expected_identity=expected_id)
            argv[0] = binaries["swift"]["path"]
            prime = collect(argv, session, evidence / (session + ".stderr"), env=env)
            put(evidence / (session + ".json"), prime)
            if prime["returncode"] or any(prime["summary"][key] != expected[corpus][key] for key in KEYS):
                raise ValueError("Fixed warm prime failed; cohort stopped")
        session = f"sample-{index:03d}-{corpus}-{lane}"
        argv = command(root, lane, session, ["--summary-only"], expected_identity=expected_id)
        executable = binaries["rust" if lane == "rust" else "swift"]
        if sha(Path(executable["path"])) != executable["sha256"]: raise ValueError("Frozen binary changed")
        argv[0] = executable["path"]
        load_before = os.getloadavg()
        result = collect(argv, session, evidence / (session + ".stderr"), env=env)
        result["schedule"] = item
        put(evidence / (session + ".json"), result)
        valid = result["returncode"] == 0 and result["summary"]["complete"] and not result["stderr_bytes"]
        valid = valid and all(result["summary"][key] == expected[corpus][key] for key in KEYS)
        if not valid: raise ValueError("Sample failed correctness; retained, cohort stopped without replacement")
        summary = result["summary"]
        if int(summary["incremental_peak_rss"]) > 256 << 20 or int(summary["peak_owned_fds"]) > 64:
            raise ValueError("Sample breached frozen resource bound; cohort stopped")
        row = dict(**item, wall_ns=result["wall_ns"], feedback_ns=result["feedback_ns"],
                   progress_ns=result["progress_ns"], summary_ns=result["summary_ns"],
                   peak_rss_bytes=result["wait4"]["peak_rss_bytes"],
                   user_seconds=result["wait4"]["user_seconds"], system_seconds=result["wait4"]["system_seconds"],
                   incremental_peak_rss=int(summary["incremental_peak_rss"]),
                   post_drain_rss=int(summary["post_drain_rss"]), scan_ns=int(summary["elapsed_ns"]),
                   metadata_calls=int(summary["metadata_calls"]), bulk_calls=int(summary["bulk_calls"]),
                   load_before=load_before, load_after=os.getloadavg(), accepted=True)
        rows.append(row)
        if (index + 1) % 12 == 0:
            print(json.dumps(dict(completed=index + 1, planned=len(schedule), profile=item["profile"], corpus=corpus)), flush=True)
    aggregates = {}
    comparisons = {}
    for profile in {row["profile"] for row in rows}:
      for corpus in ["wide", "mixed"]:
        selected = [row for row in rows if row["profile"] == profile and row["corpus"] == corpus]
        for lane in LANES:
            aggregates[profile + "/" + corpus + "/" + lane] = statistics_for([row for row in selected if row["lane"] == lane])
        for candidate, reference in [("bulk", "foundation"), ("rust", "bulk"), ("rust", "foundation")]:
            ratios = []
            for repeat in range(12):
                pair = {row["lane"]: row for row in selected if row["repeat"] == repeat}
                ratios.append(pair[candidate]["wall_ns"] / pair[reference]["wall_ns"])
            comparisons[profile + "/" + corpus + "/" + candidate + "-vs-" + reference] = dict(
                paired_ratios=ratios, median_ratio=statistics.median(ratios), minimum=min(ratios), maximum=max(ratios))
    final = dict(schema=1, complete=True, rows=rows, aggregates=aggregates, comparisons=comparisons,
                 budget=budget(), toolchain_budget_ceiling=2 << 30,
                 limits=["filesystem caches uncontrolled", "tail estimates coarse at12 samples per cell",
                         "shared machine and uncontrolled other apps", "one worker only",
                         "post_drain_rss retains result aggregates; not a reusable-session leak test",
                         "differences include runtime/data-layout costs; not proof language alone caused gains"])
    put(evidence / "report.json", final)
    print(json.dumps(dict(evidence=str(evidence), complete=True, samples=len(rows), comparisons=comparisons)), flush=True)


if __name__ == "__main__": main()
