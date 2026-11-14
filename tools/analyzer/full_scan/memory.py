#!/usr/bin/env python3
"""Isolated consumed-buffer lifetime comparison against the frozen DFS binary."""
from __future__ import annotations
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import uuid
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import traversal as t


def main():
    before = t.refinement_budget.inspect()
    if not before["passed"] or before["combined"]["entries"] + 1 > before["limits"]["entries"] or before["isolated_tooling_allocated"] + (16 << 20) > 2 << 30:
        raise ValueError("bounded memory experiment admission")
    prior = json.loads((t.EVIDENCE / "traversal-fdd17e4e26ab416c9160c2d102db2fb7.json").read_text())
    baseline = t.REPO / prior["tool_output"] / "dfs64-256k"
    if t.sha(baseline) != prior["binaries"]["dfs64-256k"]: raise ValueError("frozen DFS baseline changed")
    output = t.TOOL_ROOT / ("dfs-memory-" + uuid.uuid4().hex); output.mkdir(mode=0o700)
    record = {"schema": 1, "complete": False, "before": before, "samples": [], "controls": [],
              "scope": "Consumed bulk-buffer lifetime only; unchanged generated corpora, limits/guards/output. No app adoption.",
              "source": {str(p.relative_to(t.REPO)): t.sha(p) for p in [HERE / "DepthFirst.rs", Path(__file__)]},
              "tool_output": str(output.relative_to(t.REPO)), "baseline_sha256": t.sha(baseline),
              "gates": {"mixed_peak_reduction": .20, "wide_peak_regression": .05, "median_time_regression": .10, "paired_time_regression": .15}}
    failure = None
    try:
        code = t.derive(64, 256 << 10)
        code = t.replace_once(code, "if let Some(child) = self.receive_child(&observation, &frame.pending)? {",
            "if let Some(child) = self.receive_child(&observation, &frame.pending)? {\n                    if frame.remaining == 0 { frame.buffer = Vec::new(); }")
        (output / "main.rs").write_text(code)
        for name in ("policy.rs", "policy-vectors.tsv"): (output / name).write_bytes((t.SOURCE / name).read_bytes())
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        native = t.REPO / prior["tool_output"] / "ScannerNative.o"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "RUST", "CARGO", "B06_", "AUDIT_"))}; env["TMPDIR"] = str(output)
        binary = output / "release-consumed"
        args = [str(t.RUSTC), "--edition=2024", "-C", "opt-level=3", "-C", "panic=abort", "-C", "lto=thin", "-C", "codegen-units=1",
                "--target=aarch64-apple-darwin", "-C", "link-arg=-isysroot", "-C", "link-arg=" + sdk,
                "-C", "link-arg=" + str(native), str(output / "main.rs"), "-o", str(binary)]
        result = subprocess.run(args, env=env, capture_output=True, timeout=60)
        (output / "build.txt").write_bytes(result.stdout + result.stderr)
        if result.returncode or result.stderr: raise ValueError("memory candidate build")
        record["candidate_sha256"] = t.sha(binary)
        bins = {"retained": baseline, "released": binary}
        for corpus in ("wide", "mixed"):
            root = t.CORPUS / "fixtures" / corpus
            proof = json.loads(t.read_owned(t.CORPUS / "manifests" / (corpus + ".json"), 4096))
            if t.identity(root) != (proof["dev"], proof["ino"]): raise ValueError("generated identity changed")
            manifest = {r["relative_b64"]: r for r in map(json.loads, t.read_owned(t.CORPUS / "manifests" / (corpus + ".ndjson"), 128 << 20).splitlines())}
            observed = []
            for lane, current in bins.items():
                value = t.collect(current, root, expected=manifest, verify=True)
                record["controls"].append({"case": corpus, "lane": lane, **t.small(value)})
                observed.append(value["summary"])
            if any(observed[0][k] != observed[1][k] for k in t.CORE): raise ValueError("memory change altered accounting")
            del manifest
            for lane, current in bins.items(): record["samples"].append({"phase": "prime", "case": corpus, "lane": lane, **t.small(t.collect(current, root))})
            for repeat in range(3):
                for lane in (list(bins) if repeat % 2 == 0 else list(reversed(bins))):
                    record["samples"].append({"phase": "measured", "case": corpus, "repeat": repeat, "lane": lane, **t.small(t.collect(bins[lane], root))})
        root = t.CORPUS / "fixtures/wide"
        for label, options in (("stream-cancel", {"cancel": True}), ("blocked-cancel", {"cancel": True, "stall": True}), ("blocked-timeout", {"stall": True})):
            value = t.collect(binary, root, **options)
            if label == "blocked-cancel" and value["cancel_to_exit_seconds"] > 2: raise ValueError("blocked drain gate")
            record["controls"].append({"case": label, **t.small(value)})
        ratios = []
        for corpus in ("wide", "mixed"):
            a = [v for v in record["samples"] if v["phase"] == "measured" and v["case"] == corpus and v["lane"] == "retained"]
            b = [v for v in record["samples"] if v["phase"] == "measured" and v["case"] == corpus and v["lane"] == "released"]
            timing = statistics.median(v["worker_seconds"] for v in b) / statistics.median(v["worker_seconds"] for v in a)
            paired = max(v["worker_seconds"] / next(x["worker_seconds"] for x in a if x["repeat"] == v["repeat"]) for v in b)
            peak = max(v["peak_bytes"] for v in b) / max(v["peak_bytes"] for v in a)
            ratios.append({"case": corpus, "median_worker_ratio": timing, "max_paired_worker_ratio": paired,
                           "peak_ratio": peak, "timing_gate": timing <= 1.10 and paired <= 1.15,
                           "memory_gate": peak <= (.8 if corpus == "mixed" else 1.05)})
        record["ratios"] = ratios; record["complete"] = True
        record["gates_passed"] = all(v["timing_gate"] and v["memory_gate"] for v in ratios)
    except BaseException as error:
        failure = error; record["failure"] = type(error).__name__ + ":" + str(error)[:256]
    record["after"] = t.refinement_budget.inspect()
    data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > 65536: raise ValueError("bounded memory evidence")
    receipt = t.EVIDENCE / ("dfs-memory-" + uuid.uuid4().hex + ".json")
    with receipt.open("xb") as target: target.write(data)
    print(json.dumps({"complete": record["complete"], "failure": record.get("failure"), "receipt": str(receipt.relative_to(t.REPO)), "ratios": record.get("ratios")}))
    if failure: raise SystemExit(2)


if __name__ == "__main__": main()
