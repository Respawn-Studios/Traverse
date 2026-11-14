#!/usr/bin/env python3
"""Remaining native DFS guard controls, one tiny explicit generated root."""
from __future__ import annotations
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import traversal
from traversal import REPO, SOURCE, RUSTC, TOOL_ROOT, EVIDENCE, sha, refinement_budget
from packet import BASE, directory_fd


def refusal(binary, root, regular=False):
    fd = os.open(root / "nested/known", os.O_RDONLY | os.O_NOFOLLOW) if regular else directory_fd(root)
    value = os.fstat(fd); original = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 10); os.close(fd)
    out, err = os.pipe(), os.pipe()
    argv = [str(binary), "--root-fd", "3", "--session", str(uuid.uuid4()), "--expected-dev", str(value.st_dev),
            "--expected-ino", str(value.st_ino if regular else value.st_ino + 1)]
    pid = os.posix_spawn(str(binary), argv, {"LANG": "C"}, file_actions=[
        (os.POSIX_SPAWN_DUP2, original, 3), (os.POSIX_SPAWN_DUP2, out[1], 1), (os.POSIX_SPAWN_DUP2, err[1], 2)])
    for d in (original, out[1], err[1]): os.close(d)
    counts = [0, 0]; status = None; began = time.monotonic()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(out[0], selectors.EVENT_READ, 0); selector.register(err[0], selectors.EVENT_READ, 1)
            while selector.get_map() or status is None:
                got, value = os.waitpid(pid, os.WNOHANG) if status is None else (0, 0)
                if got: status = value
                if time.monotonic() - began > 5: raise TimeoutError("refusal drain deadline")
                for key, _ in selector.select(.01):
                    data = os.read(key.fd, 4096)
                    if not data: selector.unregister(key.fd); continue
                    counts[key.data] += len(data)
                    if max(counts) > 4096: raise ValueError("bounded refusal output")
        # Root refusal happens before the header. The qualified worker returns
        # code 2 quietly, rather than manufacturing an issue without a session.
        if os.waitstatus_to_exitcode(status) != 2 or counts[0] != 0 or counts[1] != 0:
            raise ValueError("invalid root was admitted")
        return {"passed": True, "actual_exit_observed": True, "stdout_bytes": counts[0], "fixed_stderr_bytes": counts[1]}
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
        os.close(out[0]); os.close(err[0])


def main():
    before = refinement_budget.inspect()
    if not before["passed"] or before["combined"]["entries"] + 6 > before["limits"]["entries"] or before["original_allowance_charge"]["logical"] + 4096 > 1 << 30:
        raise ValueError("six-entry native failure projection refused")
    prior = json.loads((EVIDENCE / "traversal-fdd17e4e26ab416c9160c2d102db2fb7.json").read_text())
    binary = REPO / prior["tool_output"] / "dfs64-256k"
    if sha(binary) != prior["binaries"]["dfs64-256k"]: raise ValueError("qualified candidate changed")
    output = TOOL_ROOT / ("dfs-failures-" + uuid.uuid4().hex); output.mkdir(mode=0o700)
    record = {"schema": 1, "complete": False, "before": before, "candidate_sha256": sha(binary),
              "source": {str(p.relative_to(REPO)): sha(p) for p in [HERE / "FailureControls.rs", Path(__file__)]},
              "controls": [], "scope": "Generated native directory/root replacement, denial and invalid descriptor/identity controls. No ordinary routing."}
    failure = None
    try:
        root = BASE / ("dfs-failure-" + uuid.uuid4().hex); root.mkdir(mode=0o700)
        nested = root / "nested"; nested.mkdir(mode=0o700)
        fd = os.open(nested / "known", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as target: target.write(b"generated-dfs-control")
        record["root"] = str(root.relative_to(REPO))
        record["controls"].append({"case": "wrong-identity", **refusal(binary, root)})
        record["controls"].append({"case": "regular-file-descriptor", **refusal(binary, root, regular=True)})
        os.chmod(nested, 0)
        try:
            value = traversal.collect(binary, root)
            if value["summary"]["complete"] or "directory_open" not in value["issues"]: raise ValueError("native denial hidden")
            record["controls"].append({"case": "denied-directory", **traversal.small(value)})
        finally: os.chmod(nested, 0o700)
        (output / "main.rs").write_text(traversal.derive(64, 256 << 10) + "\n" + (HERE / "FailureControls.rs").read_text())
        for name in ("policy.rs", "policy-vectors.tsv"): (output / name).write_bytes((SOURCE / name).read_bytes())
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        native = REPO / prior["tool_output"] / "ScannerNative.o"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "RUST", "CARGO", "B06_", "AUDIT_"))}
        env.update(TMPDIR=str(output), B06_DFS_GENERATED_ROOT=str(root))
        args = [str(RUSTC), "--edition=2024", "--test", "-C", "opt-level=3", "-C", "lto=thin", "-C", "codegen-units=1",
                "--target=aarch64-apple-darwin", "-C", "link-arg=-isysroot", "-C", "link-arg=" + sdk,
                "-C", "link-arg=" + str(native), str(output / "main.rs"), "-o", str(output / "controls")]
        result = subprocess.run(args, env=env, capture_output=True, timeout=60)
        (output / "build.txt").write_bytes(result.stdout + result.stderr)
        if result.returncode or result.stderr: raise ValueError("native failure control build")
        result = subprocess.run([str(output / "controls")], env=env, capture_output=True, timeout=10)
        (output / "controls.txt").write_bytes(result.stdout + result.stderr)
        if result.returncode or result.stderr: raise ValueError("native replacement/retained frame control")
        record["controls"].append({"case": "six-rust-controls-including-native-replacement", "passed": True, "output": result.stdout.decode()[-2048:]})
        record["complete"] = True
    except BaseException as error:
        failure = error; record["failure"] = type(error).__name__ + ":" + str(error)[:256]
    record["after"] = refinement_budget.inspect()
    data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > 65536: raise ValueError("bounded guard evidence")
    receipt = EVIDENCE / ("dfs-failures-" + uuid.uuid4().hex + ".json")
    with receipt.open("xb") as target: target.write(data)
    print(json.dumps({"complete": record["complete"], "failure": record.get("failure"), "receipt": str(receipt.relative_to(REPO))}))
    if failure: raise SystemExit(2)


if __name__ == "__main__": main()
