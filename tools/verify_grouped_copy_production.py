#!/usr/bin/env python3
"""Fresh-process real production grouped Copy qualification.

The root verification lane executes this runner after the engine/checkpoint API
freeze. Retain every generated fixture, source/binary hash and failed receipt.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Packages/ExplorerKit/Sources/FileOperations"
WORKER = "GroupedCopyProductionWorker.swift"
API_FROZEN = True


def matrix_plan() -> list[dict]:
    """Actual frozen production checkpoint names; outcomes commit per group."""
    cases = [{"kind": "happy", "count": count, "metadataPolicy": policy}
             for count in (1, 16, 17, 31, 33) for policy in ("strict", "destinationOwnership")]
    # Every member of the33-job participates; do not test only first/last members.
    for member in range(33):
        for boundary in ("memberWillStage", "memberStaged", "memberWillPublish", "memberPublished", "memberSynced"):
            for mechanism in ("cooperative_stop", "injected_error", "process_crash"):
                cases.append({"kind": "member_boundary", "count": 33, "member": member, "group": member // 16,
                              "boundary": boundary, "mechanism": mechanism, "metadataPolicy": "strict"})
    for group in range(3):
        for boundary in ("groupWillDeclare", "groupDeclared", "groupCreated", "groupWillSeal", "groupSealed", "groupWillRecordOutcomes", "groupOutcomesRecorded"):
            mechanisms = ("cooperative_stop", "injected_error", "process_crash")
            if boundary in ("groupWillDeclare", "groupWillSeal", "groupWillRecordOutcomes"):
                mechanisms += ("lost_acknowledgement",)
            for mechanism in mechanisms:
                cases.append({"kind": "group_boundary", "count": 33, "group": group,
                              "boundary": boundary, "mechanism": mechanism, "metadataPolicy": "strict"})
    for boundary in ("manifestWillCommit", "manifestCommitted", "terminalWillCommit", "terminalCommitted"):
        mechanisms = ("cooperative_stop", "injected_error", "process_crash")
        if boundary in ("manifestWillCommit", "terminalWillCommit"):
            mechanisms += ("lost_acknowledgement",)
        for mechanism in mechanisms:
            cases.append({"kind": "global_boundary", "count": 33, "boundary": boundary,
                          "mechanism": mechanism, "metadataPolicy": "strict"})
    cases.append({"kind": "storage_full", "count": 33, "mechanism": "sqlite_full", "maximumPages": 32,
                  "metadataPolicy": "strict"})
    cases += [{"kind": "admission", "count": 1, "variant": variant} for variant in ("folder", "symlink", "hardlink", "conflict", "duplicate")]
    return cases


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def directory(path: Path, private: bool = True) -> None:
    if not path.is_absolute() or path.resolve() != path:
        raise RuntimeError("Qualification directory contains a symlink component")
    value = path.lstat()
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or value.st_mode & (0o077 if private else 0o022):
        raise RuntimeError("Unsafe qualification directory")


def create_directory(path: Path) -> None:
    directory(path.parent, private=False)
    path.mkdir(mode=0o700)
    directory(path)


def write(path: Path, data: bytes) -> None:
    directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


class Qualification:
    def __init__(self) -> None:
        directory(ROOT, private=False)
        directory(ROOT / ".build", private=False)
        base = ROOT / ".build/grouped-copy-production"
        if not os.path.lexists(base):
            create_directory(base)
        directory(base)
        self.run = base / str(uuid.uuid4())
        create_directory(self.run)
        write(self.run / ".qualification-owner",
              f"MacExplorer grouped production qualification v1\n{self.run.name}\n".encode())
        for name in ("fixtures", "harness", "sources", "modules", "clang-modules", "tmp", "logs"):
            create_directory(self.run / name)
        self.env = os.environ.copy()
        self.env.update({"TMPDIR": str(self.run / "tmp"), "CLANG_MODULE_CACHE_PATH": str(self.run / "clang-modules"),
                         "MAC_EXPLORER_GROUPED_PRODUCTION_RUN_ROOT": str(self.run)})
        self.frozen: dict[Path, str] = {}
        self.sequence = 0
        self.report: dict = {"passed": False, "productionExecutionQualified": False,
                             "sourceHashes": {}, "harnessHashes": {}, "commands": [], "cases": [],
                             "unexercised": [],
                             "scope": ["Generated repository fixtures; real production engine only",
                                       "Separate cold inspection processes; no automatic recovery actions",
                                       "Process crashes/injected errors/Stop/lost acknowledgements distinct",
                                       "SQLiteFULL requires actual SQLite result, not an injected error",
                                       "No hardware power-loss, surprise removal or App routing claim"]}
        self.binary = self.run / "production-worker"

    def check_frozen(self) -> None:
        for path, expected in self.frozen.items():
            value = path.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_uid != os.geteuid() or value.st_nlink != 1 or digest(path.read_bytes()) != expected:
                raise RuntimeError("Frozen qualification source or binary changed")

    def snapshot(self) -> None:
        for source in sorted(SOURCES.glob("*.swift")):
            value = source.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size > 4_194_304:
                raise RuntimeError("Unsafe production source")
            data = source.read_bytes()
            target = self.run / "sources" / source.name
            write(target, data)
            self.frozen[target] = self.report["sourceHashes"][source.name] = digest(data)
        for name in (WORKER, Path(__file__).name):
            source = ROOT / "tools" / name
            value = source.lstat()
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size > 1_048_576:
                raise RuntimeError("Unsafe harness source")
            data = source.read_bytes()
            target = self.run / "harness" / name
            write(target, data)
            self.frozen[target] = self.report["harnessHashes"][name] = digest(data)
        write(self.run / "semantic-plan.json", json.dumps(matrix_plan(), indent=2, sort_keys=True).encode())

    def command(self, argv: list[str], label: str, expected: int = 0, timeout: int = 120) -> bytes:
        self.check_frozen()
        self.sequence += 1
        start = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True, timeout=timeout, check=False)
            status, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            status, stdout, stderr = "timeout", error.stdout or b"", error.stderr or b""
        receipt = {"argv": argv, "expectedExit": expected, "exit": status, "seconds": time.monotonic() - start,
                   "log": f"logs/{self.sequence:04d}-{label}.json"}
        self.report["commands"].append(receipt)
        write(self.run / receipt["log"], json.dumps({**receipt, "stdout": stdout.decode("utf-8", "replace"),
            "stderr": stderr.decode("utf-8", "replace")}, indent=2).encode())
        if status != expected:
            raise RuntimeError(f"Qualification command failed: {label} (exit {status})")
        self.check_frozen()
        return stdout

    def compile(self) -> None:
        argv = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                "-j", "2", "-num-threads", "2", "-module-cache-path", str(self.run / "modules"),
                "-o", str(self.binary), *[str(path) for path in sorted((self.run / "sources").glob("*.swift"))],
                str(self.run / "harness" / WORKER)]
        self.command(argv, "compile", timeout=600)
        self.frozen[self.binary] = self.report["binarySHA256"] = digest(self.binary.read_bytes())

    def invoke(self, phase: str, fixture: Path, *arguments: str, expected: int = 0) -> dict:
        value = json.loads(self.command([str(self.binary), phase, str(fixture), *arguments], phase, expected=expected))
        if not isinstance(value, dict) or not isinstance(value.get("pid"), int):
            raise RuntimeError("Missing structured worker receipt")
        return value

    def new_fixture(self, count: int) -> tuple[Path, dict]:
        fixture = self.run / "fixtures" / ("copy-" + str(uuid.uuid4()))
        return fixture, self.invoke("seed", fixture, str(count))

    def run_case(self, case: dict) -> dict:
        fixture, seeded = self.new_fixture(case["count"])
        if case["kind"] == "admission":
            admitted = self.invoke("admission", fixture, case["variant"])
            self.separate_processes(seeded, admitted)
            if admitted.get("groupedSelected") or admitted.get("journalCreated") or admitted.get("executionPerformed") or not admitted.get("namespaceUnchanged"):
                raise RuntimeError("Ineligible admission mutated namespace/catalog or selected grouped execution")
            return {"case": case, "fixture": str(fixture.relative_to(self.run)), "seeded": seeded, "admission": admitted}
        stopped = self.invoke("forward", fixture, case["metadataPolicy"], case.get("boundary", "none"),
                              str(case["group"]) if "group" in case else "-",
                              str(case["member"]) if "member" in case else "-", case.get("mechanism", "none"),
                              str(case["maximumPages"]) if "maximumPages" in case else "-",
                              expected=86 if case.get("mechanism") == "process_crash" else 0)
        record_id = stopped.get("recordID") or "-"
        cold = self.invoke("cold-inspect", fixture, record_id)
        repeated = self.invoke("cold-inspect", fixture, record_id)
        self.separate_processes(seeded, stopped, cold, repeated)
        for value in (cold, repeated):
            if not value.get("sourceUnchanged") or not value.get("noForwardAutoAction"):
                raise RuntimeError("Cold inspection changed protected generated files")
        for field in ("recordStatus", "state", "revision", "classificationCounts", "inventoryDigest", "destinationFingerprint"):
            if cold.get(field) != repeated.get(field):
                raise RuntimeError("Repeated independent cold inspection changed evidence")
        if case["kind"] == "happy":
            if stopped.get("disposition") != "succeeded" or stopped.get("reportedSucceeded") != case["count"]:
                raise RuntimeError("Production happy path did not acknowledge every input")
            if cold.get("state") != "completed" or cold.get("classificationCounts") != {"confirmed_public": case["count"]}:
                raise RuntimeError("Production happy path failed independent publication verification")
            expected_groups = [list(range(start, min(start + 16, case["count"]))) for start in range(0, case["count"], 16)]
            if cold.get("groups") != expected_groups:
                raise RuntimeError("Production groups/tail membership differs from admitted order")
        elif case["kind"] == "storage_full":
            if not stopped.get("genuineSQLiteFullObserved") or not any(code & 0xff == 13 for code in stopped.get("observedSQLiteFailureCodes", [])):
                raise RuntimeError("Storage limit did not produce observed SQLITE_FULL")
            if stopped.get("disposition") == "succeeded":
                raise RuntimeError("Real SQLITE_FULL was reported as successful completion")
        else:
            if not stopped.get("targetReached"):
                raise RuntimeError("Requested typed production checkpoint was not exercised")
            mechanism = case["mechanism"]
            if mechanism == "lost_acknowledgement" and not stopped.get("acknowledgementLost"):
                raise RuntimeError("Commit acknowledgement injection did not fire")
            if mechanism == "cooperative_stop" and not stopped.get("cancellationRequested"):
                raise RuntimeError("Stop was not requested on the engine cancellation token")
            if cold.get("recordStatus") != "grouped":
                if not (mechanism == "process_crash" and case["boundary"] == "manifestWillCommit" and cold.get("recordStatus") == "missing"):
                    raise RuntimeError("Interrupted production evidence unexpectedly missing/refused")
            else:
                counts = cold["classificationCounts"]
                actual_public = counts.get("confirmed_public", 0) + counts.get("uncommitted_public", 0)
                expected_public = self.expected_public(case)
                if actual_public != expected_public:
                    raise RuntimeError("Interruption changed publication prefix or started later work")
                if mechanism == "cooperative_stop" and counts.get("uncommitted_public", 0) != 0:
                    raise RuntimeError("Stop failed to drain and record its safe publication segment")
                if stopped.get("reportedSucceeded", 0) > counts.get("confirmed_public", 0):
                    raise RuntimeError("Returned success exceeded cold-confirmed durable publication")
                if mechanism == "process_crash":
                    confirmed = self.expected_crash_confirmed(case)
                    if counts.get("confirmed_public", 0) != confirmed:
                        raise RuntimeError("Crash reader invented or lost a durable publication outcome")
                    expected_phases = self.expected_crash_phases(case)
                    actual_phases = [row["phase"] for row in cold["members"]]
                    if actual_phases != expected_phases:
                        raise RuntimeError("Cold inspection invented a seal, outcome or never-staged fact")
        return {"case": case, "fixture": str(fixture.relative_to(self.run)), "seeded": seeded,
                "execution": stopped, "cold": cold, "repeatedCold": repeated}

    @staticmethod
    def expected_public(case: dict) -> int:
        boundary = case["boundary"]
        if "member" in case:
            member = case["member"]
            if boundary in ("memberWillStage", "memberStaged"):
                return member // 16 * 16
            return member + (1 if boundary in ("memberPublished", "memberSynced") else 0)
        if "group" in case:
            start = case["group"] * 16
            return min(start + 16, case["count"]) if boundary in ("groupWillRecordOutcomes", "groupOutcomesRecorded") else start
        return case["count"] if boundary.startswith("terminal") else 0

    @staticmethod
    def expected_crash_confirmed(case: dict) -> int:
        if "member" in case:
            return case["member"] // 16 * 16
        if "group" in case:
            start = case["group"] * 16
            return min(start + 16, case["count"]) if case["boundary"] == "groupOutcomesRecorded" else start
        return case["count"] if case["boundary"].startswith("terminal") else 0

    @staticmethod
    def expected_crash_phases(case: dict) -> list[str]:
        boundary = case["boundary"]
        if "member" in case:
            group = case["member"] // 16
            current = "declared" if boundary in ("memberWillStage", "memberStaged") else "sealed"
        elif "group" in case:
            group = case["group"]
            if boundary == "groupWillDeclare":
                return ["published"] * (group * 16) + ["notDeclared"] * (case["count"] - group * 16)
            current = "published" if boundary == "groupOutcomesRecorded" else (
                "sealed" if boundary in ("groupSealed", "groupWillRecordOutcomes") else "declared")
        else:
            return ["published" if boundary.startswith("terminal") else "notDeclared"] * case["count"]
        start, end = group * 16, min((group + 1) * 16, case["count"])
        return ["published"] * start + [current] * (end - start) + ["notDeclared"] * (case["count"] - end)

    @staticmethod
    def separate_processes(*receipts: dict) -> None:
        pids = [receipt["pid"] for receipt in receipts]
        if len(pids) != len(set(pids)):
            raise RuntimeError("Required independent processes were not distinct")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--describe-plan", action="store_true", help="Print semantic cases without executing or creating fixtures")
    parser.add_argument("--section", choices=("all", "happy", "member_boundary", "group_boundary", "global_boundary", "storage_full", "admission"), default="all")
    parser.add_argument("--mechanism", choices=("cooperative_stop", "injected_error", "process_crash", "lost_acknowledgement", "sqlite_full"))
    parser.add_argument("--member", type=int, choices=range(33))
    args = parser.parse_args()
    if args.describe_plan:
        print(json.dumps({"apiFrozen": API_FROZEN, "cases": matrix_plan()}, indent=2, sort_keys=True))
        return 0
    if not API_FROZEN:
        print(json.dumps({"passed": False, "executed": False, "reason": "production_checkpoint_api_not_frozen"}))
        return 2
    qualification = Qualification()
    try:
        qualification.snapshot()
        qualification.compile()
        selected = [case for case in matrix_plan() if (args.section == "all" or case["kind"] == args.section)
                    and (args.mechanism is None or case.get("mechanism") == args.mechanism)
                    and (args.member is None or case.get("member") == args.member)]
        if not selected:
            raise RuntimeError("Selection contains no qualification cases")
        qualification.report["selection"] = {"section": args.section, "mechanism": args.mechanism, "member": args.member}
        qualification.report["plannedCases"] = len(selected)
        for case in selected:
            qualification.report["cases"].append(qualification.run_case(case))
        qualification.report["selectedCasesPassed"] = True
        qualification.report["fullMatrixExecuted"] = selected == matrix_plan()
        qualification.report["productionExecutionQualified"] = qualification.report["fullMatrixExecuted"]
        qualification.report["passed"] = True
    except Exception as error:
        qualification.report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        write(qualification.run / "report.json", json.dumps(qualification.report, indent=2, sort_keys=True).encode())
    print(json.dumps({"passed": qualification.report["passed"], "report": str(qualification.run / "report.json")}))
    return 0 if qualification.report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
