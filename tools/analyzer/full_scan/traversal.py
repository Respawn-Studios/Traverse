#!/usr/bin/env python3
"""Isolated DFS qualification; unchanged production worker and existing corpora.

Derived source/binaries stay in the inventoried tooling root. Only the bounded
numeric JSON receipt receives the approved evidence allowance. No personal scan,
new corpus, file-body read, cleanup or production routing occurs here.
"""
from __future__ import annotations
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import statistics
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import refinement_budget
from packet import REPO, directory_fd, identity, read_owned
from qualify import Consumer

SOURCE = REPO / "Workers/StorageScanner"
CORPUS = REPO / ".build/b06-analyzer/20261017T140537Z-6faf182f69"
TOOL_ROOT = REPO / ".build/b06-consumer-profile-build"
EVIDENCE = REPO / ".build/b06-analyzer/evidence-extension-20261018"
RUSTC = REPO / ".build/b06-toolchain/rust-1.99.1/bin/rustc"
LANES = {"dfs64-256k": (64, 256 << 10), "dfs128-256k": (128, 256 << 10), "dfs64-1m": (64, 1 << 20)}
CORE = ["entries", "regular_entries", "directory_entries", "symlink_entries", "other_entries", "objects",
        "entry_totals", "object_totals", "missing_fields", "digest_count", "digest_sum", "digest_xor",
        "object_accounting_state", "outside_link_objects"]


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1: raise ValueError("source derivation marker changed: " + old[:80])
    return text.replace(old, new, 1)


def derive(depth, buffer):
    source = (SOURCE / "main.rs").read_text()
    source = replace_once(source, "mod policy;", f"mod policy;\nconst EXPERIMENT_DEPTH:usize={depth};\nconst EXPERIMENT_BUFFER:usize={buffer};")
    source = replace_once(source, "maximum_depth:64,maximum_queue:4096};", "maximum_depth:EXPERIMENT_DEPTH,maximum_queue:4096};")
    begin, end = source.index("    fn receive("), source.index("    fn scan(&mut self)")
    receive = source[begin:end]
    child = replace_once(receive, "fn receive(&mut self,o:&Observation,pending:&Pending,queue:&mut Vec<Pending>,head:usize) -> Result<()>",
                         "fn receive_child(&mut self,o:&Observation,pending:&Pending) -> Result<Option<Pending>>")
    child = child.replace("return Ok(());", "return Ok(None);")
    child = replace_once(child, '            if queue.len()-head>=self.options.maximum_queue{return Err("queue_limit");}\n', "")
    child = replace_once(child, "queue.push(Pending{path,dev,ino,depth:pending.depth+1});self.peak_queue=self.peak_queue.max(queue.len()-head);",
                         "return Ok(Some(Pending{path,dev,ino,depth:pending.depth+1}));")
    child = replace_once(child, "}Ok(())", "}Ok(None)")
    source = source[:begin] + "    #[allow(dead_code)]\n" + receive + child + source[end:]
    begin = source.index("        let mut queue=vec![Pending")
    end = source.index("    fn check_namespace", begin)
    source = source[:begin] + "        self.dfs_walk(root.0,&path)\n    }\n" + source[end:]
    # Tests suppress direct protocol writes, but run the same admission/accounting.
    source = replace_once(source, "        if self.output_failed || self.terminal {return;}",
                         "        if cfg!(test) {return;}\n        if self.output_failed || self.terminal {return;}")
    return source + "\n" + (HERE / "DepthFirst.rs").read_text()


def build(output, record):
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "B06_", "AUDIT_", "RUST", "CARGO"))}
    env.update(TMPDIR=str(output), SDKROOT=sdk, MACOSX_DEPLOYMENT_TARGET="15.0")
    native = output / "ScannerNative.o"
    subprocess.run(["clang", "-O3", "-target", "arm64-apple-macosx15.0", "-isysroot", sdk,
                    "-c", str(SOURCE / "ScannerNative.c"), "-o", str(native)], env=env, check=True)
    (output / "policy.rs").write_bytes((SOURCE / "policy.rs").read_bytes())
    (output / "policy-vectors.tsv").write_bytes((SOURCE / "policy-vectors.tsv").read_bytes())
    record["compiler"] = subprocess.check_output([str(RUSTC), "-vV"], env=env, text=True)
    record["sdk"] = sdk
    bins = {"bfs": REPO / ".build/storage-scanner/storage-scanner-worker"}
    for lane, (depth, buffer) in LANES.items():
        code = output / (lane + ".rs"); code.write_text(derive(depth, buffer))
        args = [str(RUSTC), "--edition=2024", "-C", "opt-level=3", "-C", "panic=abort", "-C", "lto=thin", "-C", "codegen-units=1", "-C", "linker=/usr/bin/clang",
                "-C", "link-arg=-isysroot", "-C", "link-arg=" + sdk, "-C", "link-arg=" + str(native),
                "--target=aarch64-apple-darwin", str(code)]
        binary = output / lane
        result = subprocess.run(args + ["-o", str(binary)], env=env, capture_output=True, timeout=120)
        (output / (lane + "-build.txt")).write_bytes(result.stdout + result.stderr)
        if result.returncode: raise ValueError("candidate build failed: " + lane)
        if lane == "dfs64-256k":
            test = output / "controls"
            test_args = args.copy()
            index = test_args.index("panic=abort"); del test_args[index - 1:index + 1]
            result = subprocess.run(test_args + ["--test", "-o", str(test)], env=env, capture_output=True, timeout=120)
            (output / "controls-build.txt").write_bytes(result.stdout + result.stderr)
            if result.returncode: raise ValueError("test build failed")
            tests = subprocess.run([str(test)], env=env, capture_output=True, timeout=20)
            (output / "controls.txt").write_bytes(tests.stdout + tests.stderr)
            if tests.returncode: raise ValueError("parser/policy/width controls failed")
            record["rust_tests"] = tests.stdout.decode()[-2048:]
        for option in ("--self-test", "--policy-self-test"):
            result = subprocess.run([str(binary), option], env=env, capture_output=True, timeout=5)
            if result.returncode or result.stderr: raise ValueError("fixed parser/policy control failed")
        bins[lane] = binary
    record["binaries"] = {key: sha(path) for key, path in bins.items()}
    return bins


def collect(binary, root, *, expected=None, verify=False, cancel=False, stall=False):
    original = directory_fd(root)
    dev, ino = os.fstat(original).st_dev, os.fstat(original).st_ino
    descriptor = fcntl.fcntl(original, fcntl.F_DUPFD_CLOEXEC, 10); os.close(original)
    out, err = os.pipe(), os.pipe(); session = str(uuid.uuid4())
    argv = [str(binary), "--root-fd", "3", "--expected-dev", str(dev), "--expected-ino", str(ino), "--session", session]
    began = time.monotonic(); pid = os.posix_spawn(str(binary), argv, {"LANG": "C", "LC_ALL": "C"},
        file_actions=[(os.POSIX_SPAWN_DUP2, out[1], 1), (os.POSIX_SPAWN_DUP2, err[1], 2), (os.POSIX_SPAWN_DUP2, descriptor, 3)])
    for fd in (descriptor, out[1], err[1]): os.close(fd)
    summary = None; status = None; sequence = rows = stderr = 0; pending = b""; issues = []
    consumer = Consumer(expected) if verify else None
    directories = {b""}; cancelled_at = None; peak = 0
    try:
        with selectors.DefaultSelector() as selector:
            if not stall: selector.register(out[0], selectors.EVENT_READ, "out")
            selector.register(err[0], selectors.EVENT_READ, "err")
            while selector.get_map() or status is None:
                if status is None:
                    got, s, usage = os.wait4(pid, os.WNOHANG)
                    if got: status = s; peak = usage.ru_maxrss
                if time.monotonic() - began > (8 if stall else 45): raise TimeoutError("bounded worker deadline")
                if stall and cancel and cancelled_at is None and time.monotonic() - began > .15:
                    os.kill(pid, signal.SIGTERM); cancelled_at = time.monotonic()
                for key, _ in selector.select(.01):
                    data = os.read(key.fd, 65536)
                    if not data: selector.unregister(key.fd); continue
                    if key.data == "err":
                        stderr += len(data)
                        if stderr > 4096: raise ValueError("stderr bound")
                        continue
                    pending += data
                    if len(pending) > 131072: raise ValueError("frame bound")
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        frame = json.loads(line)
                        if len(line) >= 65536 or frame.get("schema") != 2 or frame.get("session") != session or int(frame["seq"]) != sequence:
                            raise ValueError("protocol envelope")
                        sequence += 1
                        if frame["kind"] == "batch":
                            if not 1 <= len(frame["rows"]) <= 128: raise ValueError("batch bound")
                            for row in frame["rows"]:
                                rows += 1
                                if verify:
                                    raw = base64.b64decode(row["relative_b64"], validate=True)
                                    if raw.rpartition(b"/")[0] not in directories: raise ValueError("not parent first")
                                    if row["type"] == "directory": directories.add(raw)
                                    consumer.accept(row)
                            if cancel and cancelled_at is None:
                                os.kill(pid, signal.SIGTERM); cancelled_at = time.monotonic()
                        elif frame["kind"] == "issue": issues.append(frame["code"])
                        elif frame["kind"] == "summary":
                            if summary is not None: raise ValueError("duplicate terminal")
                            summary = frame
        elapsed = time.monotonic() - began
        code = os.waitstatus_to_exitcode(status)
        if stall:
            if code != 2: raise ValueError("blocked output did not stop")
        else:
            if summary is None or pending or code != (0 if summary["complete"] else 2) or stderr:
                raise ValueError("terminal/exit disagreement")
            if consumer:
                # A bounded partial traversal need not exhaust the full manifest.
                if not summary["complete"]: consumer.expected = None
                consumer.finish(summary)
            if cancel and (summary["reason"] != "cancelled" or time.monotonic() - cancelled_at > 1):
                raise ValueError("cancel drain gate")
        return {"summary": summary, "elapsed_seconds": elapsed, "rows": rows, "issues": issues,
                "cancel_to_exit_seconds": None if cancelled_at is None else time.monotonic() - cancelled_at,
                "wait4_peak_bytes": peak, "actual_exit_observed": True}
    finally:
        if status is None:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
            os.waitpid(pid, 0)
        for fd in (out[0], err[0]): os.close(fd)


def small(value):
    summary = value["summary"]
    return {"entries": None if summary is None else summary["entries"],
            "complete": None if summary is None else summary["complete"],
            "reason": None if summary is None else summary["reason"],
            "worker_seconds": None if summary is None else int(summary["elapsed_ns"]) / 1e9,
            "consumer_seconds": value["elapsed_seconds"], "peak_bytes": value["wait4_peak_bytes"],
            "fds": None if summary is None else int(summary["peak_owned_fds"]),
            "stack_or_queue": None if summary is None else int(summary["peak_queued_dirs"]),
            "cancel_to_exit_seconds": value["cancel_to_exit_seconds"], "issues": value["issues"]}


def main():
    before = refinement_budget.inspect()
    if not before["passed"] or before["isolated_tooling_allocated"] + (32 << 20) > 2 << 30:
        raise ValueError("isolated tooling admission")
    if before["extra_evidence"]["remaining_bytes"] < 65536 or before["combined"]["entries"] + 3 > before["limits"]["entries"]:
        raise ValueError("evidence admission")
    output = TOOL_ROOT / ("dfs-" + uuid.uuid4().hex); output.mkdir(mode=0o700)
    record = {"schema": 1, "complete": False, "scope": "Standalone generated-corpus traversal qualification; no ordinary routing, personal scan or new fixture.",
              "source": {str(p.relative_to(REPO)): sha(p) for p in [SOURCE / "main.rs", SOURCE / "ScannerNative.c", SOURCE / "policy.rs", HERE / "DepthFirst.rs", Path(__file__)]},
              "tool_output": str(output.relative_to(REPO)), "samples": [], "controls": [], "before": before,
              "gates": {"median_regression": .10, "max_repeat_regression": .15, "worker_incremental_ceiling": 256 << 20,
                        "baseline_descriptor_bound": 67, "baseline_bulk_buffer_bound": 16 << 20},
              "not_qualified": ["System/Data combined scan", "deeper access policy", "signed app end-to-end", "new transport/store integration", "concurrent native folder replacement", "power loss"]}
    failure = None
    try:
        bins = build(output, record)
        controls = {}
        for corpus in ("wide", "mixed"):
            root = CORPUS / "fixtures" / corpus
            proof = json.loads(read_owned(CORPUS / "manifests" / (corpus + ".json"), 4096))
            if identity(root) != (proof["dev"], proof["ino"]): raise ValueError("generated identity changed")
            manifest = {r["relative_b64"]: r for r in map(json.loads, read_owned(CORPUS / "manifests" / (corpus + ".ndjson"), 128 << 20).splitlines())}
            for lane, binary in bins.items():
                result = collect(binary, root, expected=manifest, verify=True)
                summary = result["summary"]
                if lane != "dfs128-256k" and lane != "bfs":
                    if any(summary[k] != controls[(corpus, "bfs")][k] for k in CORE): raise ValueError("equivalent-limit accounting mismatch")
                if lane == "dfs128-256k" and (not summary["complete"] or int(summary["entries"]) != len(manifest)):
                    raise ValueError("higher-depth independent coverage mismatch")
                if lane in LANES:
                    depth, _ = LANES[lane]
                    if int(summary["peak_owned_fds"]) > depth + 3 or int(summary["incremental_peak_rss"]) > 256 << 20:
                        raise ValueError("resource gate")
                controls[(corpus, lane)] = summary
                record["controls"].append({"case": corpus, "lane": lane, "parent_first_and_independent": True, **small(result)})
            del manifest
        root = CORPUS / "fixtures/wide"
        for label, options in (("stream-cancel", {"cancel": True}), ("blocked-cancel", {"cancel": True, "stall": True}), ("blocked-timeout", {"stall": True})):
            value = collect(bins["dfs64-256k"], root, **options)
            if label == "blocked-cancel" and value["cancel_to_exit_seconds"] > 2: raise ValueError("blocked cancel drain gate")
            record["controls"].append({"case": label, **small(value)})
        # One retained prime per lane/corpus precedes all timed repeats.
        for corpus in ("wide", "mixed"):
            root = CORPUS / "fixtures" / corpus
            for lane, binary in bins.items(): record["samples"].append({"phase": "prime", "case": corpus, "lane": lane, **small(collect(binary, root))})
            for repeat in range(3):
                order = list(bins) if repeat % 2 == 0 else list(reversed(bins))
                for lane in order:
                    value = collect(bins[lane], root)
                    record["samples"].append({"phase": "measured", "repeat": repeat, "case": corpus, "lane": lane, **small(value)})
        ratios = []
        for corpus in ("wide", "mixed"):
            baseline = [v for v in record["samples"] if v["phase"] == "measured" and v["case"] == corpus and v["lane"] == "bfs"]
            for lane in LANES:
                values = [v for v in record["samples"] if v["phase"] == "measured" and v["case"] == corpus and v["lane"] == lane]
                median = statistics.median(v["worker_seconds"] for v in values) / statistics.median(v["worker_seconds"] for v in baseline)
                paired = [v["worker_seconds"] / next(b["worker_seconds"] for b in baseline if b["repeat"] == v["repeat"]) for v in values]
                ratios.append({"case": corpus, "lane": lane, "median_worker_ratio": median, "max_paired_ratio": max(paired),
                               "timing_gate": median <= 1.10 and max(paired) <= 1.15})
        record["ratios"] = ratios; record["complete"] = True
        record["all_timing_gates"] = all(v["timing_gate"] for v in ratios)
    except BaseException as error:
        failure = error; record["failure"] = type(error).__name__ + ":" + str(error)[:256]
    record["after"] = refinement_budget.inspect()
    if not EVIDENCE.exists(): EVIDENCE.mkdir(mode=0o700)
    data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > 65536: raise ValueError("bounded evidence projection")
    receipt = EVIDENCE / ("traversal-" + uuid.uuid4().hex + ".json")
    with receipt.open("xb") as target: target.write(data)
    print(json.dumps({"complete": record["complete"], "receipt": str(receipt.relative_to(REPO)), "failure": record.get("failure"), "ratios": record.get("ratios")}))
    if failure: raise SystemExit(2)


if __name__ == "__main__": main()
