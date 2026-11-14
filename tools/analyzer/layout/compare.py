#!/usr/bin/env python3
"""Frozen 144-sample layout counterexperiment; reuses admitted immutable corpora.

No fixture generator, cleanup, download, app integration or timing replacement.
Use --validate-only for admission review without launching any scanner.
"""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import fcntl
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import resource
import stat
import statistics
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/analyzer"))
import benchmark
import packet
import qualify

LABELS = ("swift-baseline", "swift-value", "rust-baseline")
LANES = dict(zip(LABELS, ("bulk", "bulk", "rust")))
PROFILES = ("fresh-process-uncontrolled-cache", "identically-primed-warm")
CORE_KEYS = benchmark.KEYS
STRATEGY_KEYS = ("metadata_calls", "bulk_calls", "foundation_next_calls", "peak_queued_dirs", "peak_owned_fds")
NATIVE_OBJECT = REPO / ".build/b06-analyzer/tool-build/AnalyzerNative.o"
COMPILED_SOURCES = {"tools/analyzer/layout/main.swift", "tools/analyzer/layout/ValueLayout.swift"}
MAX_STDERR = 64 << 10
MAX_RECEIPT = 128 << 10
MAX_FAILURE = 16 << 10
MAX_PLAN = 2 << 20
MAX_REPORT = 2 << 20
TOOL_LIMIT = 2 << 30
# Exact artifacts/source recorded by the original accepted 144-sample cohort.
# A newly rebuilt/requalified executable is not silently promoted to "baseline".
ORIGINAL_HASHES = {
    "tools/analyzer/AnalyzerScanner.swift": "fbb4d95a7db73e5abadc381d91077301de240d13e0eeacd6861a825e639dd795",
    "tools/analyzer/AnalyzerNative.c": "73169e27f8a994da50d7c17d7e604a18a36407542c70492086d055c469229d5c",
    "tools/analyzer/AnalyzerNative.h": "d3e31660adb87a8f3b8637ae075aa2533fdc495222a1420bd1689aad052eb819",
    "tools/analyzer/rust/main.rs": "bc8d582b4640acf0b0bac5c4a7f2780667fd5f95b616aba7975fad9f3e177799",
    ".build/b06-analyzer/tool-build/AnalyzerNative.o": "6d0dfafca8910568b684316717469ca0015ddb99aa8b96a77673ea3a5e7e1a60",
    ".build/b06-analyzer/tool-build/b06-swift-scanner": "7deeb8acd2606cb467a0927fde4de0be0a36c5d4716f94c4b52222e3af98ef0b",
    ".build/b06-toolchain/build/b06-rust-scanner": "00add9a0a28aa7634ba2a5c0d6f71ee8ed0a657ff1da3b01376ddec4c8132ed3",
}
GATES = dict(speed_improvement=.20, memory_improvement=.25, memory_allowed_time_regression=.05,
             memory_metric="median incremental_peak_rss", p95_and_worst_allowed_regression=.10,
             incremental_rss_bytes=256 << 20, owned_fds=64)


def encoded(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def save(path: Path, value: object, maximum: int = MAX_RECEIPT) -> None:
    if len(encoded(value)) > maximum:
        raise ValueError("Layout receipt exceeds its frozen bound")
    packet.put(path, value)


def checked_path(path: Path) -> Path:
    path = path.absolute()
    if ".." in path.parts or REPO not in path.parents:
        raise ValueError("Only exact repository paths are accepted")
    packet.anchored(path.parent)
    return path


def file_bytes(path: Path, maximum: int = 16 << 20, executable: bool = False) -> bytes:
    path = checked_path(path)
    parent = packet.directory_fd(path.parent)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum
                or (executable and not before.st_mode & 0o111)):
            raise ValueError("Untrusted scanner/source artifact")
        data = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        if len(data) > maximum or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("Scanner/source changed while read")
        return data


def sha(path: Path, executable: bool = False) -> str:
    return hashlib.sha256(file_bytes(path, executable=executable)).hexdigest()


def require_hash(path: Path, expected: object, executable: bool = False) -> None:
    if not isinstance(expected, str) or re.fullmatch("[0-9a-f]{64}", expected) is None or sha(path, executable) != expected:
        raise ValueError("Qualified binary/source hash changed")


def read_receipt(path: Path) -> dict:
    result = json.loads(packet.read_owned(checked_path(path), 16 << 20))
    if not isinstance(result, dict):
        raise ValueError("Qualification receipt must be an object")
    return result


def validate_summary(summary: dict, expected: dict, strategy: dict | None = None, enforce_resources: bool = True) -> None:
    if not isinstance(summary, dict) or summary.get("complete") is not True or summary.get("reason") != "complete":
        raise ValueError("Sample is not complete")
    if any(summary.get(key) != expected[key] for key in CORE_KEYS):
        raise ValueError("Sample disagrees with independently qualified aggregate")
    if summary.get("errors") != "0" or summary.get("resource_metrics_state") != "returned":
        raise ValueError("Sample has errors or unavailable resource metrics")
    for group in ("entry_totals", "object_totals", "missing_fields"):
        if set(summary[group]) != set(qualify.FIELDS):
            raise ValueError("Invalid metric field set")
        for value in summary[group].values(): qualify.Consumer.unsigned(value)
    for key in ("entries", "regular_entries", "directory_entries", "symlink_entries", "other_entries", "objects",
                "digest_count", "outside_link_objects", "incremental_peak_rss", "post_drain_rss", "peak_owned_fds"):
        qualify.Consumer.unsigned(summary[key])
    if strategy is not None and any(summary.get(key) != strategy[key] for key in STRATEGY_KEYS):
        raise ValueError("Value-layout strategy/call counts changed")
    if (enforce_resources and int(summary["incremental_peak_rss"]) > GATES["incremental_rss_bytes"]) or int(summary["peak_owned_fds"]) > GATES["owned_fds"]:
        raise ValueError("Sample breached the frozen resource gate")


def validate_observation(result: dict, expected: dict, lane: str, binary_hash: str | None = None,
                         strategy: dict | None = None, enforce_resources: bool = False) -> None:
    if result.get("returncode") != 0 or result.get("stderr_bytes") != 0:
        raise ValueError("Qualified observation failed or emitted stderr")
    if binary_hash is not None and result.get("binary_sha256") != binary_hash:
        raise ValueError("Observation does not bind its executable")
    frames = result.get("frames", [])
    if not frames or frames[0].get("kind") != "header" or sum(row.get("kind") == "header" for row in frames) != 1:
        raise ValueError("Missing unique qualification header")
    header = frames[0]
    if (header.get("lane") != lane or header.get("worker_qos") != "utility" or type(header.get("workers")) is not int
            or header.get("workers") != 1 or header.get("materialization_policy") != "off" or header.get("profile") != "core-v1"
            or header.get("common_mask") != "2718171147" or header.get("directory_mask") != "5" or header.get("file_mask") != "1543"
            or header.get("scope_contract") != ("immutable-reference" if lane == "foundation" else "descriptor-anchored")):
        raise ValueError("Qualified lane/policy differs from the matched contract")
    validate_summary(result.get("summary"), expected, strategy, enforce_resources)
    if enforce_resources:
        values = [result.get(key) for key in ("feedback_ns", "progress_ns", "summary_ns", "wall_ns")]
        if any(type(value) is not int or value <= 0 for value in values) or values != sorted(values):
            raise ValueError("Missing or inconsistent measured feedback/exit times")
        usage = result.get("wait4", {})
        if (type(usage.get("peak_rss_bytes")) is not int or usage["peak_rss_bytes"] <= 0
                or any(not isinstance(usage.get(key), (int, float)) or not math.isfinite(usage[key]) or usage[key] < 0
                       for key in ("user_seconds", "system_seconds"))):
            raise ValueError("Missing actual wait4 resource observation")


def make_schedule() -> list[dict]:
    orders = list(itertools.permutations(LABELS))
    return [dict(profile=profile, corpus=corpus, repeat=repeat, label=label)
            for profile in PROFILES for corpus in ("wide", "mixed")
            for repeat in range(12) for label in orders[repeat % 6]]


def validate_schedule(schedule: list[dict]) -> None:
    if len(schedule) != 144: raise ValueError("Counterexperiment requires exactly 144 samples")
    for profile in PROFILES:
        for corpus in ("wide", "mixed"):
            selected = [row for row in schedule if row["profile"] == profile and row["corpus"] == corpus]
            if Counter(row["label"] for row in selected) != Counter(dict.fromkeys(LABELS, 12)):
                raise ValueError("Unbalanced label sample counts")
            orders = []
            for repeat in range(12):
                order = tuple(row["label"] for row in selected if row["repeat"] == repeat)
                if set(order) != set(LABELS) or len(order) != 3: raise ValueError("Invalid matched repeat")
                orders.append(order)
            if Counter(orders) != Counter(dict.fromkeys(itertools.permutations(LABELS), 2)):
                raise ValueError("Each lane order must appear exactly twice")


def load_qualification(run: Path, candidate: Path, qualification_path: Path,
                       correctness: dict[str, Path]) -> dict:
    run = packet.admit(str(run)); candidate = checked_path(candidate)
    for relative, digest in ORIGINAL_HASHES.items(): require_hash(REPO / relative, digest)
    receipt = read_receipt(qualification_path)
    if receipt.get("schema") != 1 or receipt.get("kind") != "swift-layout-qualification" or receipt.get("complete") is not True:
        raise ValueError("A complete layout qualification receipt is required")
    if receipt.get("source_run") != str(run): raise ValueError("Qualification belongs to a different corpus run")
    if receipt["candidate"].get("path") != str(candidate) or receipt["baseline"].get("path") != str(qualify.SWIFT):
        raise ValueError("Explicit candidate or baseline differs from qualified path")
    require_hash(candidate, receipt["candidate"]["sha256"], True)
    require_hash(qualify.SWIFT, receipt["baseline"]["sha256"], True)
    if receipt["native_object"].get("path") != str(NATIVE_OBJECT): raise ValueError("Unexpected native shim")
    require_hash(NATIVE_OBJECT, receipt["native_object"]["sha256"])
    if set(receipt["candidate"]["sources"]) != COMPILED_SOURCES: raise ValueError("Unexpected candidate source set")
    for source_map in (receipt["candidate"]["sources"], receipt["frozen"]):
        for relative, digest in source_map.items(): require_hash(REPO / relative, digest)
    if (receipt["self_tests"]["parser"].get("passed") != 17 or receipt["self_tests"]["layout"].get("passed") != 16
            or receipt["controls"].get("passed") is not True or receipt["blocked_consumer"].get("passed") is not True
            or receipt["audit"].get("passed") is not True or receipt["audit"].get("candidate_sha256") != receipt["candidate"]["sha256"]):
        raise ValueError("Required parser/layout/fault/audit qualification is missing")
    binaries = {"swift-baseline": dict(source=str(qualify.SWIFT), sha256=sha(qualify.SWIFT, True)),
                "swift-value": dict(source=str(candidate), sha256=sha(candidate, True)),
                "rust-baseline": dict(source=str(qualify.RUST), sha256=sha(qualify.RUST, True))}
    expected, scopes, strategies, inputs = {}, {}, {}, {}
    for corpus in ("wide", "mixed"):
        original = read_receipt(correctness[corpus])
        if original.get("complete") is not True or original.get("corpus") != corpus or set(original["lanes"]) != set(benchmark.LANES):
            raise ValueError("Original complete three-lane correctness is required")
        baseline = original["lanes"]["bulk"]["summary"]
        expected[corpus] = {key: baseline[key] for key in CORE_KEYS}
        for lane in benchmark.LANES:
            digest = binaries["rust-baseline" if lane == "rust" else "swift-baseline"]["sha256"]
            validate_observation(original["lanes"][lane], expected[corpus], lane, digest)
        root = packet.corpus_root(run, corpus); dev, ino = packet.identity(root)
        current_oracle = packet.oracle(run, corpus)  # Once before freeze; never inside sample timing.
        qualified = receipt["corpora"][corpus]
        if (qualified.get("root") != str(root) or (qualified.get("dev"), qualified.get("ino")) != (dev, ino)
                or qualified.get("manifest_sha256") != current_oracle["manifest_sha256"]
                or qualified.get("oracle") != current_oracle or original.get("oracle") != current_oracle
                or qualified.get("expected") != expected[corpus]):
            raise ValueError("Qualification root/manifest/oracle/aggregate is stale")
        observations = qualified["observations"]
        strategies[corpus] = {key: observations["baseline-bulk"]["summary"][key] for key in STRATEGY_KEYS}
        for label, lane in (("baseline-bulk", "bulk"), ("layout-bulk", "bulk"), ("layout-foundation", "foundation")):
            digest = binaries["swift-baseline" if label == "baseline-bulk" else "swift-value"]["sha256"]
            validate_observation(observations[label], expected[corpus], lane, digest,
                                 strategies[corpus] if lane == "bulk" else None)
        if any(original["lanes"]["bulk"]["summary"][key] != strategies[corpus][key] for key in STRATEGY_KEYS):
            raise ValueError("Baseline strategy differs from original qualification")
        scopes[corpus] = dict(root=str(root), dev=dev, ino=ino, manifest_sha256=current_oracle["manifest_sha256"])
        inputs[corpus] = dict(path=str(correctness[corpus]), sha256=sha(correctness[corpus]))
    return dict(binaries=binaries, expected=expected, scopes=scopes, strategies=strategies,
                qualification=dict(path=str(qualification_path), sha256=sha(qualification_path)), correctness=inputs)


def tooling_allocation() -> int:
    total = 0
    for root in (REPO / ".build/b06-toolchain", REPO / ".build/b06-analyzer/tool-build", REPO / ".build/b06-analyzer/layout-build"):
        pending = [root]
        while pending:
            path = pending.pop(); observed = path.lstat(); total += observed.st_blocks * 512
            if stat.S_ISDIR(observed.st_mode):
                fd = packet.directory_fd(path)
                try:
                    with os.scandir(fd) as entries: pending.extend(path / entry.name for entry in entries)
                finally: os.close(fd)
    return total


def forecast(plan: dict) -> dict:
    attempts = 216  # 144 samples plus the same original-Swift warm prime before each of 72 warm samples.
    binary_bytes = sum(Path(record["source"]).stat().st_size for record in plan["binaries"].values())
    logical = binary_bytes + attempts * (MAX_STDERR + MAX_RECEIPT + MAX_FAILURE) + MAX_PLAN + MAX_REPORT
    projection = dict(entries=attempts * 3 + 16, logical=logical, allocated=logical + (attempts * 3 + 16) * 4096)
    before = packet.budget(projection["entries"], projection["logical"], projection["allocated"])
    tooling = tooling_allocation()
    if tooling + binary_bytes + 3 * 4096 > TOOL_LIMIT: raise ValueError("Frozen copies exceed independent tooling budget")
    return dict(projected=projection, initial_budget=before, tooling_allocated=tooling,
                tool_limit=TOOL_LIMIT, frozen_binary_bytes=binary_bytes, maximum_attempts=attempts)


def host_observation() -> dict:
    result = {}
    commands = [("os", ["/usr/bin/sw_vers"]), ("xcode", ["/usr/bin/xcodebuild", "-version"]),
                ("swift", ["/usr/bin/xcrun", "swiftc", "--version"]),
                ("rust", [str(REPO / ".build/b06-toolchain/rust-1.99.1/bin/rustc"), "-vV"]),
                ("model", ["/usr/sbin/sysctl", "-n", "hw.model"]), ("memory", ["/usr/sbin/sysctl", "-n", "hw.memsize"]),
                ("cpus", ["/usr/sbin/sysctl", "-n", "hw.physicalcpu", "hw.logicalcpu"]), ("thermal", ["/usr/bin/pmset", "-g", "therm"])]
    for key, argv in commands:
        observed = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        result[key] = dict(status=observed.returncode, stdout=observed.stdout[:8192].strip(), stderr=observed.stderr[:8192].strip())
    return result


def freeze(run: Path, admitted: dict) -> tuple[Path, dict]:
    forecasted = forecast(admitted)
    evidence = run / "evidence" / ("layout-comparison-" + uuid.uuid4().hex)
    packet.create_directory(evidence); frozen = evidence / "frozen"; packet.create_directory(frozen)
    binaries = {}
    for label in LABELS:
        original = admitted["binaries"][label]; source = Path(original["source"])
        require_hash(source, original["sha256"], True)
        data = file_bytes(source, executable=True)
        destination = frozen / (label + "-scanner")
        with packet.create_file(destination) as output:
            output.write(data); os.fchmod(output.fileno(), 0o700)
        require_hash(destination, original["sha256"], True)
        binaries[label] = dict(original, path=str(destination), actual_lane=LANES[label])
    schedule = make_schedule(); validate_schedule(schedule)
    sources = {str(path.relative_to(REPO)): sha(path) for path in (REPO / "tools/analyzer").rglob("*")
               if path.is_file() and "__pycache__" not in path.parts}
    plan = dict(admitted, schema=1, kind="swift-value-layout-counterexperiment", binaries=binaries, schedule=schedule,
                gates=GATES, host=host_observation(), sources=sources, admission=forecasted,
                output_bounds=dict(stderr_bytes=MAX_STDERR, receipt_bytes=MAX_RECEIPT, failure_bytes=MAX_FAILURE),
                claims="Summary-only complete traversal/accounting/hash and child exit; no full-entry streaming, cold-cache, language-only or production claim.")
    save(evidence / "frozen-plan.json", plan, MAX_PLAN)
    return evidence, plan


def recheck(plan: dict, corpus: str) -> tuple[Path, tuple[int, int]]:
    scope = plan["scopes"][corpus]; root = Path(scope["root"])
    packet.anchored(root)
    expected = (scope["dev"], scope["ino"])
    if packet.identity(root) != expected: raise ValueError("Frozen corpus identity changed")
    for binary in plan["binaries"].values(): require_hash(Path(binary["path"]), binary["sha256"], True)
    return root, expected


class SummaryConsumer:
    count = 0
    def __init__(self, expected: dict, strategy: dict | None): self.expected, self.strategy = expected, strategy
    def accept(self, row: dict) -> None: raise ValueError("Timed summary-only sample emitted an entry")
    def finish(self, summary: dict) -> None: validate_summary(summary, self.expected, self.strategy)


@contextmanager
def bounded_stderr():
    # Per-process soft limit, inherited by this owned child only; restore the runner immediately afterward.
    old = resource.getrlimit(resource.RLIMIT_FSIZE)
    soft = MAX_STDERR if old[0] == resource.RLIM_INFINITY else min(old[0], MAX_STDERR)
    resource.setrlimit(resource.RLIMIT_FSIZE, (soft, old[1]))
    try: yield
    finally: resource.setrlimit(resource.RLIMIT_FSIZE, old)


def execute_attempt(evidence: Path, plan: dict, item: dict, index: int, prime: bool, env: dict) -> dict:
    label = "swift-baseline" if prime else item["label"]
    session = f"{'prime' if prime else 'sample'}-{index:03d}-{item['corpus']}-{label}"
    receipt = evidence / (session + ".json"); stderr = evidence / (session + ".stderr")
    row = dict(schedule=item, label=label, prime=prime, session=session, accepted=False, disposition="not_started")
    result = None
    try:
        root, expected_id = recheck(plan, item["corpus"])
        argv = qualify.command(root, LANES[label], session, ["--summary-only"], expected_identity=expected_id)
        argv[0] = plan["binaries"][label]["path"]
        row["load_before"] = os.getloadavg(); row["disposition"] = "started"
        strategy = plan["strategies"][item["corpus"]]
        with bounded_stderr():
            result = qualify.collect(argv, session, stderr, SummaryConsumer(plan["expected"][item["corpus"]], strategy), env=env)
        validate_observation(result, plan["expected"][item["corpus"]], LANES[label], strategy=strategy, enforce_resources=True)
        recheck(plan, item["corpus"])
        if len(encoded(result)) > MAX_RECEIPT - 8192: raise ValueError("Collected result exceeds receipt bound")
        summary = result["summary"]
        row.update(accepted=True, disposition="accepted", result=result, wall_ns=result["wall_ns"], feedback_ns=result["feedback_ns"],
                   progress_ns=result["progress_ns"], summary_ns=result["summary_ns"], peak_rss_bytes=result["wait4"]["peak_rss_bytes"],
                   user_seconds=result["wait4"]["user_seconds"], system_seconds=result["wait4"]["system_seconds"],
                   incremental_peak_rss=int(summary["incremental_peak_rss"]), post_drain_rss=int(summary["post_drain_rss"]),
                   scan_ns=int(summary["elapsed_ns"]), load_after=os.getloadavg())
    except Exception as error:
        row.update(disposition="rejected", error_type=type(error).__name__, reason=str(error)[:512])
        if result is not None and len(encoded(result)) <= MAX_RECEIPT - 8192: row["result"] = result
        failure = stderr.with_suffix(".stderr.failure.json")
        if failure.exists(): row["collector_failure"] = str(failure)
        save(receipt, row)
        raise
    save(receipt, row)
    return row


def analyze(rows: list[dict]) -> tuple[dict, dict]:
    aggregates, comparisons = {}, {}
    for profile in PROFILES:
        for corpus in ("wide", "mixed"):
            selected = [row for row in rows if row["schedule"]["profile"] == profile and row["schedule"]["corpus"] == corpus]
            stats = {}
            for label in LABELS:
                stats[label] = benchmark.statistics_for([row for row in selected if row["label"] == label])
                aggregates[f"{profile}/{corpus}/{label}"] = stats[label]
            for candidate, reference in (("swift-value", "swift-baseline"), ("rust-baseline", "swift-baseline"), ("rust-baseline", "swift-value")):
                pairs = [{row["label"]: row for row in selected if row["schedule"]["repeat"] == repeat} for repeat in range(12)]
                ratios = [pair[candidate]["wall_ns"] / pair[reference]["wall_ns"] for pair in pairs]
                speed = statistics.median(ratios)
                reference_memory = stats[reference]["incremental_peak_rss"]["median"]
                memory_ratio = (stats[candidate]["incremental_peak_rss"]["median"] / reference_memory) if reference_memory else None
                tail = all(stats[candidate]["wall_ns"][key] <= stats[reference]["wall_ns"][key] * (1 + GATES["p95_and_worst_allowed_regression"]) for key in ("p95", "worst"))
                comparisons[f"{profile}/{corpus}/{candidate}-vs-{reference}"] = dict(paired_ratios=ratios, median_ratio=speed,
                    memory_median_ratio=memory_ratio, tail_pass=tail,
                    speed_route_pass=speed <= 1 - GATES["speed_improvement"] and tail,
                    memory_route_pass=memory_ratio is not None and memory_ratio <= 1 - GATES["memory_improvement"] and speed <= 1 + GATES["memory_allowed_time_regression"] and tail)
    return aggregates, comparisons


def run_cohort(evidence: Path, plan: dict) -> dict:
    rows, primes = [], []
    env = {key: value for key, value in os.environ.items() if not key.startswith(("DYLD_", "B06_AUDIT_"))}
    try:
        for index, item in enumerate(plan["schedule"]):
            if item["profile"] == PROFILES[1]: primes.append(execute_attempt(evidence, plan, item, index, True, env))
            rows.append(execute_attempt(evidence, plan, item, index, False, env))
            if (index + 1) % 12 == 0: print(json.dumps(dict(completed=index + 1, planned=144)), flush=True)
        aggregates, comparisons = analyze(rows)
        frozen_allocation = sum(Path(record["path"]).stat().st_blocks * 512 for record in plan["binaries"].values())
        final_tooling = tooling_allocation() + frozen_allocation
        if final_tooling > TOOL_LIMIT: raise ValueError("Final tooling allocation exceeds independent ceiling")
        gate_summary = {}
        for pair in ("swift-value-vs-swift-baseline", "rust-baseline-vs-swift-baseline", "rust-baseline-vs-swift-value"):
            selected = [value for key, value in comparisons.items() if key.endswith("/" + pair)]
            gate_summary[pair] = dict(all_four_speed_route_pass=all(value["speed_route_pass"] for value in selected),
                                      all_four_memory_route_pass=all(value["memory_route_pass"] for value in selected))
        report = dict(schema=1, complete=True, rows=rows, prime_count=len(primes), aggregates=aggregates, comparisons=comparisons,
                      budget=packet.budget(), tooling_allocated=final_tooling, gates=GATES, gate_summary=gate_summary,
                      limits=["Uncontrolled ordinary filesystem cache, no cold-cache claim", "12 samples per cell; nearest-rank p95 equals maximum",
                              "Summary-only timed output; full-entry correctness qualified separately", "No rejected/outlier replacement",
                              "Process/runtime/layout costs differ; no language-only or production claim",
                              "post_drain_rss retains aggregates; not post-release RSS or reusable-session leak proof"])
        save(evidence / "report.json", report, MAX_REPORT)
        return report
    except Exception as error:
        save(evidence / "report.json", dict(schema=1, complete=False, disposition="stopped_without_replacement",
             accepted_rows=rows, successful_prime_count=len(primes), error_type=type(error).__name__, reason=str(error)[:512]), MAX_REPORT)
        raise


@contextmanager
def exclusive_packet():
    fd = packet.directory_fd(packet.BASE)
    try: lock = os.open(".lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    finally: os.close(fd)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally: os.close(lock)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True); parser.add_argument("--candidate", required=True)
    parser.add_argument("--qualification", required=True); parser.add_argument("--correctness-wide", required=True)
    parser.add_argument("--correctness-mixed", required=True); parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args(); run = packet.admit(args.run)
    with exclusive_packet():
        admitted = load_qualification(run, Path(args.candidate), Path(args.qualification).absolute(),
                                      {corpus: Path(getattr(args, "correctness_" + corpus)).absolute() for corpus in ("wide", "mixed")})
        if args.validate_only:
            print(json.dumps(dict(complete=True, timed=False, forecast=forecast(admitted), qualification=admitted["qualification"])), flush=True); return
        evidence, plan = freeze(run, admitted)
        print(json.dumps(dict(evidence=str(evidence), samples=144, frozen=True)), flush=True)
        report = run_cohort(evidence, plan)
        print(json.dumps(dict(evidence=str(evidence), complete=report["complete"], samples=len(report["rows"]))), flush=True)


if __name__ == "__main__": main()
