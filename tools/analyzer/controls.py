#!/usr/bin/env python3
"""Generated-filesystem controls separate from decisive Batch06 timing."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
from packet import Generator, admit, budget, corpus_root, put
from qualify import RUST, SWIFT, collect, command


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    args = parser.parse_args()
    run = admit(args.run)
    batch = uuid.uuid4().hex[:12]
    evidence = run / "evidence" / ("controls-" + batch)
    from packet import create_directory
    create_directory(evidence)
    g = Generator(run, "faults-" + batch, (30, 4096, 65536))
    for name in [b"denied", b"nested", b"nested/deeper"]: g.directory(name)
    g.file(b"zero")
    g.file(b"denied/known", b"only generated")
    g.file(b"nested/deeper/known", b"generated")
    g.finish()
    target = corpus_root(run, g.root.name)
    left = Generator(run, "links-" + batch, (8, 4096, 65536))
    right = Generator(run, "link-holder-" + batch, (8, 4096, 65536))
    left.file(b"original", b"generated shared object")
    os.link(left.root / "original", right.root / "outside")
    right.record(b"outside", "regular", len(b"generated shared object"))
    left.finish(); right.finish()
    results = {}

    def run_case(label: str, lane: str, root: Path, extras: list[str], partial: bool) -> dict:
        session = batch + "-" + label + "-" + lane
        result = collect(command(root, lane, session, ["--summary-only", *extras]), session,
                         evidence / (session + ".stderr"), timeout=15)
        put(evidence / (session + ".json"), result)
        if partial != (result["returncode"] == 2 and not result["summary"]["complete"]):
            raise ValueError("Incorrect complete/partial disposition: " + label)
        if not partial and (result["returncode"] != 0 or not result["summary"]["complete"]):
            raise ValueError("Unexpected incomplete control: " + label)
        results[session] = result
        return result

    for lane in ["foundation", "bulk", "rust"]:
        run_case("cancel-before-open", lane, target, ["--cancel-after", "0"], True)
        run_case("cancel-after-one", lane, target, ["--cancel-after", "1"], True)
        run_case("depth-limit", lane, target, ["--maximum-depth", "0"], True)
        run_case("queue-limit", lane, target, ["--maximum-queue", "1"], True)
        (target / "denied").chmod(0)
        try: run_case("denied", lane, target, [], True)
        finally: (target / "denied").chmod(0o700)
        outside = run_case("outside-link", lane, left.root, [], False)
        if outside["summary"].get("outside_link_objects") != "1":
            raise ValueError("Link outside selected root was hidden")
        # No regular-file read permission is needed by any scanner lane.
        (target / "zero").chmod(0)
        try: run_case("unreadable-body", lane, target, [], False)
        finally: (target / "zero").chmod(0o600)

    # Admission must reject broader roots before any enumeration/header.
    refusals = []
    for lane in ["bulk", "rust"]:
        for invalid in [run / "fixtures", target / "nested", Path("/")]:
            argv = command(target, lane, batch)
            argv[argv.index("--root") + 1] = str(invalid)
            child = subprocess.run(argv, capture_output=True, timeout=5)
            if child.returncode != 64 or child.stdout:
                raise ValueError("Broader root reached scanner")
            refusals.append(dict(lane=lane, refused=True, stdout_bytes=len(child.stdout)))
        argv = command(target, lane, batch)
        argv[argv.index("--expected-ino") + 1] = "1"
        child = subprocess.run(argv, capture_output=True, timeout=5)
        frames = [json.loads(line) for line in child.stdout.splitlines()]
        summaries = [row for row in frames if row.get("kind") == "summary"]
        if (child.returncode != 2 or len(summaries) != 1 or summaries[0]["complete"]
                or summaries[0]["entries"] != "0" or any(row.get("kind") == "entry" for row in frames)):
            raise ValueError("Wrong original identity was admitted")
        results[lane + "-wrong-identity"] = dict(returncode=child.returncode, frames=frames)

    # Repeat processes expose per-job peak/drain resources; this does not claim
    # reusable in-process sessions or an app-level stale-generation test.
    repeat = []
    for index in range(20):
        for lane in ["bulk", "rust"]:
            result = run_case("repeat-" + str(index), lane, target,
                              ["--cancel-after", "1"] if index % 2 else [], bool(index % 2))
            if int(result["summary"]["peak_owned_fds"]) > 64:
                raise ValueError("Descriptor ceiling breached")
            repeat.append(dict(index=index, lane=lane, wall_ns=result["wall_ns"],
                               peak_rss=result["wait4"]["peak_rss_bytes"],
                               descriptors=result["summary"]["peak_owned_fds"]))
    report = dict(schema=1, passed=True, native_cases=len(results), refusal_cases=refusals,
                  results=results, repeat=repeat, budget=budget(),
                  unexercised=["real provider/cloud/disconnection", "in-process reusable session growth",
                               "kernel-wide body trace", "two-worker scheduling", "private/compression/snapshot accounting"])
    put(evidence / "summary.json", report)
    print(json.dumps(dict(evidence=str(evidence), passed=True, native_cases=len(results), refusals=len(refusals))))


if __name__ == "__main__": main()
