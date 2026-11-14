#!/usr/bin/env python3
"""Untimed correctness/audit packet for the isolated Swift value-layout fork."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/analyzer"))
sys.path.insert(0, str(REPO / "tools/analyzer/audit"))
from packet import Generator, admit, budget, corpus_root, create_directory, identity, oracle, put, read_owned
from qualify import Consumer, SWIFT, collect, command, independent_sizes
from run_audit import KEYS as AUDIT_KEYS, environment
from build import FROZEN, NATIVE_OBJECT, OUTPUT, verify_frozen
from verify_derivation import verify

CANDIDATE = OUTPUT / "b06-swift-layout-scanner"
CORE_KEYS = ["entries", "regular_entries", "directory_entries", "symlink_entries", "other_entries", "objects",
             "entry_totals", "object_totals", "missing_fields", "digest_count", "digest_sum", "digest_xor",
             "object_accounting_state", "outside_link_objects"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(root: Path, lane: str, session: str, binary: Path, extras: list[str] | None = None) -> list[str]:
    argv = command(root, lane, session, extras, expected_identity=identity(root))
    argv[0] = str(binary)
    return argv


def require(value: bool, reason: str) -> None:
    if not value: raise ValueError(reason)


def run_faults(owner: Path, evidence: Path) -> dict:
    """Small new generated roots, never the immutable timed corpora."""
    generator = Generator(owner, "layout-faults", (250, 4096, 1 << 20))
    for directory in [b"denied", b"nested", b"nested/deeper"]: generator.directory(directory)
    for path, body in [(b"zero", b""), (b"denied/known", b"generated"),
                       (b"nested/deeper/known", b"generated"), (b"original", b"shared")]:
        generator.file(path, body)
    os.link(generator.root / "original", generator.root / "inside", follow_symlinks=False)
    generator.record(b"inside", "regular", 6)
    holder = Generator(owner, "layout-holder", (4, 4096, 65536))
    os.link(generator.root / "original", holder.root / "outside", follow_symlinks=False)
    holder.record(b"outside", "regular", 6)
    generator.finish(); holder.finish()
    root = corpus_root(owner, "layout-faults")
    observations = []
    for lane in ["bulk", "foundation"]:
        cases = [("complete", [], False), ("cancel-zero", ["--cancel-after", "0"], True),
                 ("cancel-one", ["--cancel-after", "1"], True),
                 ("depth", ["--maximum-depth", "0"], True), ("queue", ["--maximum-queue", "1"], True),
                 ("denied", [], True), ("unreadable-body", [], False)]
        for label, extras, partial in cases:
            session = "layout-" + label + "-" + lane
            changed = root / ("denied" if label == "denied" else "zero")
            if label in ["denied", "unreadable-body"]: changed.chmod(0)
            try:
                result = collect(invoke(root, lane, session, CANDIDATE, ["--summary-only", *extras]),
                                 session, evidence / (session + ".stderr"), timeout=15)
            finally:
                if label in ["denied", "unreadable-body"]:
                    changed.chmod(0o700 if label == "denied" else 0o600)
            put(evidence / (session + ".json"), result)
            require(result["returncode"] == (2 if partial else 0) and result["summary"]["complete"] is (not partial),
                    "Incorrect layout fault disposition: " + label)
            if label == "complete": require(result["summary"]["outside_link_objects"] == "1", "External hardlink hidden")
            if label.startswith("cancel"):
                require(result["summary"]["entries"] == ("0" if label == "cancel-zero" else "1"), "Incorrect cancellation boundary")
            observations.append(dict(label=label, lane=lane, passed=True, result=result))
    refusals = []
    for invalid in [owner / "fixtures", root / "nested", Path("/")]:
        argv = invoke(root, "bulk", "layout-refusal", CANDIDATE)
        argv[argv.index("--root") + 1] = str(invalid)
        result = subprocess.run(argv, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        require(result.returncode == 64 and not result.stdout, "Broader layout root admitted")
        refusals.append(dict(passed=True, returncode=result.returncode, stdout_bytes=len(result.stdout)))
    argv = invoke(root, "bulk", "layout-wrong-identity", CANDIDATE)
    argv[argv.index("--expected-ino") + 1] = "1"
    result = subprocess.run(argv, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    frames = [json.loads(line) for line in result.stdout.splitlines()]
    terminal = [row for row in frames if row.get("kind") == "summary"]
    require(result.returncode == 2 and len(terminal) == 1 and not terminal[0]["complete"]
            and terminal[0]["entries"] == "0", "Wrong layout identity admitted")
    repeat = []
    for index in range(20):
        session = "layout-repeat-" + str(index)
        extras = ["--cancel-after", "1"] if index % 2 else []
        result = collect(invoke(root, "bulk", session, CANDIDATE, ["--summary-only", *extras]), session,
                         evidence / (session + ".stderr"), timeout=15)
        put(evidence / (session + ".json"), result)
        require(result["returncode"] == (2 if index % 2 else 0), "Repeated layout disposition failed")
        require(int(result["summary"]["peak_owned_fds"]) <= 3, "Layout descriptor ceiling breached")
        repeat.append(result)
    return dict(passed=True, cases=observations, refusals=refusals, wrong_identity=frames, repeat=repeat,
                limit="Fresh-process controls; no reusable in-process lifecycle claim")


def blocked_consumer_controls(owner: Path, evidence: Path) -> dict:
    generator = Generator(owner, "layout-stall", (220, 4096, 1 << 20))
    for index in range(200): generator.file(("item-" + str(index)).encode())
    generator.finish()
    root = corpus_root(owner, "layout-stall")
    results = []
    child = subprocess.Popen(invoke(root, "bulk", "layout-stall", CANDIDATE), cwd=REPO,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    began = time.monotonic_ns()
    try: child.wait(timeout=7)
    except BaseException:
        child.kill(); child.communicate(); raise
    stdout, stderr = child.communicate()
    results.append(dict(test="consumer-stall", elapsed_ns=time.monotonic_ns() - began,
                        returncode=child.returncode, stdout_bytes=len(stdout), stderr_bytes=len(stderr)))
    require(child.returncode == 2, "Layout consumer stall did not exit partial")
    child = subprocess.Popen(invoke(root, "bulk", "layout-signal-stall", CANDIDATE), cwd=REPO,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(.1)
    began = time.monotonic_ns(); child.send_signal(signal.SIGTERM)
    try: child.wait(timeout=2)
    except BaseException:
        child.kill(); child.communicate(); raise
    stdout, stderr = child.communicate()
    results.append(dict(test="signal-while-stalled", elapsed_ns=time.monotonic_ns() - began,
                        returncode=child.returncode, stdout_bytes=len(stdout), stderr_bytes=len(stderr)))
    require(child.returncode == 2, "Layout stalled cancellation did not exit partial")
    # This deterministic replacement stays wholly within this new owned fixture.
    child = subprocess.Popen(invoke(root, "bulk", "layout-root-replaced", CANDIDATE), cwd=REPO,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    moved = root.with_name("layout-stall-retained")
    replaced = False
    try:
        while True:
            line = child.stdout.readline()
            require(bool(line), "Layout replacement control ended before progress")
            if json.loads(line)["kind"] == "progress": break
        root.rename(moved); root.symlink_to("layout-faults", target_is_directory=True); replaced = True
        stdout, stderr = child.communicate(timeout=5)
    except BaseException:
        child.kill(); child.communicate(); raise
    finally:
        if replaced: root.unlink(); moved.rename(root)
    rows = [json.loads(line) for line in stdout.splitlines()]
    terminal = [row for row in rows if row["kind"] == "summary"]
    require(child.returncode == 2 and len(terminal) == 1 and not terminal[0]["complete"], "Layout root replacement appeared complete")
    results.append(dict(test="root-symlink-replacement", returncode=child.returncode, summary=terminal[0]))
    result = dict(passed=True, results=results, limit="Controlled pipe/rename observations, not a blocked-kernel-call deadline")
    put(evidence / "blocked-consumer-controls.json", result)
    return result


def audit(root: Path, evidence: Path) -> dict:
    library = REPO / ".build/b06-toolchain/audit/libB06FileReadAudit.dylib"
    require(library.is_file() and library.resolve() == library, "Qualified audit library missing or redirected")
    observed = identity(root)
    results = []
    for lane in ["bulk", "foundation"]:
        session = "layout-audit-" + lane
        env = environment()
        env.update(DYLD_INSERT_LIBRARIES=str(library), B06_AUDIT_ROOT=str(root),
                   B06_AUDIT_DEV=str(observed[0]), B06_AUDIT_INO=str(observed[1]))
        stderr = evidence / (session + ".stderr")
        result = collect(invoke(root, lane, session, CANDIDATE, ["--summary-only"]), session,
                         stderr, timeout=30, env=env)
        lines = read_owned(stderr, 16384).splitlines()
        receipts = [json.loads(line) for line in lines if line.startswith(b'{"b06_file_read_audit":')]
        receipt = receipts[0] if len(receipts) == 1 else {}
        passed = (result["returncode"] == 0 and result["summary"]["complete"]
                  and set(receipt) == {"b06_file_read_audit", "configured", *AUDIT_KEYS}
                  and receipt.get("configured") == 1 and all(receipt.get(key) == 0 for key in AUDIT_KEYS))
        record = dict(lane=lane, passed=passed, receipt=receipt, candidate_sha256=sha(CANDIDATE),
                      library_sha256=sha(library), result=result)
        put(evidence / (session + ".json"), record)
        require(passed, "Layout controlled file-body audit failed")
        require(identity(root) == observed, "Audit corpus replaced")
        results.append(record)
    return dict(passed=True, candidate_sha256=sha(CANDIDATE), results=results,
                coverage="Previously qualified public/nocancel interposer on immutable accounting corpus; not exhaustive kernel tracing")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, help="Existing immutable smoke/edge/wide/mixed run")
    args = parser.parse_args()
    verify_frozen(); verify()
    source_run = admit(args.run)
    # No new large payloads. This includes small fault roots and all receipts.
    budget(800, 2 << 20, 8 << 20)
    owner = admit(None)
    evidence = owner / "evidence" / ("layout-qualification-" + uuid.uuid4().hex)
    create_directory(evidence)
    candidate_hash = sha(CANDIDATE)
    report = dict(schema=1, kind="swift-layout-qualification", complete=False,
                  source_run=str(source_run), evidence=str(evidence), frozen=FROZEN,
                  candidate=dict(path=str(CANDIDATE), sha256=candidate_hash,
                                 sources={str(path.relative_to(REPO)): sha(path) for path in
                                          [REPO / "tools/analyzer/layout/main.swift", REPO / "tools/analyzer/layout/ValueLayout.swift"]}),
                  baseline=dict(path=str(SWIFT), sha256=sha(SWIFT)),
                  native_object=dict(path=str(NATIVE_OBJECT), sha256=sha(NATIVE_OBJECT)), corpora={})
    try:
        tests = {}
        for label, flag in [("parser", "--self-test"), ("layout", "--layout-self-test")]:
            result = subprocess.run([str(CANDIDATE), flag], cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            require(result.returncode == 0 and not result.stderr, "Candidate self-test failed")
            tests[label] = json.loads(result.stdout)
        report["self_tests"] = tests
        for corpus in ["smoke", "edges-v2", "wide", "mixed"]:
            root = corpus_root(source_run, corpus); observed = identity(root)
            independent = oracle(source_run, corpus)
            expected = {row["relative_b64"]: row for row in map(json.loads,
                        read_owned(source_run / "manifests" / (corpus + ".ndjson"), 64 << 20).splitlines())}
            sizes = independent_sizes(root, expected) if corpus.startswith("edges") else {}
            observations = {}
            for label, binary, lane in [("baseline-bulk", SWIFT, "bulk"), ("layout-bulk", CANDIDATE, "bulk"),
                                        ("layout-foundation", CANDIDATE, "foundation")]:
                session = "layout-qualify-" + corpus + "-" + label
                result = collect(invoke(root, lane, session, binary), session,
                                 evidence / (session + ".stderr"), Consumer(expected, sizes), timeout=120)
                result["binary_sha256"] = sha(binary)
                put(evidence / (session + ".json"), result)
                require(result["returncode"] == 0 and result["summary"]["complete"], "Candidate correctness partial")
                require(identity(corpus_root(source_run, corpus)) == observed, "Correctness corpus replaced")
                observations[label] = result
            canonical = {key: observations["baseline-bulk"]["summary"][key] for key in CORE_KEYS}
            require(all(all(value["summary"][key] == canonical[key] for key in CORE_KEYS)
                        for value in observations.values()), "Candidate canonical record/accounting parity failed")
            require(int(canonical["object_totals"]["data_logical"]) == independent["object_data_logical"], "Independent object total failed")
            require(oracle(source_run, corpus) == independent, "Corpus metadata changed across qualification")
            report["corpora"][corpus] = dict(root=str(root), dev=observed[0], ino=observed[1],
                                             manifest_sha256=independent["manifest_sha256"], oracle=independent,
                                             expected=canonical, observations=observations)
            print(json.dumps(dict(phase="correctness", corpus=corpus, entries=canonical["entries"], passed=True)), flush=True)
        report["controls"] = run_faults(owner, evidence)
        report["blocked_consumer"] = blocked_consumer_controls(owner, evidence)
        report["audit"] = audit(corpus_root(source_run, "edges-v2"), evidence)
        verify_frozen(); verify()
        require(sha(CANDIDATE) == candidate_hash, "Candidate binary changed during qualification")
        report.update(complete=True, budget=budget())
        put(evidence / "qualification.json", report)
        print(json.dumps(dict(complete=True, qualification=str(evidence / "qualification.json"), candidate_sha256=candidate_hash)), flush=True)
    except BaseException as error:
        report.update(complete=False, failure=dict(type=type(error).__name__, reason=str(error)[:512]))
        put(evidence / "qualification-failed.json", report)
        raise


if __name__ == "__main__": main()
