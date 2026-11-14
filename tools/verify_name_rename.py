#!/usr/bin/env python3
"""Isolated native Rename crash, old-reader and optional size qualification."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Packages/ExplorerKit/Sources/FileOperations"
CATALOG_V2_BASELINE = "9aa4b16cb05c6d4a0635e8727473aac39961ecee"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", action="store_true", help="Also compare optimized old/new engine size profiles")
    parser.add_argument("--baseline-ref", default=CATALOG_V2_BASELINE,
                        help="Catalog-v2 source commit (defaults to the pinned qualified pre-upgrade commit)")
    args = parser.parse_args()
    run = ROOT / ".build/name-rename-qualification" / str(uuid.uuid4())
    if run.parent.resolve() != run.parent:
        raise RuntimeError("Qualification root must not contain symlinks")
    run.mkdir(parents=True)
    for part in ["modules", "tmp", "current", "baseline", "harness"]:
        (run / part).mkdir()
    base = ROOT / ".build/test-fixtures"
    base.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(run / "tmp")
    env["CLANG_MODULE_CACHE_PATH"] = str(run / "modules")
    baseline = subprocess.check_output(["git", "rev-parse", "--verify", f"{args.baseline_ref}^{{commit}}"], cwd=ROOT, text=True).strip()
    harness_hashes: dict[str, str] = {}
    for name in ["verify_name_rename.py", "NameRenameQualificationWorker.swift", "RenameCompatibilityProfileWorker.swift"]:
        data = (ROOT / "tools" / name).read_bytes()
        (run / "harness" / name).write_bytes(data)
        harness_hashes[name] = hashlib.sha256(data).hexdigest()
    manifests: dict[str, dict[str, str]] = {"current": {}, "baseline": {}}
    for source in sorted(SOURCES.glob("*.swift")):
        data = source.read_bytes()
        (run / "current" / source.name).write_bytes(data)
        manifests["current"][source.name] = hashlib.sha256(data).hexdigest()
    old_files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", baseline, "Packages/ExplorerKit/Sources/FileOperations"], cwd=ROOT, text=True).splitlines()
    for name in old_files:
        if not name.endswith(".swift"):
            continue
        data = subprocess.check_output(["git", "show", f"{baseline}:{name}"], cwd=ROOT)
        (run / "baseline" / Path(name).name).write_bytes(data)
        manifests["baseline"][Path(name).name] = hashlib.sha256(data).hexdigest()
    report: dict = {"passed": False, "baselineRef": args.baseline_ref, "baselineCommit": baseline, "sourceHashes": manifests, "cases": [],
                    "harnessHashes": harness_hashes, "harnessSnapshot": "harness",
                    "builds": {},
                    "limits": ["Process interruption, not power loss", "Current case-insensitive APFS only", "No owner journal migration", "No remount, reboot, actual inode reuse or snapshot restore", "Profile caches and concurrent desktop activity uncontrolled"]}

    def compile_worker(label: str, snapshot: str, worker: str) -> Path:
        binary = run / label
        # Keep the original source path for the worker's repository-local fixture
        # boundary (#filePath), while retaining and verifying its exact source bytes.
        if hashlib.sha256((ROOT / "tools" / worker).read_bytes()).hexdigest() != harness_hashes[worker]:
            raise RuntimeError("Qualification harness changed before compilation")
        command = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library", "-j", "2", "-num-threads", "2",
                   "-module-cache-path", str(run / "modules"), "-o", str(binary),
                   *[str(p) for p in sorted((run / snapshot).glob("*.swift"))], str(ROOT / "tools" / worker)]
        with (run / f"{label}-build.log").open("w") as output:
            subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=300)
        if hashlib.sha256((ROOT / "tools" / worker).read_bytes()).hexdigest() != harness_hashes[worker]:
            raise RuntimeError("Qualification harness changed during compilation")
        report["builds"][label] = {"command": command, "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                                    "sourceSnapshot": snapshot, "log": f"{label}-build.log"}
        return binary

    def invoke(binary: Path, phase: str, root: Path, boundary: str | None = None, expected: int = 0) -> dict:
        command = [str(binary), phase, str(root)] + ([] if boundary is None else [boundary])
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
        (run / f"{root.name}-{phase}.log").write_text(result.stdout + result.stderr)
        if result.returncode != expected:
            raise RuntimeError(f"{phase}/{boundary} exit {result.returncode}: {root.name}")
        return json.loads(result.stdout)

    try:
        worker = compile_worker("current-crash-worker", "current", "NameRenameQualificationWorker.swift")
        old_worker = compile_worker("baseline-worker", "baseline", "RenameCompatibilityProfileWorker.swift")
        for direction, boundaries in [("forward", ["prepared", "intent", "syscall", "sync", "applied", "committed"]),
                                      ("reverse", ["intent", "syscall", "sync", "applied", "committed"])]:
            for boundary in boundaries:
                root = base / ("name-rename-" + str(uuid.uuid4()))
                stopped = invoke(worker, direction, root, boundary, expected=86)
                inspected = invoke(worker, "inspect", root, boundary)
                recovered = invoke(worker, "recover", root, boundary)
                if len({stopped["pid"], inspected["pid"], recovered["pid"]}) != 3 or recovered["state"] != "undone" or recovered["storedName"] != "Case.txt" or inspected["recordID"] != recovered["recordID"]:
                    raise RuntimeError("Fresh-process recovery invariant failed")
                report["cases"].append({"direction": direction, "boundary": boundary, "fixture": str(root.relative_to(ROOT)),
                                        "stopped": stopped, "inspected": inspected, "recovered": recovered})
        compatibility = base / ("name-rename-" + str(uuid.uuid4()))
        invoke(worker, "complete", compatibility, "none")
        report["oldReader"] = invoke(old_worker, "old-reader", compatibility)
        report["oldReaderFixture"] = str(compatibility.relative_to(ROOT))
        migration = base / ("name-rename-" + str(uuid.uuid4()))
        seeded = invoke(old_worker, "legacy-seed", migration)
        migrated = invoke(worker, "legacy-migrate", migration, "none")
        if seeded["recordHash"] != migrated["recordHash"] or seeded["recordID"] != migrated["recordID"]:
            raise RuntimeError("Catalog upgrade changed a real baseline legacy record")
        report["legacyMigration"] = {"fixture": str(migration.relative_to(ROOT)), "seeded": seeded,
                                     "migrated": migrated, "oldReader": invoke(old_worker, "old-reader", migration)}
        if args.profile:
            current_profile = compile_worker("current-profile-worker", "current", "RenameCompatibilityProfileWorker.swift")
            report["profiles"] = {}
            for label, binary in [("baseline", old_worker), ("current", current_profile)]:
                root = base / ("name-rename-" + str(uuid.uuid4()))
                profile = invoke(binary, "profile", root)
                profile["fixture"] = str(root.relative_to(ROOT))
                profile["mediansSeconds"] = {case: statistics.median(row["seconds"] for row in profile["rows"] if row["case"] == case)
                                            for case in sorted({row["case"] for row in profile["rows"]})}
                report["profiles"][label] = profile
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["failure"] = str(error)
    receipt = run / "receipt.json"
    receipt.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passed": report["passed"], "receipt": str(receipt), "cases": len(report["cases"]), "failure": report.get("failure")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
