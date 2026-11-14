#!/usr/bin/env python3
"""B03.4 real native Trash process qualification. Never permanently cleans up."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent
PROMOTED_API_FROZEN = True
NATIVE_TRASH_EXECUTION_AUTHORIZED = True
COUNTS = (1, 16, 17, 31, 33)
POLICIES = ("strict", "destinationOwnership")
SEEDS = ("published", "undone", "sealedUnpublished", "neverCreatedTail")
GLOBAL_STAGES = ("inventoryVerified", "invalidationWillCommit", "invalidationCommitted",
                 "cleanupTerminalWillCommit", "cleanupTerminalCommitted")
GROUP_STAGES = ("trashIntentWillCommit", "trashIntentCommitted", "nativeTrashWillEnter", "nativeTrashReturned",
                "returnedLocationRecorded", "trashSynced", "trashOutcomeWillCommit", "trashOutcomeRecorded")
MECHANISMS = ("cooperative_stop", "injected_error", "process_crash")


def matrix_plan() -> list[dict]:
    cases: list[dict] = []
    for seed in SEEDS:
        for count in COUNTS:
            if seed == "neverCreatedTail" and count <= 16:
                continue
            for policy in POLICIES:
                cases.append({"kind": "happy", "seed": seed, "count": count, "policy": policy})
    for policy in POLICIES:
        cases.append({"kind": "collision", "seed": "undone", "count": 17, "policy": policy})
        for count in (1, 17):
            cases.append({"kind": "ordinaryControl", "seed": "ordinary", "count": count, "policy": policy})
    for seed in SEEDS:
        active_groups = range(2 if seed == "neverCreatedTail" else 3)
        for stage in GLOBAL_STAGES:
            for mechanism in MECHANISMS:
                cases.append({"kind": "boundary", "seed": seed, "count": 33, "policy": "strict",
                              "stage": stage, "mechanism": mechanism})
        for group in active_groups:
            for stage in GROUP_STAGES:
                for mechanism in MECHANISMS:
                    cases.append({"kind": "boundary", "seed": seed, "count": 33, "policy": "strict",
                                  "stage": stage, "group": group, "mechanism": mechanism})
            for stage in ("trashIntentWillCommit", "trashOutcomeWillCommit"):
                cases.append({"kind": "boundary", "seed": seed, "count": 33, "policy": "strict",
                              "stage": stage, "group": group, "mechanism": "lost_acknowledgement"})
        for stage in ("invalidationWillCommit", "cleanupTerminalWillCommit"):
            cases.append({"kind": "boundary", "seed": seed, "count": 33, "policy": "strict",
                          "stage": stage, "mechanism": "lost_acknowledgement"})
    for seed in ("published", "undone"):
        cases.append({"kind": "storage_full", "seed": seed, "count": 33, "policy": "strict",
                      "mechanism": "sqlite_full"})
    return cases


def compaction_case(case: dict) -> bool:
    return case["kind"] == "happy" and case["seed"] in ("published", "undone") and case["count"] == 33


def read_owned_source(path: Path, maximum: int = 1_048_576) -> bytes:
    """Root-authorized bounded snapshot read; never follow a source redirection."""
    if path.resolve() != path:
        raise RuntimeError("Qualification source has a redirected ancestor")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                or before.st_nlink != 1 or not 0 <= before.st_size <= maximum):
            raise RuntimeError("Unsafe qualification source snapshot")
        chunks, size = [], 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            size += len(chunk)
            if size > maximum:
                raise RuntimeError("Qualification source exceeded its snapshot bound")
            chunks.append(chunk)
        after, linked = os.fstat(fd), path.lstat()
        for field in ("st_dev", "st_ino", "st_size", "st_mode", "st_uid", "st_mtime_ns"):
            if getattr(before, field) != getattr(after, field):
                raise RuntimeError("Qualification source changed during snapshot")
        if after.st_nlink != 1 or (linked.st_dev, linked.st_ino) != (after.st_dev, after.st_ino):
            raise RuntimeError("Qualification source link changed during snapshot")
        return b"".join(chunks)
    finally:
        os.close(fd)


def source_bundle(qualification, helper) -> Path:
    original = read_owned_source(qualification.run / "harness/GroupedCopyProductionWorker.swift")
    needle = b"@main private enum GroupedCopyProductionWorker"
    if original.count(needle) != 1:
        raise RuntimeError("Frozen forward worker entry point changed")
    snippet = read_owned_source(TOOLS / "GroupedCopyNativeTrashProcessWorker.swift")
    runner = read_owned_source(Path(__file__).absolute())
    combined = original.replace(needle, b"private enum GroupedCopyProductionWorker") + b"\n" + snippet
    target = qualification.run / "harness/GroupedCopyNativeTrashCombined.swift"
    helper.write(target, combined)
    qualification.frozen[target] = hashlib.sha256(combined).hexdigest()
    for name, data in (("GroupedCopyNativeTrashProcessWorker.swift", snippet), (Path(__file__).name, runner)):
        copied = qualification.run / "harness" / name
        helper.write(copied, data)
        qualification.frozen[copied] = hashlib.sha256(data).hexdigest()
    qualification.report["nativeTrashSourceBundle"] = {
        "forwardOriginalSHA256": hashlib.sha256(original).hexdigest(),
        "snippetSHA256": hashlib.sha256(snippet).hexdigest(), "combinedSHA256": hashlib.sha256(combined).hexdigest(),
        "runnerSHA256": hashlib.sha256(runner).hexdigest(),
        "transformation": "Remove only frozen forward @main; concatenate in one file to reuse private fixture helpers"}
    return target


def expected_boundary(case: dict, initial: dict) -> tuple[list[str], str, bool]:
    """Independent protocol table, not output-equality or inferred success."""
    groups = initial["groups"]
    phases = ["none"] * len(groups)
    stage, mechanism = case["stage"], case["mechanism"]
    pre_invalidation = stage in ("inventoryVerified", "invalidationWillCommit") and mechanism != "lost_acknowledgement"
    if pre_invalidation:
        return phases, initial["state"], False
    state = "cleanupReview"
    if stage.startswith("cleanupTerminal"):
        phases = ["none" if row["neverCreated"] else "confirmed" for row in groups]
        if stage == "cleanupTerminalCommitted" or mechanism == "lost_acknowledgement":
            state = "cleaned"
    elif "group" in case:
        group = case["group"]
        for ordinal in range(group):
            phases[ordinal] = "confirmed"
        durable = {"trashIntentWillCommit": "none", "trashIntentCommitted": "intent", "nativeTrashWillEnter": "intent",
                   "nativeTrashReturned": "intent", "returnedLocationRecorded": "returned", "trashSynced": "returned",
                   "trashOutcomeWillCommit": "returned", "trashOutcomeRecorded": "confirmed"}[stage]
        if mechanism == "lost_acknowledgement":
            durable = "intent" if stage == "trashIntentWillCommit" else "confirmed"
        elif mechanism == "cooperative_stop" and stage in (
                "nativeTrashReturned", "returnedLocationRecorded", "trashSynced", "trashOutcomeWillCommit", "trashOutcomeRecorded"):
            durable = "confirmed"
        phases[group] = durable
    return phases, state, True


def check_boundary_return(case: dict, initial: dict, action: dict) -> dict:
    """Acknowledged returns differ from cold commits after a lost acknowledgement."""
    stage, mechanism = case["stage"], case["mechanism"]
    if mechanism == "process_crash":
        expected = {"termination": "_exit(86)", "stage": stage, "group": case.get("group"), "returned": False}
        if (action.get("termination") != expected["termination"] or action.get("stage") != stage
                or action.get("group") != case.get("group") or "disposition" in action):
            raise RuntimeError(f"Crash incorrectly claimed a returned cleanup result: expected={expected}, actual={action}")
        return expected
    created = [row["ordinal"] for row in initial["groups"] if not row["neverCreated"]]
    acknowledged = 0
    if stage.startswith("cleanupTerminal"):
        acknowledged = len(created)
    elif "group" in case:
        acknowledged = sum(ordinal < case["group"] for ordinal in created)
        # The outcome has already been acknowledged before this hook. A Stop
        # after native entry also drains the one current outcome before returning.
        if stage == "trashOutcomeRecorded" or (mechanism == "cooperative_stop" and stage in (
                "nativeTrashReturned", "returnedLocationRecorded", "trashSynced", "trashOutcomeWillCommit")):
            acknowledged += 1
    terminal_stop = mechanism == "cooperative_stop" and stage == "cleanupTerminalCommitted"
    disposition = "succeeded" if terminal_stop else "partial" if acknowledged else (
        "cancelled" if mechanism == "cooperative_stop" else "failed")
    statuses = ["succeeded"] * acknowledged
    roles = ["transfer"] * acknowledged
    if not terminal_stop:
        statuses.append("cancelled" if mechanism == "cooperative_stop" else "failed")
        roles.append("job")
    expected = {"disposition": disposition, "reportedSucceededAreas": acknowledged,
                "cancellationRequested": mechanism == "cooperative_stop",
                "returnedOutcomeRoles": roles, "returnedOutcomeStatuses": statuses,
                "failureCodes": [] if mechanism == "cooperative_stop" else ["ioFailure"]}
    actual = {key: action.get(key) for key in expected}
    if actual != expected:
        raise RuntimeError(f"Cleanup acknowledgement oracle failed at {stage}/{case.get('group')}/{mechanism}: expected={expected}, actual={actual}")
    return expected


def check_storage_full(case: dict, initial: dict, action: dict, observed: dict) -> None:
    """SQLITE_FULL is an actual failed transaction, not a lost acknowledgement."""
    codes = action.get("observedSQLiteFailureCodes", [])
    genuine = [code for code in codes if type(code) is int and code & 255 == 13]
    if not genuine or action.get("genuineSQLiteFullCount") != len(genuine) or action.get("sqliteFailureCount") != len(codes):
        raise RuntimeError("Actual SQLite numeric13 was not observed; a completed or synthetic failure cannot qualify FULL")
    if action.get("disposition") == "succeeded" or action.get("cancellationRequested"):
        raise RuntimeError("Storage FULL must return non-success without pretending cooperative Stop")
    pressure = action.get("storagePressure", {})
    pages, free = pressure.get("requestedMaximumPages"), pressure.get("initialFreePages")
    if type(pages) is not int or type(free) is not int or not 0 <= free <= pages <= 16384 or pages == 0:
        raise RuntimeError("FULL did not use bounded read-only current page_count/freelist_count pressure")
    events = action.get("checkpoints", [])
    phases = ["none"] * len(initial["groups"])
    state, invalidated, revision = initial["state"], False, initial["revision"]
    native_group = None
    if events:
        last = events[-1]
        stage, group = last.get("stage"), last.get("group")
        if stage == "invalidationWillCommit":
            if group is not None:
                raise RuntimeError("Invalidation FULL unexpectedly named a group")
        elif stage == "cleanupTerminalWillCommit":
            phases = ["confirmed"] * len(phases)
            state, invalidated = "cleanupReview", True
            revision += 1 + len(phases) * 3
        elif stage in ("trashIntentWillCommit", "nativeTrashReturned", "trashOutcomeWillCommit"):
            if type(group) is not int or not 0 <= group < len(phases):
                raise RuntimeError("FULL save checkpoint lacks its exact group")
            for ordinal in range(group):
                phases[ordinal] = "confirmed"
            state, invalidated = "cleanupReview", True
            revision += 1 + group * 3
            if stage == "nativeTrashReturned":
                phases[group] = "intent"; native_group = group; revision += 1
            elif stage == "trashOutcomeWillCommit":
                phases[group] = "returned"; native_group = group; revision += 2
        else:
            raise RuntimeError("FULL occurred outside a recognized actual catalog save boundary")
        if last.get("revision") != revision:
            raise RuntimeError("FULL pre-save revision differs from independent successful commit count")
    if ([row["cleanupPhase"] for row in observed["groups"]] != phases
            or observed["state"] != state or observed["undoInvalidated"] != invalidated
            or observed["revision"] != revision):
        raise RuntimeError("FULL cold catalog differs from exact failed-transaction/earlier-commit boundary")
    if observed["memberPhases"] != initial["memberPhases"]:
        raise RuntimeError("Cleanup FULL rewrote member publication/reversal facts")
    if action.get("reportedSucceededAreas") != phases.count("confirmed"):
        raise RuntimeError("FULL reported unacknowledged or missing successful native group outcomes")
    for ordinal, row in enumerate(observed["groups"]):
        absent = phases[ordinal] in ("returned", "confirmed") or ordinal == native_group
        if row["originalAbsent"] != absent:
            raise RuntimeError("FULL native/original location differs from the failed-save boundary")
        if phases[ordinal] in ("intent", "returned") and not row.get("unknownNativeOutcomeProtected"):
            raise RuntimeError("FULL uncertain native outcome lost its explicit protection")
    if any(phase in ("intent", "returned") for phase in phases) and observed["canCleanup"]:
        raise RuntimeError("Cold FULL intent/returned outcome regained automatic cleanup authority")
    if invalidated and (observed.get("canUndo") or observed.get("groupedReviewActions")):
        raise RuntimeError("Cleanup invalidation regained recovery or Undo authority after FULL")
    if native_group is not None and action.get("knownNativeRecoveryLocations", 0) <= 0:
        raise RuntimeError("FULL after native return failed to report its exact returned recovery location")


def execute_selected(selected: list[dict]) -> int:
    sys.dont_write_bytecode = True
    location = ROOT / "tools/verify_grouped_copy_production.py"
    original_sha = hashlib.sha256(read_owned_source(location)).hexdigest()
    spec = importlib.util.spec_from_file_location("native_trash_forward_helpers", location)
    if spec is None or spec.loader is None:
        raise RuntimeError("Missing frozen forward harness helpers")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    if hashlib.sha256(read_owned_source(location)).hexdigest() != original_sha:
        raise RuntimeError("Forward helper changed during import")
    q = helper.Qualification()
    q.report.update({"packet": "B03.4 real native Trash qualification", "passed": False,
        "productionExecutionQualified": False, "nativeTrashPacketQualified": False,
        "nativeTrashDefaultRoute": True, "fixturesAndNativeTargetsRetained": True,
        "plannedCases": len(matrix_plan()), "selectedCases": len(selected), "fullMatrixExecuted": False,
        "compactionCoverage": {"label": "Fresh public catalog compaction after real native Trash, then independent cold verification",
            "plannedCases": [case for case in matrix_plan() if compaction_case(case)],
            "selectedCases": [case for case in selected if compaction_case(case)],
            "executedCases": [], "allPlannedCasesPassed": False},
        "unexercised": ["Physical power loss or surprise volume removal", "Denied/TCC/provider/read-only topologies",
            "Forced native FileManager error accompanied by returned URL", "Genuine SQLiteFULL cases not yet qualified for both published and undone seeds",
            "Packet4 stale/substitution/sync-failure actions need promoted unit/process qualification"],
        "scope": ["Only fresh marked generated .build fixtures and their exact native returned Trash targets",
            "Default production FileManager.trashItem; no relocation seam, arbitrary Trash search or permanent cleanup",
            "Independent cold processes never call cleanup/Undo/Trash or adopt missing areas",
            "Stage injection, cooperative Stop, _exit86, lost acknowledgements and numeric SQLite13 remain distinct"],
        "snapshotScope": ["Root-authorized FileOperations/*.swift snapshot for this generated qualification only",
            "Frozen forward helper and worker; native Trash worker and runner bounded regular owned single-link reads",
            "Compile/run source and binary hashes rechecked around every command; no App/UI or owner catalog access"]})
    try:
        q.snapshot()
        for name, plan in (("native-trash-semantic-plan.json", matrix_plan()), ("native-trash-selected-plan.json", selected)):
            data = json.dumps(plan, indent=2, sort_keys=True).encode()
            target = q.run / name
            helper.write(target, data)
            q.frozen[target] = hashlib.sha256(data).hexdigest()
        q.compile()
        combined = source_bundle(q, helper)
        binary = q.run / "native-trash-worker"
        q.command(["xcrun", "swiftc", "-O", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                   "-j", "2", "-num-threads", "2", "-module-cache-path", str(q.run / "modules"), "-o", str(binary),
                   *[str(path) for path in sorted((q.run / "sources").glob("*.swift"))], str(combined)],
                  "native-trash-compile", timeout=600)
        q.frozen[binary] = q.report["nativeTrashBinarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()

        def invoke(phase: str, fixture: Path, record: str, stage: str = "none", group: int | None = None,
                   mechanism: str = "none", policy: str = "strict") -> dict:
            output = q.command([str(binary), phase, str(fixture), record, stage,
                                "-" if group is None else str(group), mechanism, policy], phase,
                               expected=86 if mechanism == "process_crash" else 0, timeout=180)
            receipt = json.loads(output)
            if not isinstance(receipt.get("pid"), int):
                raise RuntimeError("Missing native process receipt")
            return receipt

        def cold(phase: str, fixture: Path, record: str) -> dict:
            receipt = invoke(phase, fixture, record)
            if not receipt.get("coldObservationOnly") or receipt.get("nativeTrashInvoked") or not receipt.get("sourceUnchanged"):
                raise RuntimeError("Cold observation performed an action or changed generated sources")
            if not receipt.get("noArbitraryTrashSearch"):
                raise RuntimeError("Cold observation exceeded exact known native targets")
            return receipt

        def same_cold(first: dict, second: dict) -> None:
            for key in ("state", "revision", "undoInvalidated", "groups", "canCleanup", "memberPhases",
                        "destinationFingerprint", "publicFingerprint", "knownNativeFingerprint", "canUndo", "groupedReviewActions",
                        "catalogRecordDigest", "sourceFingerprint"):
                if first.get(key) != second.get(key):
                    raise RuntimeError("Independent repeated cold observation changed evidence")

        for case in selected:
            q.report["activeCase"] = case
            fixture, created = q.new_fixture(case["count"])
            prior = [created]
            if case["seed"] == "ordinary":
                seeded = invoke("ordinary", fixture, "-", policy=case["policy"])
                if seeded.get("disposition") != "succeeded":
                    raise RuntimeError("Ordinary control seed did not complete")
            else:
                stage, mechanism, group = "none", "none", "-"
                if case["seed"] in ("sealedUnpublished", "neverCreatedTail"):
                    stage = "groupSealed" if case["seed"] == "sealedUnpublished" else "groupDeclared"
                    mechanism = "cooperative_stop"
                    group = str((case["count"] - 1) // 16)
                seeded = q.invoke("forward", fixture, case["policy"], stage, group, "-", mechanism, "-")
            prior.append(seeded)
            record = seeded.get("recordID")
            if not isinstance(record, str):
                raise RuntimeError("Real execution seed lacks durable record")
            if case["seed"] == "undone":
                undone = invoke("undo", fixture, record)
                if undone.get("disposition") != "succeeded":
                    raise RuntimeError("Real Undo seed did not complete")
                prior.append(undone)
            if case["kind"] == "collision":
                collision = invoke("collision", fixture, record)
                if not collision.get("nativeCollisionSeeded") or not collision.get("nativeTrashDefaultRoute"):
                    raise RuntimeError("Name collision was not seeded through actual native Trash")
                prior.append(collision)
            observation = "observe-ordinary" if case["seed"] == "ordinary" else "observe"
            initial = cold(observation, fixture, record)
            if not initial.get("canCleanup"):
                raise RuntimeError("Real seeded evidence did not qualify explicit cleanup")
            if case["seed"] != "ordinary":
                expected_members = [list(range(start, min(start + 16, case["count"]))) for start in range(0, case["count"], 16)]
                if [row["members"] for row in initial["groups"]] != expected_members:
                    raise RuntimeError("Seed groups/tail differ from admitted membership")
                last_start = (case["count"] - 1) // 16 * 16
                expected_phases = ["undone" if case["seed"] == "undone" else
                    "sealed" if case["seed"] == "sealedUnpublished" and ordinal >= last_start else
                    "neverStaged" if case["seed"] == "neverCreatedTail" and ordinal >= last_start else
                    "published" for ordinal in range(case["count"])]
                expected_state = "completed" if case["seed"] == "published" else "undone" if case["seed"] == "undone" else "stoppedSettled"
                if (initial["memberPhases"] != expected_phases or initial["state"] != expected_state
                        or initial["undoInvalidated"] or any(row["cleanupPhase"] != "none" for row in initial["groups"])):
                    raise RuntimeError("Execution seed does not establish its exact declared member/terminal/cleanup facts")
                if [row["neverCreated"] for row in initial["groups"]] != [
                        case["seed"] == "neverCreatedTail" and ordinal == len(expected_members) - 1
                        for ordinal in range(len(expected_members))]:
                    raise RuntimeError("Never-created tail closure differs from its explicit seed")
            action = invoke("cleanup", fixture, record, case.get("stage", "none"), case.get("group"), case.get("mechanism", "none"))
            observed = cold(observation, fixture, record)
            repeated = cold(observation, fixture, record)
            q.separate_processes(*prior, initial, action, observed, repeated)
            same_cold(observed, repeated)
            if observed["publicFingerprint"] != initial["publicFingerprint"]:
                raise RuntimeError("Cleanup changed published copies or their absence/identity")
            expected_return = None
            if case["kind"] == "storage_full":
                check_storage_full(case, initial, action, observed)
            elif case["kind"] != "boundary":
                if action.get("disposition") != "succeeded" or observed["state"] != "cleaned" or not observed["undoInvalidated"]:
                    raise RuntimeError("Native cleanup was reported complete without durable cleaned disposition")
                acknowledged = sum(not row.get("neverCreated", False) for row in initial["groups"])
                expected_return = {"disposition": "succeeded", "reportedSucceededAreas": acknowledged,
                    "cancellationRequested": False, "failureCodes": [],
                    "returnedOutcomeRoles": ["transfer"] * acknowledged,
                    "returnedOutcomeStatuses": ["succeeded"] * acknowledged}
                actual_return = {key: action.get(key) for key in expected_return}
                if actual_return != expected_return:
                    raise RuntimeError(f"Successful cleanup return differs from exact native areas: expected={expected_return}, actual={actual_return}")
                expected = ["none" if row.get("neverCreated") else "confirmed" for row in observed["groups"]]
                if [row["cleanupPhase"] for row in observed["groups"]] != expected:
                    raise RuntimeError("Native cleanup did not confirm exactly the created groups")
                if any(row["cleanupPhase"] == "confirmed" and not row.get("knownNativeTargetVerified") for row in observed["groups"]):
                    raise RuntimeError("Native returned target failed independent ownership/descendant verification")
                if case["kind"] == "collision" and not (
                        observed.get("collisionObjectPreserved") and observed.get("nativeCollisionTargetsDistinct")):
                    raise RuntimeError("Native name collision lost/replaced a known generated object")
            else:
                expected_return = check_boundary_return(case, initial, action)
                phases, state, invalidated = expected_boundary(case, initial)
                if [row["cleanupPhase"] for row in observed["groups"]] != phases or observed["state"] != state:
                    raise RuntimeError("Interrupted native cleanup disagrees with independent durable-phase table")
                if observed["undoInvalidated"] != invalidated:
                    raise RuntimeError("Native cleanup did not durably invalidate Undo at the required boundary")
                mechanism = case["mechanism"]
                if not action.get("targetReached"):
                    raise RuntimeError("Requested native retention checkpoint was not reached")
                if mechanism == "cooperative_stop" and not action.get("cancellationRequested"):
                    raise RuntimeError("Native Stop did not reach the executing root cancellation token")
                if mechanism == "lost_acknowledgement" and not action.get("acknowledgementLost"):
                    raise RuntimeError("Native cleanup lost-ack hook did not fire after actual COMMIT")
                if any(phase in ("intent", "returned") for phase in phases) and observed["canCleanup"]:
                    raise RuntimeError("Cold unknown native outcome regained cleanup authority")
                if case["stage"] == "nativeTrashReturned" and mechanism in ("process_crash", "injected_error"):
                    target = observed["groups"][case["group"]]
                    if not target["originalAbsent"] or not target.get("unknownNativeOutcomeProtected"):
                        raise RuntimeError("Missing original was incorrectly treated as native Trash success")
                if action.get("reportedSucceededAreas", 0) > phases.count("confirmed"):
                    raise RuntimeError("Reported native cleanup success exceeds durable confirmed group outcomes")
            compaction = None
            if compaction_case(case):
                compacted = invoke("compact", fixture, record, policy=case["policy"])
                after_compaction = cold(observation, fixture, record)
                q.separate_processes(*prior, initial, action, observed, repeated, compacted, after_compaction)
                same_cold(repeated, after_compaction)
                for key in ("compacted", "publicCompactJournalInvoked", "exactRecordPreserved", "ownedNamespaceUnchanged",
                            "payloadFilesystemMutationTrapsInstalled", "sourceUnchanged", "noArbitraryTrashSearch"):
                    if compacted.get(key) is not True:
                        raise RuntimeError("Compaction receipt lacks an explicit maintenance/preservation guarantee")
                if compacted.get("nativeTrashInvoked") is not False or compacted.get("mutationTrapExitCode") != 87:
                    raise RuntimeError("Compaction entered a payload mutation route or lacked fatal mutation traps")
                for key in ("recordID", "revision", "catalogRecordDigest", "sourceFingerprint", "destinationFingerprint",
                            "publicFingerprint", "knownNativeFingerprint"):
                    if compacted.get(key) != repeated.get(key) or compacted.get(key) != after_compaction.get(key):
                        raise RuntimeError("Compaction changed exact record, known targets, owned namespace or source evidence")
                for key in ("databaseBytes", "eventCount", "freePages", "beforeDatabaseBytes", "beforeEventCount", "beforeFreePages"):
                    if type(compacted.get(key)) is not int or compacted[key] < 0:
                        raise RuntimeError("Compaction lacks numeric public maintenance evidence")
                if (compacted["databaseBytes"] == 0 or compacted["beforeDatabaseBytes"] == 0
                        or compacted["eventCount"] != 1 or compacted["beforeEventCount"] <= compacted["eventCount"]
                        or after_compaction["state"] != "cleaned" or after_compaction["undoInvalidated"] is not True
                        or after_compaction["canUndo"] is not False or after_compaction["canCleanup"] is not False
                        or after_compaction["groupedReviewActions"]
                        or after_compaction["memberPhases"] != ["published" if case["seed"] == "published" else "undone"] * 33
                        or any(row["cleanupPhase"] != "confirmed" or not row.get("knownNativeTargetVerified")
                               for row in after_compaction["groups"])):
                    raise RuntimeError("Compaction lost current cleanup evidence, phases or revoked Undo authority")
                compaction = {"action": compacted, "independentCold": after_compaction}
                q.report["compactionCoverage"]["executedCases"].append(case)
            q.report["cases"].append({"case": case, "fixture": str(fixture.relative_to(q.run)), "seed": prior,
                                      "initial": initial, "expectedReturn": expected_return, "action": action,
                                      "cold": observed, "repeatedCold": repeated, "compaction": compaction})
        q.report.pop("activeCase", None)
        q.report["nativeTrashSelectedCasesPassed"] = True
        q.report["fullMatrixExecuted"] = selected == matrix_plan()
        q.report["realNativeTrashExercised"] = any(
            row["cleanupPhase"] == "confirmed" for entry in q.report["cases"] for row in entry["cold"]["groups"])
        full_seeds = {entry["case"]["seed"] for entry in q.report["cases"] if entry["case"]["kind"] == "storage_full"}
        q.report["genuineSQLiteFullQualified"] = full_seeds == {"published", "undone"}
        if q.report["genuineSQLiteFullQualified"]:
            q.report["unexercised"].remove("Genuine SQLiteFULL cases not yet qualified for both published and undone seeds")
        coverage = q.report["compactionCoverage"]
        coverage["allPlannedCasesPassed"] = coverage["executedCases"] == coverage["plannedCases"]
        qualified = (q.report["fullMatrixExecuted"] and q.report["realNativeTrashExercised"]
                     and q.report["genuineSQLiteFullQualified"] and coverage["allPlannedCasesPassed"])
        q.report["nativeTrashPacketQualified"] = qualified
        q.report["productionExecutionQualified"] = qualified
        q.report["passed"] = True
        q.report["qualificationMeaning"] = "Selected declared cases passed; packet qualified only when the entire declared matrix, both genuine FULL seeds and all labelled post-cleanup compaction cases pass. Compaction observations extend existing cases, not the matrix case count. Listed environment limits remain unexercised."
    except Exception as error:
        q.report["passed"] = False
        q.report["nativeTrashPacketQualified"] = False
        q.report["productionExecutionQualified"] = False
        q.report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        helper.write(q.run / "report.json", json.dumps(q.report, indent=2, sort_keys=True).encode())
    print(json.dumps({"passed": q.report.get("passed", False), "nativeTrashPacketQualified": q.report.get("nativeTrashPacketQualified", False),
                      "fullMatrixExecuted": q.report.get("fullMatrixExecuted", False), "selectedCasesPassed": q.report.get("nativeTrashSelectedCasesPassed", False),
                      "report": str(q.run / "report.json"), "fixturesAndNativeTargetsRetained": True}))
    return 0 if q.report.get("passed") else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--describe-plan", action="store_true")
    parser.add_argument("--section", choices=("all", "happy", "boundary", "collision", "ordinaryControl", "storage_full"), default="all")
    parser.add_argument("--seed", choices=SEEDS + ("ordinary",))
    parser.add_argument("--mechanism", choices=MECHANISMS + ("lost_acknowledgement", "sqlite_full"))
    parser.add_argument("--group", type=int, choices=range(3))
    args = parser.parse_args()
    selected = [case for case in matrix_plan() if (args.section == "all" or case["kind"] == args.section)
                and (args.seed is None or case["seed"] == args.seed)
                and (args.mechanism is None or case.get("mechanism") == args.mechanism)
                and (args.group is None or case.get("group") == args.group)]
    if args.describe_plan:
        print(json.dumps({"executed": False, "promotedAPIFrozen": PROMOTED_API_FROZEN,
                          "nativeTrashExecutionAuthorized": NATIVE_TRASH_EXECUTION_AUTHORIZED, "cases": selected}, indent=2))
        return 0
    if not PROMOTED_API_FROZEN or not NATIVE_TRASH_EXECUTION_AUTHORIZED:
        print(json.dumps({"executed": False, "reason": "awaiting_root_native_trash_execution_authorization_and_frozen_API"}))
        return 2
    if not selected:
        raise RuntimeError("Selection contains no cases")
    return execute_selected(selected)


if __name__ == "__main__":
    raise SystemExit(main())
