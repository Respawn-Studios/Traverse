#!/usr/bin/env python3
"""Fresh-process production grouped recovery/Undo qualification; root-owned execution.

Exact per-member oracles are independent of the production classifier. All fixture
data and immutable source/binary/log receipts stay in the repository's marked
qualification root. No owner journal, UI, Trash, mounts or power-loss claims.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
# Root reviews the complete worker, exact oracle and frozen API before opening
# this gate. A package build or one successful shard does not open it implicitly.
PRODUCTION_API_AND_ORACLE_REVIEWED = True
qualification_module = None


def matrix_plan() -> list[dict]:
    cases: list[dict] = []
    for count in (1, 16, 17, 31, 33):
        for policy in ("strict", "destinationOwnership"):
            cases.append({"kind": "happy_undo", "count": count, "metadataPolicy": policy})
    for action in ("confirmCopies", "confirmUndo", "finishReview"):
        for stage in ("reviewPrepared", "reviewIntentWillCommit", "reviewIntentCommitted", "reviewWillSync",
                      "reviewSynced", "reviewWillRecordOutcomes", "reviewOutcomesRecorded"):
            for mechanism in ("cooperative_stop", "injected_error", "process_crash"):
                cases.append({"kind": "confirmation", "action": action, "stage": stage, "mechanism": mechanism, "count": 1})
        for stage in ("reviewIntentWillCommit", "reviewWillRecordOutcomes"):
            cases.append({"kind": "confirmation", "action": action, "stage": stage,
                          "mechanism": "lost_acknowledgement", "count": 1})
    for member in range(33):
        for stage in ("reverseIntentWillCommit", "reverseIntentCommitted", "reverseWillRename", "reverseRenamed",
                      "reverseSynced", "reverseWillRecordOutcome", "reverseOutcomeRecorded"):
            for mechanism in ("cooperative_stop", "injected_error", "process_crash"):
                cases.append({"kind": "undo", "stage": stage, "mechanism": mechanism, "member": member, "count": 33})
        for stage in ("reverseIntentWillCommit", "reverseWillRecordOutcome"):
            cases.append({"kind": "undo", "stage": stage, "mechanism": "lost_acknowledgement", "member": member, "count": 33})
    for stage in ("reverseTerminalWillCommit", "reverseTerminalCommitted"):
        for mechanism in ("cooperative_stop", "injected_error", "process_crash"):
            cases.append({"kind": "undo", "stage": stage, "mechanism": mechanism, "count": 33})
    cases.append({"kind": "undo", "stage": "reverseTerminalWillCommit", "mechanism": "lost_acknowledgement", "count": 33})
    for variant in ("foreign_session", "reuse", "revision", "inventory"):
        cases.append({"kind": "authority", "variant": variant, "count": 1, "action": "confirmCopies"})
    for variant in ("public_corrupt", "private_corrupt", "marker_corrupt", "extra_child"):
        cases.append({"kind": "protected", "variant": variant, "count": 33, "action": "confirmCopies"})
    for member in (0, 15, 16, 32):
        cases.append({"kind": "partial_confirmation", "count": 33, "publishedThrough": member, "action": "confirmCopies"})
    for member in (0, 16):
        cases.append({"kind": "partial_confirmation", "count": 33, "publishedThrough": member,
                      "protectMember": member + 1, "action": "confirmCopies"})
    for change in ("source_edit", "source_remove"):
        for action in ("confirmCopies", "confirmUndo", "finishReview", "undo"):
            cases.append({"kind": "original_changed", "count": 33, "variant": change, "action": action})
    for stage in ("reverseIntentCommitted", "reverseRenamed", "reverseWillRecordOutcome"):
        cases.append({"kind": "explicit_retry", "count": 33, "stage": stage, "member": 16})
    for action in ("confirmCopies", "confirmUndo", "undo"):
        cases.append({"kind": "storage_full", "count": 33, "action": action, "mechanism": "sqlite_full"})
    return cases


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise RuntimeError(reason)


def member(phase: str, public: str, private: str) -> dict:
    return {"phase": phase, "public": public, "private": private}


def exact_members(snapshot: dict, expected: list[dict]) -> None:
    actual = snapshot["members"]
    require(len(actual) == len(expected), "Cold member count changed")
    for ordinal, (row, wanted) in enumerate(zip(actual, expected)):
        require(row.get("ordinal") == ordinal and all(row.get(key) == value for key, value in wanted.items()),
                f"Independent member oracle failed at ordinal {ordinal}: actual={row}, expected={wanted}")


def intact_inventory(snapshot: dict) -> None:
    require(snapshot["publicInventoryExact"] and all(row["areaInventoryExact"] for row in snapshot["members"])
            and all(row["inventoryExact"] and row["identityMatched"] and row["markerMatched"] for row in snapshot["groups"]),
            "Independent namespace/group/member inventory or identity changed")


def eligible_members(snapshot: dict, action: str) -> list[int]:
    wanted = {"confirmCopies": ("sealed", "matched", "absent"), "confirmUndo": ("reverseIntent", "absent", "matched")}.get(action)
    return [row["ordinal"] for row in snapshot["members"] if (row["phase"], row["public"], row["private"]) == wanted]


def seed_oracle(count: int, action: str, published_through: int, cold: dict) -> None:
    expected, states = [], []
    for index in range(count):
        if action == "confirmCopies":
            group_start, group_end = (published_through // 16) * 16, min((published_through // 16 + 1) * 16, count)
            if index < group_start:
                row, state = member("published", "matched", "absent"), "copied"
            elif index <= published_through:
                row, state = member("sealed", "matched", "absent"), "copyNeedsConfirmation"
            elif index < group_end:
                row, state = member("sealed", "absent", "matched"), "retainedCopy"
            else:
                row, state = member("notDeclared", "absent", "notDeclared"), "notStarted"
        elif action == "finishReview":
            row, state = (member("sealed", "absent", "matched"), "retainedCopy") if index < 16 else (member("notDeclared", "absent", "notDeclared"), "notStarted")
        elif action == "confirmUndo" and index == count - 1:
            row, state = member("reverseIntent", "absent", "matched"), "undoNeedsConfirmation"
        else:
            row, state = member("published", "matched", "absent"), "copied"
        expected.append(row); states.append(state)
    exact_members(cold["snapshot"], expected)
    intact_inventory(cold["snapshot"])
    require(cold["itemStates"] == states, "Real engine seed did not establish exact intended recovery fixture")
    require(cold["snapshot"]["state"] == ("completed" if action == "undo" else "active"), "Recovery seed head state mismatch")
    require(cold["availableActions"] == ([] if action == "undo" else [action]) and cold["canUndo"] == (action == "undo"),
            "Recovery seed grants unexpected action authority")


def undo_oracle(case: dict, cold: dict, execution: dict, initial: dict | None = None) -> None:
    """Infer exact disk/durable state from semantic boundary, never classifier labels."""
    stage, mechanism, count = case.get("stage", "none"), case.get("mechanism", "none"), case["count"]
    if stage.startswith("reverseTerminal") or stage == "none":
        expected = [member("undone", "absent", "matched") for _ in range(count)]
    else:
        ordinal = case["member"]
        current_phase, public, private = "published", "matched", "absent"
        if stage != "reverseIntentWillCommit":
            current_phase = "reverseIntent"
        if mechanism == "lost_acknowledgement":
            current_phase = "reverseIntent" if stage == "reverseIntentWillCommit" else "undone"
            public, private = ("matched", "absent") if stage == "reverseIntentWillCommit" else ("absent", "matched")
        elif stage in ("reverseRenamed", "reverseSynced", "reverseWillRecordOutcome", "reverseOutcomeRecorded"):
            public, private = "absent", "matched"
            # Stop is drained after exclusive rename and acknowledges that member.
            if mechanism == "cooperative_stop" or stage == "reverseOutcomeRecorded":
                current_phase = "undone"
        expected = [member("undone", "absent", "matched") if index > ordinal else
                    member(current_phase, public, private) if index == ordinal else member("published", "matched", "absent")
                    for index in range(count)]
    snapshot = cold["snapshot"]
    exact_members(snapshot, expected)
    intact_inventory(snapshot)
    require(snapshot["groupPhases"] == ["settled"] * ((count + 15) // 16), "Undo changed group durability/ownership phases")
    require(snapshot["reviewIntent"] is None and not snapshot["undoInvalidated"], "Undo created unrelated review/cleanup authority")
    expected_items = {("published", "matched", "absent"): "copied", ("reverseIntent", "matched", "absent"): "undoPending",
                      ("reverseIntent", "absent", "matched"): "undoNeedsConfirmation", ("undone", "absent", "matched"): "undone"}
    require(cold["itemStates"] == [expected_items[(row["phase"], row["public"], row["private"])] for row in expected],
            "Recovery classification disagrees with direct exact reverse slot oracle")
    if mechanism != "process_crash":
        acknowledged = sum(row["phase"] == "undone" for row in expected)
        if mechanism == "lost_acknowledgement" and stage == "reverseWillRecordOutcome":
            acknowledged -= 1
        require(execution["returnedSuccessCount"] == acknowledged, "Reported Undo successes differ from acknowledged member commits")
        complete_return = stage == "none" or (mechanism == "cooperative_stop" and all(row["phase"] == "undone" for row in expected))
        disposition = "succeeded" if complete_return else "partial" if acknowledged else (
            "cancelled" if mechanism == "cooperative_stop" else "failed")
        require(execution["disposition"] == disposition and execution["actionAchieved"] == complete_return,
                "Undo return disposition/action-achieved flag disagrees with exact acknowledged outcomes")
        expected_returns: list[dict] = []
        def returned(ordinal: int | None, status: str, failure: str = "none") -> dict:
            return {"ordinal": ordinal, "role": "job" if ordinal is None else "transfer", "status": status, "failure": failure}
        if complete_return:
            expected_returns = [returned(index, "succeeded") for index in range(count - 1, -1, -1)]
        elif stage.startswith("reverseTerminal"):
            expected_returns = [returned(index, "succeeded") for index in range(count - 1, -1, -1)]
            expected_returns.append(returned(None, "failed", "outOfSpace" if mechanism == "sqlite_full" else "ioFailure"))
        else:
            ordinal = case["member"]
            current_acknowledged = expected[ordinal]["phase"] == "undone" and not (
                mechanism == "lost_acknowledgement" and stage == "reverseWillRecordOutcome")
            first_unacknowledged = ordinal - 1 if current_acknowledged else ordinal
            expected_returns = [returned(index, "succeeded") for index in range(count - 1, first_unacknowledged, -1)]
            # After a drained Stop, the next loop sets its older active member
            # before checking cancellation; it receives cancelled, not the one
            # whose safe reversal was just acknowledged.
            active = first_unacknowledged if mechanism == "cooperative_stop" else ordinal
            for index in range(first_unacknowledged, -1, -1):
                if index != active:
                    expected_returns.append(returned(index, "notStarted"))
                elif mechanism == "cooperative_stop":
                    expected_returns.append(returned(index, "cancelled"))
                else:
                    reversed_current = stage in ("reverseRenamed", "reverseSynced", "reverseWillRecordOutcome")
                    failure = "recoveryUncertain" if reversed_current else "outOfSpace" if mechanism == "sqlite_full" else "ioFailure"
                    expected_returns.append(returned(index, "failed", failure))
            if current_acknowledged and mechanism != "cooperative_stop":
                expected_returns.append(returned(None, "failed", "ioFailure"))
        require(execution["returnedOutcomes"] == expected_returns,
                f"Undo returned ordinal/status/role association mismatch: actual={execution['returnedOutcomes']}, expected={expected_returns}")
    if stage != "none":
        intents = [int(event["member"]) for event in execution["events"] if event["stage"] == "reverseIntentWillCommit"]
        last = 0 if stage.startswith("reverseTerminal") else case["member"]
        require(intents == list(range(count - 1, last - 1, -1)), "Undo checkpoint order touched an unrequested next member or repeated an intent")
    all_undone = all(row["phase"] == "undone" for row in expected)
    pending = any(row["phase"] == "reverseIntent" and row["public"] == "matched" for row in expected)
    unconfirmed = any(row["phase"] == "reverseIntent" and row["private"] == "matched" for row in expected)
    if stage == "none":
        expected_state = "undone"
    elif mechanism == "lost_acknowledgement":
        expected_state = "undone" if stage == "reverseTerminalWillCommit" else "active"
    elif mechanism in ("process_crash", "sqlite_full"):
        expected_state = "undone" if stage == "reverseTerminalCommitted" else (
            "completed" if stage == "reverseIntentWillCommit" and case.get("member") == count - 1 else "active")
    elif mechanism == "injected_error":
        expected_state = "completed" if stage == "reverseIntentWillCommit" and case.get("member") == count - 1 else "needsReview"
    elif mechanism == "cooperative_stop":
        expected_state = "needsReview" if pending else ("undone" if all_undone else (
            "completed" if stage == "reverseIntentWillCommit" and case.get("member") == count - 1 else "stoppedSettled"))
    else:
        raise RuntimeError("Unmodelled Undo mechanism")
    require(snapshot["state"] == expected_state, f"Exact reverse head state mismatch: {snapshot['state']} vs {expected_state}")
    actions = ["confirmUndo"] if unconfirmed else (["finishReview"] if expected_state in ("active", "needsReview") and not pending else [])
    require(cold["availableActions"] == actions, "Cold Undo actions differ from exact durable/filesystem state")
    can_undo = not unconfirmed and not all_undone and (pending or expected_state in ("completed", "stoppedSettled"))
    require(cold["canUndo"] == can_undo, "Cold Undo authority differs from exact durable/filesystem state")
    if initial is not None:
        if stage == "none":
            saves = count * 2 + 1
        elif stage.startswith("reverseTerminal"):
            saves = count * 2 + int(stage == "reverseTerminalCommitted" or mechanism in ("cooperative_stop", "lost_acknowledgement"))
            if mechanism == "injected_error": saves += 1
        else:
            ordinal = case["member"]
            saves = (count - ordinal - 1) * 2
            if mechanism == "lost_acknowledgement":
                saves += 1 if stage == "reverseIntentWillCommit" else 2
            elif stage != "reverseIntentWillCommit":
                saves += 2 if expected[ordinal]["phase"] == "undone" else 1
            if mechanism in ("cooperative_stop", "injected_error") and (ordinal < count - 1 or stage != "reverseIntentWillCommit"):
                saves += 1  # Explicit close/needsReview in catch, or drained final terminal close.
        require(snapshot["revision"] == initial["snapshot"]["revision"] + saves,
                "Undo cold revision differs from exact acknowledged/lost commit count")


def confirmation_oracle(case: dict, initial: dict, cold: dict, execution: dict) -> None:
    stage, mechanism, action = case["stage"], case["mechanism"], case["action"]
    before, after = initial["snapshot"], cold["snapshot"]
    require(before["destinationFingerprint"] == after["destinationFingerprint"], "Confirmation moved/copied/deleted generated payloads")
    completed = stage == "reviewOutcomesRecorded" or (stage == "reviewWillRecordOutcomes" and mechanism == "lost_acknowledgement")
    expected = [{key: row[key] for key in ("phase", "public", "private")} for row in before["members"]]
    eligible = eligible_members(before, action)
    if completed:
        for index in eligible:
            expected[index]["phase"] = "published" if action == "confirmCopies" else "undone"
    exact_members(after, expected)
    intact_inventory(after)
    require(after["groupPhases"] == (["settled"] * len(before["groupPhases"]) if completed else before["groupPhases"]),
            "Confirmation changed wrong durable group phase")
    intent_committed = not completed and stage not in ("reviewPrepared", "reviewIntentWillCommit") or (
        stage == "reviewIntentWillCommit" and mechanism == "lost_acknowledgement")
    publications = [row for row in expected if row["phase"] in ("published", "undone")]
    terminal = "undone" if publications and all(row["phase"] == "undone" for row in publications) else (
        "completed" if all(row["phase"] == "published" for row in expected) else "stoppedSettled")
    require(after["state"] == (terminal if completed else "needsReview" if intent_committed else before["state"]), "Confirmation durable head state mismatch")
    if intent_committed:
        require(after["reviewIntent"] == {"kind": {"confirmCopies": "publication", "confirmUndo": "reversal", "finishReview": "closure"}[action],
                                           "members": eligible}, "Confirmation persisted wrong eligible subset intent")
    else:
        require(after["reviewIntent"] is None, "Unexpected confirmation review intent")
    require(cold["availableActions"] == ([] if completed else [action]), "Confirmation cold action eligibility mismatch")
    require(cold["canUndo"] == (completed and any(row["phase"] == "published" for row in expected)), "Confirmation granted wrong Undo authority")
    require(after["revision"] == before["revision"] + (2 if completed else 1 if intent_committed else 0),
            "Confirmation revision differs from exact intent/outcome commit count")
    if mechanism != "process_crash" and stage != "reviewPrepared":
        require(all(role == "job" for role in execution["returnedOutcomeRoles"]), "Confirmation reported transfer units instead of job evidence")
        succeeded = stage == "reviewOutcomesRecorded" and mechanism == "cooperative_stop"
        require(execution["actionAchieved"] == succeeded and execution["returnedSuccessCount"] == ((len(eligible) or 1) if succeeded else 0),
                "Confirmation acknowledged success differs from actual completed return")


def settled_confirmation_oracle(initial: dict, cold: dict, execution: dict, action: str, protected: int | None) -> None:
    before, after = initial["snapshot"], cold["snapshot"]
    expected = [{key: row[key] for key in ("phase", "public", "private")} for row in before["members"]]
    eligible = eligible_members(before, action)
    for ordinal in eligible:
        expected[ordinal]["phase"] = "published" if action == "confirmCopies" else "undone"
    exact_members(after, expected)
    publications = [row for row in expected if row["phase"] in ("published", "undone")]
    terminal = "undone" if publications and all(row["phase"] == "undone" for row in publications) else (
        "completed" if all(row["phase"] == "published" for row in expected) else "stoppedSettled")
    require(after["state"] == ("needsReview" if protected is not None else terminal), "Explicit subset confirmation persisted wrong terminal/protected state")
    require(after["revision"] == before["revision"] + 2 and after["reviewIntent"] is None and not after["undoInvalidated"],
            "Explicit subset confirmation did not commit exactly intent then outcomes/closure")
    require(after["groupPhases"] == ["settled"] * len(before["groupPhases"]), "Explicit subset confirmation left wrong group phase")
    require(cold["availableActions"] == [] and cold["canUndo"] == (protected is None and any(row["phase"] == "published" for row in expected)),
            "Explicit subset confirmation grants wrong subsequent action authority")
    states = {("published", "matched", "absent"): "copied", ("undone", "absent", "matched"): "undone",
              ("sealed", "absent", "matched"): "retainedCopy", ("notDeclared", "absent", "notDeclared"): "notStarted"}
    expected_states = ["protected" if index == protected else states[(row["phase"], row["public"], row["private"])]
                       for index, row in enumerate(expected)]
    require(cold["itemStates"] == expected_states, "Explicit subset confirmation misclassified completed/retained/protected members")
    require(execution["returnedSuccessCount"] == (len(eligible) or 1) and all(role == "job" for role in execution["returnedOutcomeRoles"]),
            "Explicit subset confirmation reported wrong count or fresh Copy outcomes")
    require(after["destinationFingerprint"] == before["destinationFingerprint"], "Explicit subset confirmation mutated payload namespace")
    intact_inventory(after)


def confirmation_full_oracle(initial: dict, cold: dict, execution: dict, action: str) -> None:
    pressure = execution["storagePressure"]
    attempts = pressure.get("attempts", [])
    require(pressure.get("fixtureExplicitAttempts") is True and pressure.get("productionAutomaticRetry") is False
            and pressure.get("maximumAttempts") == 256 and 1 <= len(attempts) <= 256
            and pressure.get("attemptCount") == len(attempts) and pressure.get("primingAttemptCount") == len(attempts) - 1,
            "FULL priming was not disclosed as bounded explicit one-attempt calls")
    expected = initial["snapshot"]
    initial_rows = initial["snapshot"]["members"]
    intent_ids: set[str] = set()
    intent_kind = "publication" if action == "confirmCopies" else "reversal"
    eligible = eligible_members(initial["snapshot"], action)
    prior_intent = None
    for ordinal, attempt in enumerate(attempts):
        require(attempt["ordinal"] == ordinal and attempt["before"] == expected and attempt["freshExplicitReviewToken"],
                "FULL priming reused consent or lost exact durable attempt ordering")
        after = attempt["after"]
        require(attempt["requestedMaximumPages"] == pressure["requestedMaximumPages"] == attempt["observedPageCount"],
                "FULL page cap changed between explicit attempts")
        require(attempt["priorStoredIntentID"] == prior_intent and attempt["sourceUnchanged"] and attempt["confirmationNamespaceUnchanged"],
                "FULL priming lost prior intent authority or changed payload namespace")
        require(after["members"] == initial_rows and after["groupPhases"] == initial["snapshot"]["groupPhases"]
                and after["sourceFingerprint"] == initial["snapshot"]["sourceFingerprint"]
                and after["destinationFingerprint"] == initial["snapshot"]["destinationFingerprint"],
                "Intent-only FULL priming recorded an outcome or mutated copied objects")
        intact_inventory(after)
        require(not attempt["acknowledgementLost"] and attempt["returnedSuccessCount"] == 0
                and attempt["sqliteFailureCount"] == len(attempt["observedSQLiteFailureCodes"]), "FULL attempt mixed acknowledgement/error mechanisms")
        if ordinal < len(attempts) - 1:
            require(attempt["targetReached"] and attempt["stopIssued"] and attempt["cancellationRequested"]
                    and attempt["disposition"] == "cancelled" and attempt["observedSQLiteFailureCodes"] == []
                    and attempt["genuineSQLiteFullCount"] == 0,
                    "Priming attempt did not stop immediately after a successful real intent commit")
            require([event["stage"] for event in attempt["events"]] == ["reviewPrepared", "reviewIntentWillCommit", "reviewIntentCommitted"],
                    "Priming attempt advanced into synchronization/outcome commit")
            require(attempt["returnedOutcomes"] == [{"ordinal": None, "role": "job", "status": "cancelled", "failure": "none"}],
                    "Priming cancellation returned transfer outcomes")
            require(after["revision"] == expected["revision"] + 1 and after["state"] == "needsReview"
                    and after["reviewIntent"] == {"kind": intent_kind, "members": eligible}
                    and attempt["storedIntentPreparedRevision"] == expected["revision"],
                    "Priming attempt did not persist exactly one newly prepared review intent")
            intent = attempt["storedIntentID"]
            require(isinstance(intent, str) and str(uuid.UUID(intent)).upper() == intent and intent not in intent_ids,
                    "Priming call reused a durable review intent identity")
            intent_ids.add(intent); prior_intent = intent
        else:
            require(not attempt["targetReached"] and not attempt["stopIssued"] and not attempt["cancellationRequested"]
                    and attempt["disposition"] == "failed" and attempt["genuineSQLiteFullCount"] > 0
                    and any(code & 255 == 13 for code in attempt["observedSQLiteFailureCodes"]),
                    "Final actual intent save did not fail with numeric SQLite FULL13")
            require([event["stage"] for event in attempt["events"]] == ["reviewPrepared", "reviewIntentWillCommit"],
                    "FULL did not arise before the final intent commit acknowledgement")
            require(after == expected and attempt["storedIntentID"] == prior_intent,
                    "Failed FULL transaction changed durable intent or revision")
            require(attempt["returnedOutcomes"] == [{"ordinal": None, "role": "job", "status": "failed", "failure": "outOfSpace"}],
                    "Actual FULL did not return a non-success outOfSpace job result")
        expected = after
    require(cold["snapshot"] == expected == execution["snapshot"] and pressure["failedAttemptBefore"] == expected,
            "Cold reader disagrees with final FULL rollback/priming evidence")
    require(cold["itemStates"] == initial["itemStates"] and cold["availableActions"] == [action] and not cold["canUndo"],
            "FULL priming granted publication/reversal or lost the explicit recovery action")
    require(expected["revision"] == initial["snapshot"]["revision"] + pressure["primingAttemptCount"],
            "FULL priming undisclosed durable revision growth")


def source_snapshot(argument: Path | None) -> dict | None:
    """Read an exact root-produced staged baseline; never adopt arbitrary sources."""
    if argument is None:
        return None
    root = argument.absolute()
    prefix = "b03.3-index-sources-"
    require(root.parent == ROOT / ".build" and root.name.startswith(prefix)
            and str(uuid.UUID(root.name[len(prefix):])) == root.name[len(prefix):], "Production baseline is outside exact repository UUID namespace")
    def directory(path: Path, private: bool = True) -> None:
        require(path.resolve() == path, "Production baseline contains a symlink component")
        value = path.lstat()
        require(stat.S_ISDIR(value.st_mode) and value.st_uid == os.geteuid()
                and value.st_mode & (0o077 if private else 0o022) == 0, "Unsafe production baseline directory")
    def names(path: Path, maximum: int) -> set[str]:
        values: set[str] = set()
        with os.scandir(path) as entries:
            for entry in entries:
                require(len(values) < maximum, "Production baseline entry count exceeds bound")
                values.add(entry.name)
        return values
    def read(path: Path, maximum: int) -> bytes:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                    and before.st_mode & 0o077 == 0 and 0 <= before.st_size <= maximum, "Unsafe production baseline file")
            data = bytearray()
            while True:
                chunk = os.read(fd, min(65_536, maximum + 1 - len(data)))
                if not chunk: break
                data.extend(chunk)
                require(len(data) <= maximum, "Production baseline file exceeds bound")
            after, linked = os.fstat(fd), path.lstat()
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode, before.st_uid, before.st_nlink)
                    == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode, after.st_uid, after.st_nlink)
                    and (linked.st_dev, linked.st_ino) == (after.st_dev, after.st_ino), "Production baseline changed while reading")
            return bytes(data)
        finally:
            os.close(fd)
    directory(ROOT, private=False); directory(ROOT / ".build", private=False); directory(root)
    sources = root / "sources"; directory(sources)
    require(names(root, 3) == {"sources", ".qualification-source-baseline.json"}, "Unknown production baseline root entry")
    manifest_path = root / ".qualification-source-baseline.json"
    data = read(manifest_path, 65_536)
    manifest = json.loads(data)
    require(isinstance(manifest, dict) and manifest.get("schema") == 1
            and manifest.get("generator") == "mac-explorer-index-source-baseline"
            and manifest.get("parent") == "4becba12dd118ec8065164ef4c7c2a30caab4ee9"
            and manifest.get("source") == "B03.3 staged package baseline", "Unknown production baseline manifest")
    files = manifest.get("files")
    require(isinstance(files, dict) and 1 <= len(files) <= 128 and names(sources, 129) == set(files), "Production baseline file set changed")
    frozen = {manifest_path: hashlib.sha256(data).hexdigest()}
    total = 0
    for name, expected in sorted(files.items()):
        require(isinstance(name, str) and name.endswith(".swift") and name[:-6].replace("_", "").isalnum()
                and isinstance(expected, str) and len(expected) == 64 and all(char in "0123456789abcdef" for char in expected),
                "Invalid production baseline source identity")
        payload = read(sources / name, 4_194_304); total += len(payload)
        require(total <= 33_554_432 and hashlib.sha256(payload).hexdigest() == expected, "Production baseline source hash/budget mismatch")
        frozen[sources / name] = expected
    return {"root": root, "sources": sources, "manifest": manifest, "manifestBytes": data,
            "manifestSHA256": hashlib.sha256(data).hexdigest(), "frozen": frozen, "totalSourceBytes": total}


def bundle(qualification) -> Path:
    original = (qualification.run / "harness/GroupedCopyProductionWorker.swift").read_bytes()
    needle = b"@main private enum GroupedCopyProductionWorker"
    require(original.count(needle) == 1, "Frozen fixture helper entry point changed")
    snippet = (TOOLS / "GroupedCopyRecoveryProcessWorker.swift").read_bytes()
    runner = Path(__file__).read_bytes()
    for name, data in (("GroupedCopyRecoveryProcessWorker.swift", snippet), (Path(__file__).name, runner)):
        target = qualification.run / "harness" / name
        qualification_module.write(target, data)
        qualification.frozen[target] = qualification.report["harnessHashes"][name] = hashlib.sha256(data).hexdigest()
    transformed = original.replace(needle, b"private enum GroupedCopyProductionWorker") + b"\n" + snippet
    target = qualification.run / "harness/GroupedCopyRecoveryCombined.swift"
    qualification_module.write(target, transformed)
    qualification.frozen[target] = hashlib.sha256(transformed).hexdigest()
    qualification.report["recoverySourceTransformation"] = {
        "forwardWorkerOriginalSHA256": hashlib.sha256(original).hexdigest(),
        "recoverySnippetSHA256": hashlib.sha256(snippet).hexdigest(), "combinedSHA256": hashlib.sha256(transformed).hexdigest(),
        "operation": "Remove only frozen forward worker @main, concatenate snapshot recovery snippet"}
    return target


def execute(selected: list[dict], complete: bool, production_snapshot: Path | None = None) -> int:
    global qualification_module
    sys.dont_write_bytecode = True
    helper = TOOLS / "verify_grouped_copy_production.py"
    expected = hashlib.sha256(helper.read_bytes()).hexdigest()
    spec = importlib.util.spec_from_file_location("b03_forward_qualification", helper)
    require(spec is not None and spec.loader is not None, "Missing frozen forward harness definitions")
    qualification_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qualification_module)
    require(hashlib.sha256(helper.read_bytes()).hexdigest() == expected, "Forward helper changed while loading definitions")
    baseline = source_snapshot(production_snapshot)
    if baseline is not None:
        qualification_module.SOURCES = baseline["sources"]
    qualification = qualification_module.Qualification()
    qualification.report.update({"packet": "B03.3 production recovery/Undo", "passed": False,
        "recoveryExecutionQualified": False, "completeMatrix": complete, "plannedCaseCount": len(matrix_plan()),
        "selectedCaseCount": len(selected), "oracle": "Independent literal public/private slot match + exact durable per-member expectations"})
    try:
        if baseline is not None:
            qualification.frozen.update(baseline["frozen"])
            qualification.report["productionSourceBaseline"] = {"root": str(baseline["root"].relative_to(ROOT)),
                "manifestSHA256": baseline["manifestSHA256"], "manifest": baseline["manifest"], "totalSourceBytes": baseline["totalSourceBytes"]}
            target = qualification.run / "production-source-baseline.json"
            qualification_module.write(target, baseline["manifestBytes"])
            qualification.frozen[target] = baseline["manifestSHA256"]
        qualification.snapshot()
        if baseline is not None:
            require(qualification.report["sourceHashes"] == baseline["manifest"]["files"], "Copied production baseline differs from exact manifest")
        qualification_module.write(qualification.run / "recovery-semantic-plan.json", json.dumps(matrix_plan(), indent=2, sort_keys=True).encode())
        qualification_module.write(qualification.run / "recovery-selected-plan.json", json.dumps(selected, indent=2, sort_keys=True).encode())
        qualification.compile()
        combined = bundle(qualification)
        binary = qualification.run / "recovery-worker"
        qualification.command(["xcrun", "swiftc", "-O", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
            "-j", "2", "-num-threads", "2", "-module-cache-path", str(qualification.run / "modules"), "-o", str(binary),
            *[str(path) for path in sorted((qualification.run / "sources").glob("*.swift"))], str(combined)], "recovery-compile", timeout=600)
        qualification.frozen[binary] = qualification.report["recoveryBinarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()

        def invoke(phase: str, fixture: Path, record: str, action: str = "none", stage: str = "none",
                   mechanism: str = "none", member: int | None = None) -> dict:
            expected = 86 if mechanism == "process_crash" else (1 if phase == "review" and mechanism == "injected_error" else 0)
            data = qualification.command([str(binary), phase, str(fixture), record, action, stage, mechanism,
                                          "-" if member is None else str(member)], phase, expected=expected)
            value = json.loads(data)
            require(isinstance(value.get("pid"), int), "Missing recovery process receipt")
            if mechanism not in ("none", "sqlite_full"):
                require(value.get("targetReached") is True, "Recovery target checkpoint was never reached")
            if mechanism != "sqlite_full":
                require(value.get("stopIssued", False) == (mechanism == "cooperative_stop"), "Stop issuance receipt mismatch")
            require(value.get("acknowledgementLost", False) == (mechanism == "lost_acknowledgement"), "Lost acknowledgement hook did not fire exactly as requested")
            if mechanism == "cooperative_stop" and phase != "review":
                require(value.get("cancellationRequested") is True, "Stop did not reach returned operation cancellation state")
            if mechanism == "sqlite_full":
                codes = value.get("observedSQLiteFailureCodes", [])
                require(value.get("genuineSQLiteFullCount", 0) > 0 and any(code & 255 == 13 for code in codes),
                        "Real recovery SQLITE_FULL13 was not observed; generic outOfSpace/injected errors do not qualify")
                require(value.get("sqliteFailureCount") == len(codes) and not value.get("actionAchieved"), "FULL failure counter/action receipt invalid")
                require(not value.get("stopIssued") and not value.get("cancellationRequested"), "Final FULL was mislabeled as cooperative Stop")
            return value

        def cold_pair(fixture: Path, record: str, receipts: list[dict]) -> dict:
            cold, repeated = invoke("review", fixture, record), invoke("review", fixture, record)
            qualification.separate_processes(*receipts, cold, repeated)
            for field in ("snapshot", "availableActions", "canUndo", "itemStates", "protectionReasons"):
                require(cold[field] == repeated[field], "Repeated independent cold reader changed evidence")
            require(cold["namespaceUnchanged"] and cold["sourceUnchanged"] and repeated["noForwardAutoAction"], "Cold recovery reader mutated generated namespace")
            return cold

        for case in selected:
            qualification.report["activeCase"] = case
            fixture, seeded = qualification.new_fixture(case["count"])
            action = case.get("action", "undo")
            publish_through = case.get("publishedThrough", 0)
            seed_stage = "memberPublished" if action == "confirmCopies" else "groupSealed" if action == "finishReview" else "none"
            seed = qualification.invoke("forward", fixture, case.get("metadataPolicy", "strict"), seed_stage,
                str(publish_through // 16) if seed_stage == "memberPublished" else "0" if seed_stage == "groupSealed" else "-",
                str(publish_through) if seed_stage == "memberPublished" else "-", "process_crash" if seed_stage != "none" else "none", "-",
                expected=86 if seed_stage != "none" else 0)
            record = seed["recordID"]
            receipts = [seeded, seed]
            if action == "confirmUndo":
                receipts.append(invoke("undo", fixture, record, stage="reverseRenamed", mechanism="process_crash", member=case["count"] - 1))
            initial = invoke("review", fixture, record); receipts.append(initial)
            seed_oracle(case["count"], action, publish_through, initial)
            expected_source = initial["snapshot"]["sourceFingerprint"]
            kind = case["kind"]
            if kind in ("undo", "happy_undo", "confirmation", "storage_full"):
                stage, mechanism = case.get("stage", "none"), case.get("mechanism", "none")
                phase = "review" if stage == "reviewPrepared" else "undo" if action == "undo" else "action"
                execution = invoke(phase, fixture, record, action, stage, mechanism, case.get("member")); receipts.append(execution)
                cold = cold_pair(fixture, record, receipts)
                if kind in ("undo", "happy_undo"):
                    undo_oracle(case, cold, execution, initial)
                elif kind == "confirmation":
                    confirmation_oracle(case, initial, cold, execution)
                else:
                    require(cold["snapshot"]["sourceFingerprint"] == initial["snapshot"]["sourceFingerprint"], "FULL changed originals")
                    if action != "undo":
                        require(cold["snapshot"]["destinationFingerprint"] == initial["snapshot"]["destinationFingerprint"], "FULL confirmation mutated payload namespace")
                    # Every copied object remains exactly in one recorded public/private slot.
                    for row in cold["snapshot"]["members"]:
                        require((row["public"], row["private"]) in (("matched", "absent"), ("absent", "matched"), ("absent", "notDeclared")),
                                "FULL lost/changed a copied object or created ambiguous duplicate slots")
                    events = execution["events"]
                    require(bool(events), "FULL occurred without a reachable production recovery checkpoint")
                    failed_boundary = events[-1]
                    if action == "undo":
                        require(failed_boundary["stage"] in ("reverseIntentWillCommit", "reverseWillRecordOutcome", "reverseTerminalWillCommit"),
                                "FULL did not arise at an actual reverse persistence boundary")
                        inferred = {**case, "stage": failed_boundary["stage"]}
                        if failed_boundary["member"] != "-": inferred["member"] = int(failed_boundary["member"])
                        undo_oracle(inferred, cold, execution, initial)
                    else:
                        require(failed_boundary["stage"] in ("reviewIntentWillCommit", "reviewWillRecordOutcomes"), "FULL did not arise at confirmation persistence boundary")
                        confirmation_full_oracle(initial, cold, execution, action)
            elif kind == "authority":
                execution = invoke("authority", fixture, record, case["variant"]); receipts.append(execution)
                cold = cold_pair(fixture, record, receipts)
                require(execution["rejectionUnchanged"] and execution["disposition"] == "failed", "Stale/foreign/reused review caused mutation")
                require(cold["snapshot"] == execution["snapshot"], "Stale refusal changed on cold reopen")
            elif kind == "protected":
                target = 0 if case["variant"] == "public_corrupt" else 1
                changed = invoke("change", fixture, record, case["variant"], member=target); receipts.append(changed)
                protected = invoke("review", fixture, record); receipts.append(protected)
                require(protected["itemStates"][target] == "protected", "Corrupt/stale inventory was granted recovery authority")
                require(not protected["canUndo"] and "finishReview" not in protected["availableActions"], "Protected job was allowed Undo/closure")
                execution = protected
                if "confirmCopies" in protected["availableActions"]:
                    execution = invoke("action", fixture, record, "confirmCopies"); receipts.append(execution)
                    require(execution["confirmationNamespaceUnchanged"] and all(role == "job" for role in execution["returnedOutcomeRoles"]),
                            "Partial confirmation mutated payload or reported fresh copies")
                cold = cold_pair(fixture, record, receipts)
                require(cold["snapshot"]["destinationFingerprint"] == changed["snapshot"]["destinationFingerprint"], "Protected recovery mutated deliberate fixture alteration")
                require(cold["itemStates"][target] == "protected", "Partial confirmation dismissed protected member")
            elif kind in ("partial_confirmation", "original_changed"):
                if kind == "original_changed":
                    changed = invoke("change", fixture, record, case["variant"], member=0); receipts.append(changed)
                    expected_source = changed["snapshot"]["sourceFingerprint"]
                elif "protectMember" in case:
                    changed = invoke("change", fixture, record, "private_corrupt", member=case["protectMember"]); receipts.append(changed)
                else:
                    changed = {"snapshot": initial["snapshot"]}
                prepared = invoke("review", fixture, record); receipts.append(prepared)
                execution = invoke("undo" if action == "undo" else "action", fixture, record, action); receipts.append(execution)
                cold = cold_pair(fixture, record, receipts)
                require(execution["disposition"] == "succeeded" and execution["sourceUnchanged"], "Explicit recovery depended on removed/changed original or failed valid subset")
                require(cold["snapshot"]["sourceFingerprint"] == changed["snapshot"]["sourceFingerprint"], "Recovery rewrote original source after deliberate change")
                if action == "undo":
                    undo_oracle({"count": case["count"]}, cold, execution, prepared)
                else:
                    settled_confirmation_oracle(prepared, cold, execution, action, case.get("protectMember"))
            elif kind == "explicit_retry":
                interrupted = invoke("undo", fixture, record, stage=case["stage"], mechanism="process_crash", member=case["member"]); receipts.append(interrupted)
                pending = invoke("review", fixture, record); receipts.append(pending)
                undo_oracle({**case, "mechanism": "process_crash"}, pending, interrupted, initial)
                if case["stage"] == "reverseIntentCommitted":
                    execution = invoke("undo", fixture, record); receipts.append(execution)
                else:
                    require(pending["availableActions"] == ["confirmUndo"], "Private unconfirmed reversal did not require explicit confirmation")
                    confirmed = invoke("action", fixture, record, "confirmUndo"); receipts.append(confirmed)
                    require(confirmed["confirmationNamespaceUnchanged"], "Confirm Undo moved an already private object again")
                    execution = invoke("undo", fixture, record); receipts.append(execution)
                cold = cold_pair(fixture, record, receipts)
                exact_members(cold["snapshot"], [member("undone", "absent", "matched") for _ in range(33)])
                require(cold["snapshot"]["state"] == "undone" and not cold["canUndo"] and not cold["availableActions"], "Explicit retry did not complete exact remaining copies")
                require(execution["returnedSuccessCount"] == (17 if case["stage"] == "reverseIntentCommitted" else 16), "Explicit retry repeated an already acknowledged reversal")
                remaining = range(16 if case["stage"] == "reverseIntentCommitted" else 15, -1, -1)
                require(execution["returnedOutcomes"] == [{"ordinal": ordinal, "role": "transfer", "status": "succeeded", "failure": "none"}
                                                          for ordinal in remaining], "Explicit retry returned wrong member associations")
            else:
                raise RuntimeError("Unmodelled recovery case kind")
            require(cold["snapshot"]["sourceFingerprint"] == expected_source, "Recovery changed original namespace across a process interruption")
            # An outcome can be durable despite a failed/lost acknowledgement.
            # Keep this independent cold fact separate from the worker's return.
            if action == "undo":
                selected_ordinals = [row["ordinal"] for row in initial["snapshot"]["members"] if row["phase"] in ("published", "reverseIntent")]
                durable_achieved = bool(selected_ordinals) and all(cold["snapshot"]["members"][index]["phase"] == "undone" for index in selected_ordinals)
            elif action in ("confirmCopies", "confirmUndo"):
                selected_ordinals = eligible_members(initial["snapshot"], action)
                durable_achieved = bool(selected_ordinals) and all(cold["snapshot"]["members"][index]["phase"] ==
                    ("published" if action == "confirmCopies" else "undone") for index in selected_ordinals)
            else:
                durable_achieved = cold["snapshot"]["state"] in ("completed", "stoppedSettled", "undone")
            if kind == "authority": durable_achieved = False  # The explicitly rejected attempt itself performed nothing.
            qualification.report["cases"].append({"case": case, "fixture": str(fixture.relative_to(qualification.run)),
                "receipts": receipts, "execution": execution, "cold": cold, "independentOraclePassed": True,
                "acknowledgedActionAchieved": execution.get("acknowledgedActionAchieved", False),
                "durableRequestedActionAchieved": durable_achieved})
        qualification.report.pop("activeCase", None)
        qualification.report["selectedCasesPassed"] = True
        qualification.report["passed"] = complete
        qualification.report["recoveryExecutionQualified"] = complete
        if not complete:
            qualification.report["unexercised"].append("Remaining complete process matrix; shard success is partial evidence")
    except Exception as error:
        qualification.report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        qualification_module.write(qualification.run / "report.json", json.dumps(qualification.report, indent=2, sort_keys=True).encode())
    print(json.dumps({"passed": qualification.report["passed"], "selectedCasesPassed": qualification.report.get("selectedCasesPassed", False),
                      "completeMatrix": complete, "report": str(qualification.run / "report.json")}))
    return 0 if qualification.report.get("selectedCasesPassed") else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--describe-plan", action="store_true")
    parser.add_argument("--kind", choices=sorted({case["kind"] for case in matrix_plan()}))
    parser.add_argument("--member", type=int, choices=range(33))
    parser.add_argument("--stage")
    parser.add_argument("--mechanism", choices=("cooperative_stop", "injected_error", "process_crash", "lost_acknowledgement", "sqlite_full"))
    parser.add_argument("--production-source-snapshot", type=Path)
    args = parser.parse_args()
    planned = matrix_plan()
    selected = [case for case in planned if (args.kind is None or case["kind"] == args.kind)
                and (args.member is None or case.get("member") == args.member)
                and (args.stage is None or case.get("stage") == args.stage)
                and (args.mechanism is None or case.get("mechanism") == args.mechanism)]
    if args.describe_plan:
        print(json.dumps({"executionReviewGate": PRODUCTION_API_AND_ORACLE_REVIEWED, "selectedCases": selected,
                          "totalRequired": len(planned)}, indent=2))
        return 0
    if not PRODUCTION_API_AND_ORACLE_REVIEWED:
        print(json.dumps({"executed": False, "reason": "awaiting_root_review_and_source_freeze"}))
        return 2
    require(bool(selected), "No matching process cases")
    return execute(selected, complete=len(selected) == len(planned), production_snapshot=args.production_source_snapshot)


if __name__ == "__main__":
    raise SystemExit(main())
