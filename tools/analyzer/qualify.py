#!/usr/bin/env python3
"""Independent bounded protocol consumer for generated Batch06 fixtures."""
from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid
import re

sys.dont_write_bytecode = True
from packet import REPO, admit, budget, corpus_root, create_file, identity, oracle, put, read_owned

FIELDS = ["data_logical", "all_logical", "data_allocated", "all_allocated"]
MASKS = ["common", "volume", "directory", "file", "fork"]
SWIFT = REPO / ".build/b06-analyzer/tool-build/b06-swift-scanner"
RUST = REPO / ".build/b06-toolchain/build/b06-rust-scanner"


def command(root: Path, lane: str, session: str, extra: list[str] | None = None,
            expected_identity: tuple[int, int] | None = None) -> list[str]:
    dev, ino = expected_identity if expected_identity is not None else identity(root)
    return [str(RUST if lane == "rust" else SWIFT), "--lane", lane, "--root", str(root),
            "--expected-dev", str(dev), "--expected-ino", str(ino), "--session", session] + (extra or [])


def canonical(row: dict) -> bytes:
    values = ["b06-record-v1", row["relative_b64"], row["name_b64"], row["type"]]
    values += [row[key] if row[key] is not None else "-" for key in ["dev", "ino", "nlink", "flags"]]
    values += [",".join(row["returned"][key] for key in MASKS), str(row["errno"])]
    values += [",".join(row[key].get("value", "-") for key in FIELDS)]
    return ("\n".join(values) + "\n").encode()


def independent_sizes(root: Path, expected: dict) -> dict:
    """Separate Python/ctypes getattrlist oracle; not either packed parser.

    Only the small accounting corpus uses this outside timing. Unlike bulk,
    getattrlist has no per-record name reference or multi-record alignment.
    """
    import struct
    class Attributes(ctypes.Structure):
        _fields_ = [("count", ctypes.c_uint16), ("reserved", ctypes.c_uint16)] + [
            (name, ctypes.c_uint32) for name in MASKS]
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.getattrlist
    function.argtypes = [ctypes.c_char_p, ctypes.POINTER(Attributes), ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    function.restype = ctypes.c_int
    result = {}
    for key, edge in expected.items():
        if edge["type"] != "regular": continue
        request = Attributes(5, 0, 0xA0000000, 0, 0, 0x606, 0)
        output = ctypes.create_string_buffer(4096)
        path = os.fsencode(root) + b"/" + base64.b64decode(key, validate=True)
        if function(path, ctypes.byref(request), output, len(output), 0x801) != 0:
            raise OSError(ctypes.get_errno(), "Independent generated size observation failed")
        raw = output.raw
        length, common, volume, directory, returned_file, fork = struct.unpack_from("<6I", raw)
        if not 24 <= length <= len(raw) or common & 0x80000000 == 0:
            raise ValueError("Invalid independent size observation")
        offset = 24
        if common & 0x20000000:
            error, = struct.unpack_from("<I", raw, offset); offset += 4
            if error: raise OSError(error, "Independent metadata error")
        sizes = {}
        for bit, name in [(2, "all_logical"), (4, "all_allocated"), (0x200, "data_logical"), (0x400, "data_allocated")]:
            if returned_file & bit:
                if offset + 8 > length: raise ValueError("Truncated independent size")
                value, = struct.unpack_from("<q", raw, offset); offset += 8
                if value < 0: raise ValueError("Negative independent size")
                sizes[name] = {"state": "returned", "value": str(value)}
            else: sizes[name] = {"state": "not_returned"}
        result[key] = sizes
    return result


class Consumer:
    def __init__(self, expected: dict | None = None, sizes: dict | None = None):
        self.expected = expected
        self.sizes = sizes or {}
        self.seen: set[str] = set()
        self.xor = self.sum = 0
        self.count = 0
        self.totals = dict.fromkeys(FIELDS, 0)
        self.object_totals = dict.fromkeys(FIELDS, 0)
        self.missing = dict.fromkeys(FIELDS, 0)
        self.types = dict.fromkeys(["regular", "directory", "symlink", "other", "unknown"], 0)
        self.objects: dict[tuple[str, str], dict] = {}
        self.unknown_identity = self.partial = False

    @staticmethod
    def unsigned(value: object, maximum: int = (1 << 64) - 1) -> int:
        if not isinstance(value, str) or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
            raise ValueError("Noncanonical unsigned decimal")
        result = int(value)
        if result > maximum: raise ValueError("Unsigned value overflow")
        return result

    def accept(self, row: dict) -> None:
        key = row["relative_b64"]
        raw = base64.b64decode(key, validate=True)
        if base64.b64encode(raw).decode() != key:
            raise ValueError("Noncanonical base64 edge")
        if len(raw) > 8192 or any(part in (b"", b".", b"..") for part in raw.split(b"/")) or b"\0" in raw:
            raise ValueError("Unsafe canonical entry edge")
        if base64.b64decode(row["name_b64"], validate=True) != raw.split(b"/")[-1]:
            raise ValueError("Mismatched entry name")
        if base64.b64decode(row["parent_b64"], validate=True) != raw.rpartition(b"/")[0]:
            raise ValueError("Mismatched entry parent")
        if key in self.seen:
            raise ValueError("Repeated scanner edge")
        self.seen.add(key)
        if row["type"] not in self.types: raise ValueError("Unknown entry type")
        if type(row["errno"]) is not int or not 0 <= row["errno"] <= (1 << 31) - 1:
            raise ValueError("Invalid entry error")
        for field in ["dev", "ino", "nlink", "flags"]:
            if row[field] is not None: self.unsigned(row[field])
        if set(row["returned"]) != set(MASKS): raise ValueError("Invalid returned masks")
        for value in row["returned"].values(): self.unsigned(value, (1 << 32) - 1)
        if self.expected is not None:
            expected = self.expected.get(key)
            if expected is None or any(row[k] != expected[k] for k in ["relative_b64", "type", "dev", "ino"]):
                raise ValueError("Scanner disagrees with independent manifest edge")
            if row["type"] == "regular" and row["data_logical"] != {"state": "returned", "value": expected["data_logical"]}:
                raise ValueError("Scanner data-fork length disagrees with generator")
        for field in FIELDS:
            value = row[field]
            if key in self.sizes and value != self.sizes[key][field]:
                raise ValueError("Scanner disagrees with independent all/data-fork size observation")
            if not isinstance(value, dict) or value.get("state") not in ("returned", "not_returned", "error"):
                raise ValueError("Unknown size support state")
            if value["state"] == "returned":
                if set(value) != {"state", "value"}: raise ValueError("Invalid returned field shape")
                self.unsigned(value["value"], (1 << 63) - 1)
            elif set(value) != {"state"}: raise ValueError("Invalid absent field shape")
        digest = int.from_bytes(hashlib.sha256(canonical(row)).digest(), "big")
        self.xor ^= digest
        self.sum = (self.sum + digest) % (1 << 256)
        self.count += 1
        if self.count > 220_000: raise ValueError("Entry ceiling exceeded")
        self.types[row["type"]] += 1
        if row["errno"] or row["type"] == "unknown" or any(row[k] is None for k in ["dev", "ino", "nlink", "flags"]):
            self.partial = True
        if row["type"] == "regular":
            values = tuple(int(row[field]["value"]) if row[field]["state"] == "returned" and not row["errno"] else None for field in FIELDS)
            for field, value in zip(FIELDS, values):
                if value is None:
                    self.missing[field] += 1; self.partial = True
                else: self.totals[field] += value
            if row["dev"] is None or row["ino"] is None:
                self.unknown_identity = True
            else:
                object_key = (row["dev"], row["ino"])
                previous = self.objects.get(object_key)
                links = int(row["nlink"]) if row["nlink"] is not None else None
                if previous is None:
                    self.objects[object_key] = dict(values=values, links=links, edges=1)
                    for field, value in zip(FIELDS, values):
                        if value is not None: self.object_totals[field] += value
                else:
                    previous["edges"] += 1
                    if previous["values"] != values or previous["links"] != links or (links is not None and previous["edges"] > links):
                        self.partial = True

    def finish(self, summary: dict) -> None:
        if self.expected is not None and self.seen != self.expected.keys():
            raise ValueError("Missing scanner manifest edges")
        if (self.unsigned(summary["entries"]) != self.count or self.unsigned(summary["digest_count"]) != self.count or summary["digest_xor"] != f"{self.xor:064x}"
                or summary["digest_sum"] != f"{self.sum:064x}"):
            raise ValueError("Independent streamed digest mismatch")
        if self.unsigned(summary["objects"]) != len(self.objects): raise ValueError("Independent object count mismatch")
        for key, expected in [("entry_totals", self.totals), ("object_totals", self.object_totals), ("missing_fields", self.missing)]:
            if set(summary[key]) != set(FIELDS) or any(self.unsigned(summary[key][field]) != expected[field] for field in FIELDS):
                raise ValueError("Independent " + key + " mismatch")
        for kind in ["regular", "directory", "symlink", "other"]:
            expected = self.types[kind] + (self.types["unknown"] if kind == "other" else 0)
            if self.unsigned(summary[kind + "_entries"]) != expected: raise ValueError("Independent entry type count mismatch")
        outside = sum(o["links"] is not None and o["links"] > o["edges"] for o in self.objects.values())
        if self.unsigned(summary["outside_link_objects"]) != outside: raise ValueError("Independent outside-link count mismatch")
        expected_state = "unknown" if self.unknown_identity else "returned" if summary["complete"] else "partial"
        if summary["object_accounting_state"] != expected_state or (summary["complete"] and self.partial):
            raise ValueError("Invalid complete/object accounting state")


def stop_child(child: subprocess.Popen) -> None:
    """Only this admitted child; never use Popen.poll before the owning wait4."""
    if child.returncode is not None: return
    try: os.kill(child.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        try: pid, status, _ = os.wait4(child.pid, os.WNOHANG)
        except ChildProcessError:
            # A caller may already have reaped it. Do not mask the first failure.
            return
        if pid:
            child.returncode = os.waitstatus_to_exitcode(status); return
        time.sleep(0.01)
    try: os.kill(child.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    try:
        _, status, _ = os.wait4(child.pid, 0)
        child.returncode = os.waitstatus_to_exitcode(status)
    except ChildProcessError: pass


def collect(argv: list[str], session: str, stderr: Path, consumer: Consumer | None = None,
            timeout: float = 30, env: dict | None = None) -> dict:
    """Bounded protocol state machine; failures retain a small rejection receipt."""
    started = time.monotonic_ns()
    frames = []; buffer = bytearray(); peak_buffer = 0
    first_feedback = first_progress = summary_at = None
    state = "header"; summary = None; child = None; frame_count = entry_count = issues = 0
    try:
        with create_file(stderr) as errors:
            child = subprocess.Popen(argv, cwd=REPO, stdout=subprocess.PIPE, stderr=errors, env=env)
            selector = selectors.DefaultSelector()
            try:
                descriptor = child.stdout.fileno()
                os.set_blocking(descriptor, False)
                selector.register(descriptor, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic_ns() - started > timeout * 1e9:
                        raise TimeoutError("Generated scanner exceeded fixed deadline")
                    for _, _ in selector.select(0.05):
                        part = os.read(descriptor, 65536)
                        if not part:
                            selector.unregister(descriptor); break
                        buffer.extend(part); peak_buffer = max(peak_buffer, len(buffer))
                        while b"\n" in buffer:
                            line, _, rest = buffer.partition(b"\n"); buffer = bytearray(rest)
                            if len(line) + 1 > 65536: raise ValueError("Oversized scanner frame")
                            row = json.loads(line)
                            if not isinstance(row, dict) or type(row.get("schema")) is not int or row.get("schema") != 1 or row.get("session") != session:
                                raise ValueError("Stale or unknown scanner protocol")
                            frame_count += 1
                            kind = row.get("kind")
                            if kind not in ("header", "entry", "progress", "issue", "summary"):
                                raise ValueError("Unknown scanner frame kind")
                            if state == "terminal": raise ValueError("Scanner frame after terminal summary")
                            if state == "header":
                                if kind != "header": raise ValueError("Scanner omitted initial header")
                                state = "body"
                            elif kind == "header": raise ValueError("Repeated scanner header")
                            now = time.monotonic_ns() - started
                            if first_feedback is None: first_feedback = now
                            if kind == "entry":
                                entry_count += 1
                                if entry_count > 220_000: raise ValueError("Unbounded entry output")
                                if consumer is not None: consumer.accept(row)
                            else:
                                if kind == "issue":
                                    issues += 1
                                    if issues > 100: raise ValueError("Unbounded issue output")
                                if kind == "progress":
                                    if first_progress is not None: raise ValueError("Repeated first-progress frame")
                                    first_progress = now
                                if kind == "summary":
                                    if type(row.get("complete")) is not bool: raise ValueError("Invalid completion state")
                                    summary = row; summary_at = now; state = "terminal"
                                frames.append(row)
                                if len(frames) > 104: raise ValueError("Unbounded diagnostic output")
                        if len(buffer) > 65536: raise ValueError("Unterminated oversized scanner frame")
                if buffer: raise ValueError("Truncated scanner output")
                if state != "terminal": raise ValueError("Scanner omitted terminal summary")
                while True:
                    pid, status, usage = os.wait4(child.pid, os.WNOHANG)
                    if pid: break
                    if time.monotonic_ns() - started > timeout * 1e9:
                        raise TimeoutError("Scanner worker failed to drain")
                    time.sleep(0.005)
                child.returncode = os.waitstatus_to_exitcode(status)
            except BaseException as error:
                try: stop_child(child)
                except BaseException as cleanup:
                    if hasattr(error, "add_note"): error.add_note("Child cleanup failed: " + type(cleanup).__name__)
                raise
            finally:
                child.stdout.close(); selector.close()
        if consumer is not None: consumer.finish(summary)
        return dict(returncode=child.returncode, frames=frames, summary=summary,
                    wall_ns=time.monotonic_ns() - started, feedback_ns=first_feedback, progress_ns=first_progress,
                    summary_ns=summary_at, consumer_peak_buffer=peak_buffer,
                    wait4=dict(user_seconds=usage.ru_utime, system_seconds=usage.ru_stime,
                               peak_rss_bytes=usage.ru_maxrss), stderr_bytes=stderr.stat().st_size)
    except BaseException as error:
        # Keep this receipt below 16 KiB even for hostile summary frames. Raw entry
        # data is never retained here, and existing evidence is never overwritten.
        saved_summary = summary if summary is not None and len(json.dumps(summary)) <= 8192 else None
        failure = dict(schema=1, complete=False, disposition="rejected", session=session[:128],
                       reason=type(error).__name__ + ": " + str(error)[:512], state=state,
                       frames_seen=frame_count, entries_seen=entry_count,
                       accepted_entries=consumer.count if consumer is not None else None,
                       last_summary=saved_summary, returncode=child.returncode if child else None,
                       wall_ns=time.monotonic_ns() - started, consumer_peak_buffer=peak_buffer)
        try: put(stderr.with_suffix(stderr.suffix + ".failure.json"), failure)
        except BaseException as receipt_error:
            if hasattr(error, "add_note"): error.add_note("Failure receipt unavailable: " + type(receipt_error).__name__)
        raise


def validate(run: Path, corpus: str, lanes: list[str]) -> dict:
    root = corpus_root(run, corpus)
    original_identity = identity(root)
    independent = oracle(run, corpus)
    expected = {row["relative_b64"]: row for row in map(json.loads,
                read_owned(run / "manifests" / (corpus + ".ndjson"), 64 << 20).splitlines())}
    sizes = independent_sizes(root, expected) if corpus.startswith("edges") else {}
    results = {}
    comparison_keys = ["entries", "regular_entries", "directory_entries", "symlink_entries", "other_entries",
                       "objects", "entry_totals", "object_totals", "missing_fields", "digest_count", "digest_sum", "digest_xor",
                       "object_accounting_state", "outside_link_objects"]
    epoch = uuid.uuid4().hex
    for lane in lanes:
        if corpus_root(run, corpus) != root or identity(root) != original_identity:
            raise ValueError("Corpus root changed between qualification lanes")
        session = "qualify-" + epoch + "-" + lane
        argv = command(root, lane, session, expected_identity=original_identity)
        binary_hash = hashlib.sha256(Path(argv[0]).read_bytes()).hexdigest()
        result = collect(argv, session,
                         run / "evidence" / (session + ".stderr"), Consumer(expected, sizes), timeout=120)
        result["binary_sha256"] = binary_hash
        if hashlib.sha256(Path(argv[0]).read_bytes()).hexdigest() != binary_hash:
            put(run / "evidence" / (session + "-binary-changed.json"), result)
            raise ValueError("Correctness executable changed while running")
        results[lane] = result
        put(run / "evidence" / (session + ".json"), result)
        if result["returncode"] or not result["summary"]["complete"]:
            raise ValueError("Correctness lane returned partial: " + lane)
        if identity(corpus_root(run, corpus)) != original_identity:
            raise ValueError("Corpus root changed during qualification lane")
    baseline = results[lanes[0]]["summary"]
    for lane in lanes[1:]:
        if any(results[lane]["summary"][key] != baseline[key] for key in comparison_keys):
            raise ValueError("Matched lane canonical/accounting mismatch: " + lane)
    # A regular-file metadata-only oracle and immutable generator are independent
    # of both packed parsers; parity alone is never treated as the only oracle.
    if (int(baseline["entries"]) != independent["entries"]
            or int(baseline["objects"]) != independent["objects"]
            or int(baseline["entry_totals"]["data_logical"]) != independent["data_logical"]
            or int(baseline["object_totals"]["data_logical"]) != independent["object_data_logical"]):
        raise ValueError("Independent observation mismatch")
    return dict(schema=1, corpus=corpus, oracle=independent, independent_size_edges=len(sizes),
                lanes=results, budget=budget(), complete=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--lanes", default="foundation,bulk,rust")
    args = parser.parse_args()
    run = admit(args.run)
    corpus_root(run, args.corpus)
    lanes = args.lanes.split(",")
    if not lanes or any(lane not in ("foundation", "bulk", "rust") for lane in lanes):
        parser.error("unknown lane")
    receipt = run / "evidence" / ("correctness-" + args.corpus + "-" + uuid.uuid4().hex + ".json")
    result = validate(run, args.corpus, lanes)
    put(receipt, result)
    print(json.dumps(dict(receipt=str(receipt), complete=True, entries=result["oracle"]["entries"],
                          lanes=lanes, budget=result["budget"])), flush=True)


if __name__ == "__main__":
    main()
