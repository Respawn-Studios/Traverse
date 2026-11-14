#!/usr/bin/env python3
"""Reinventory B06 including newly generated native-analysis evidence.

Unlike frozen earlier receipts, this includes new analysis-* native fixtures and
new ui-* evidence roots after the preceding checkpoint. It never removes data.
Normal native app products retain their existing development-build scope; the
separate isolated benchmark tooling envelope is inventoried as before.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compact_resources", HERE / "compact/qualify.py")
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)
from packet import REPO, BASE, LIMITS, anchored, directory_fd, inventory, put

# Owner-approved 18 October: 8 MiB for new screenshots and small JSON receipts
# only. Existing failures remain charged to the original aggregate allowance.
# Corpus entry/data/allocation and isolated-tooling limits are unchanged.
EXTRA_EVIDENCE_BYTES = 24 << 20
PRE_EXTENSION_UI = "ui-20261017T193513.860162Z"
# Known analysis-only run: up to seven PNGs, three JSON reports and the root.
# A twelfth slot is spare. General native reuse keeps the larger reservation.
ANALYSIS_REUSE_ENTRIES = 12
# Owner-approved 18 October: preceding 128 slots, then 256 for the consolidated
# full-scope packet,64 final entries, then8 shipped-helper and128 conditional
# catalog entries. Source corpus generation remains frozen.
#128 more tiny evidence slots use the owner's broad development-limit authority
# for policy activation/control gates; byte/corpus/tooling limits are unchanged.
#128 additional small entries qualify the reviewed filtered-result interface,
# provenance refusals and native chart/scope regression. Source/byte caps stay.
# Owner-authorized practical development headroom:256 tiny retained entries
# for committed-prefix comparisons/failures; no new source corpus or byte cap.
# Owner-approved native dimensional-chart qualification packet18 October:
#128 additional tiny retained evidence entries; all byte/corpus limits unchanged.
# Owner-approved final native/classification/capture follow-up:32 tiny entries.
# Owner-approved subsequent Properties/full-analysis integration packet:64 entries.
# 19 October: use the owner's prior development-limit authority for 256 tiny
# browser/accounting/performance receipts and 8 MiB more image/JSON evidence.
# The owner subsequently explicitly confirmed the SAME increment; do not double it.
# No new source corpus, personal scan scope, store, memory or tooling allowance.
#19 October overnight routine decision under the owner's development-limit
# authority:128 small entries for native card/sidewall regressions, the numeric
# admission profile and final activation receipts. No new source corpus or byte
# allowance; every failed diagnostic and store remains charged and preserved.
#19 October continued overnight run: owner delegates implementation decisions,
# including major choices, for B06.2 and potential B06.3. Reserve512 small retained
# controls/receipts once; no source-corpus or byte/tooling limit changes.
#19 October owner-return packet:256 consolidated small entries for selected
# Trash native acceptance and the separately frozen cache comparison. No source
# corpus expansion, recycled evidence or byte/tooling change.
EXTRA_TEST_ENTRIES = 128 + 256 + 64 + 8 + 128 + 128 + 128 + 256 + 128 + 32 + 64 + 256 + 128 + 512 + 256
#23 October delegated continued development: reconcile the inherited304-entry /
#32,353-byte overage and admit one directory-heavy tiny control. Original source
#corpus and data ceiling stay frozen. Preserve every failure. See the verified
#open-identity comparison packet;8MiB more receipt credit is included above.
EXTRA_TEST_ENTRIES += 16_384
CONTROL_LOGICAL_BYTES = 32 << 20
# Owner's larger development-limit authority18 October: retain original source
# corpus and old32MiB sessions; allow8GiB generated SQLite /2GiB per new session,
#12GiB combined allocation and3GiB isolated tooling. Failed stores stay charged.
# Runtime personal-analysis stores use their separately bounded2GiB/8GiB pool.
SQLITE_STORE_BYTES = 8 << 30
SQLITE_SESSION_BYTES = 32 << 20
SQLITE_STORE_ROOT = BASE / "paged-result-stores-20261018"
FULL_SCOPE_STORE_ROOT = BASE / "full-scope-stores-20261018"
FULL_SCOPE_SESSION_BYTES = 2 << 30
COMBINED_ALLOCATION_BYTES = 12 << 30
TOOLING_BYTES = 3 << 30
FREE_SPACE_FLOOR = 8 << 30
SQLITE_NAMES = {"result.sqlite", "result.sqlite-journal", "result.sqlite-wal", "result.sqlite-shm"}
#19 October selected-Trash packet: generated private operation state needs its
# own1MiB logical allowance, not credit against the frozen analyzer corpus.
# This is quota accounting only, never recovery/cleanup authority.
SELECTED_TRASH_STATE_BYTES = 1 << 20


def effective_limits() -> dict:
    return dict(entries=LIMITS["entries"] + EXTRA_TEST_ENTRIES, logical=LIMITS["logical"] + CONTROL_LOGICAL_BYTES,
                allocated=COMBINED_ALLOCATION_BYTES, tooling=TOOLING_BYTES)


def evidence_credit(roots: list[Path]) -> int:
    total = 0
    for root in roots:
        anchored(root)
        for path in root.iterdir():
            metadata = path.lstat()
            import stat
            if not stat.S_ISREG(metadata.st_mode): continue
            # The frozen two-reader receipt retains all17 correctness/timing/
            # Stop/quota cases (~70KiB). Owner-delegated evidence decision:
            # this exact generated numeric-receipt namespace gets128KiB/file;
            # the shared16MiB supplement and every other file ceiling stay.
            large_numeric = re.fullmatch(r"prefetch-[0-9a-f]{32}\.json", path.name) is not None
            ceiling = (131072 if large_numeric else 65536) if path.suffix == ".json" else 1 << 20 if path.suffix.lower() in (".png", ".jpg", ".jpeg") else 0
            if 0 < metadata.st_size <= ceiling: total += metadata.st_size
    return total


def sqlite_session_credit(entries, *, limit=SQLITE_SESSION_BYTES) -> int:
    """Pure admission facts only; this is not store ownership or cleanup proof."""
    import stat
    total = 0
    for path in entries:
        value = path.lstat()
        if path.name in SQLITE_NAMES:
            if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
                    or value.st_uid != os.geteuid() or value.st_mode & 0o077):
                raise ValueError("Uncertain generated SQLite file receives no allowance")
            total += value.st_size
    if total > limit: raise ValueError("Generated SQLite session exceeds its admitted limit")
    return total


def sqlite_credit() -> tuple[int, int]:
    import stat
    total = sessions = 0
    for container, limit in [(SQLITE_STORE_ROOT, SQLITE_SESSION_BYTES),
                             (FULL_SCOPE_STORE_ROOT, FULL_SCOPE_SESSION_BYTES)]:
        if not container.exists(): continue
        anchored(container)
        for root in container.iterdir():
            value = root.lstat()
            if container == FULL_SCOPE_STORE_ROOT and full_scope_pool_lock(root.name, value):
                continue  # Counted by inventory; receives no database credit.
            if (not re.fullmatch(r"session-[0-9a-f]{32}", root.name)
                    or not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid()
                    or value.st_mode & 0o077):
                raise ValueError("Uncertain generated SQLite session root")
            anchored(root)
            entries = list(root.iterdir())
            if container == FULL_SCOPE_STORE_ROOT:
                session_bytes = 0
                for path in entries:
                    observed = path.lstat()
                    if (not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1
                            or observed.st_uid != os.geteuid() or observed.st_mode & 0o077):
                        raise ValueError("Uncertain full-scope session file")
                    session_bytes += observed.st_size
                if session_bytes > limit: raise ValueError("Full-scope session exceeds its allowance")
            total += sqlite_session_credit(entries, limit=limit); sessions += 1
    if total > SQLITE_STORE_BYTES: raise ValueError("Generated SQLite allowance exceeds the development envelope")
    return total, sessions


def selected_trash_state_credit() -> int:
    import stat
    total = entries = 0
    names = {".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2", ".mac-explorer-journal-v1",
             "operations-v2.sqlite", "operations-v2.sqlite-journal"}
    for fixture in BASE.iterdir():
        if not re.fullmatch(r"location-fixture-[0-9a-f]{32}", fixture.name): continue
        state = fixture / "PrivateState"
        if not os.path.lexists(state): continue
        anchored(fixture); anchored(state)
        value = state.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or value.st_mode & 0o077:
            raise ValueError("Uncertain selected-Trash test state")
        children = list(state.iterdir())
        if len(children) != 1 or children[0].name != "operation-recovery":
            raise ValueError("Unrecognized selected-Trash test state")
        history = children[0]; anchored(history); value = history.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or value.st_mode & 0o077:
            raise ValueError("Uncertain selected-Trash history")
        for path in history.iterdir():
            value = path.lstat(); entries += 1
            if path.name not in names or not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_uid != os.geteuid() or value.st_mode & 0o077:
                raise ValueError("Uncertain selected-Trash state file")
            total += value.st_size
            if total > SELECTED_TRASH_STATE_BYTES or entries > 128:
                raise ValueError("Selected-Trash state allowance exhausted")
    return total


def full_scope_pool_lock(name, value) -> bool:
    """Only the native session pool's empty private lock, not an evidence bypass."""
    import stat
    if name != "pool.lock": return False
    if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
            or value.st_uid != os.geteuid() or value.st_mode & 0o7777 != 0o600
            or value.st_size != 0):
        raise ValueError("Uncertain full-scope pool lock")
    return True


def full_scope_inventory(root: Path) -> dict:
    """Count the new store envelope without changing frozen corpus scanners."""
    import stat
    anchored(root)
    total = dict(entries=0, logical=0, allocated=0)
    with os.scandir(root) as sessions:
        for session in sessions:
            observed = session.stat(follow_symlinks=False)
            if full_scope_pool_lock(session.name, observed):
                total["entries"] += 1; total["allocated"] += observed.st_blocks * 512
                continue
            if (not re.fullmatch(r"session-[0-9a-f]{32}", session.name)
                    or not stat.S_ISDIR(observed.st_mode) or observed.st_uid != os.geteuid()
                    or observed.st_mode & 0o077):
                raise ValueError("Uncertain full-scope container entry")
            total["entries"] += 1; total["allocated"] += observed.st_blocks * 512
            if total["entries"] > effective_limits()["entries"]:
                raise ValueError("Full-scope store entry allowance exceeded")
            descriptor = directory_fd(root / session.name)
            try:
                held = os.fstat(descriptor)
                if (held.st_dev, held.st_ino) != (observed.st_dev, observed.st_ino):
                    raise ValueError("Full-scope session changed")
                with os.scandir(descriptor) as files:
                    for entry in files:
                        value = entry.stat(follow_symlinks=False)
                        if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
                                or value.st_uid != os.geteuid() or value.st_mode & 0o077):
                            raise ValueError("Uncertain full-scope session file")
                        total["entries"] += 1; total["logical"] += value.st_size
                        total["allocated"] += value.st_blocks * 512
                        if (total["entries"] > effective_limits()["entries"]
                                or total["logical"] > SQLITE_STORE_BYTES + EXTRA_EVIDENCE_BYTES
                                or total["allocated"] > COMBINED_ALLOCATION_BYTES):
                            raise ValueError("Full-scope store inventory exceeds admission")
            finally: os.close(descriptor)
    return total


def base_inventory() -> dict:
    """Keep frozen per-corpus scanners unchanged; combine reviewed supplements.

    The old inspector rejects the entire BASE at its original byte ceiling
    before it could subtract the new, separately allowed store bytes. Walk each
    direct child with that same strict scanner, then apply aggregate admission
    (including evidence/store eligibility) in inspect(). No child is excluded.
    """
    import stat
    anchored(BASE)
    total = dict(entries=0, logical=0, allocated=0)
    fd = directory_fd(BASE)
    try:
        original = os.fstat(fd)
        with os.scandir(fd) as children:
            for child in children:
                value = child.stat(follow_symlinks=False)
                total["entries"] += 1; total["allocated"] += value.st_blocks * 512
                if stat.S_ISDIR(value.st_mode):
                    branch = (full_scope_inventory(BASE / child.name)
                        if BASE / child.name == FULL_SCOPE_STORE_ROOT else inventory(BASE / child.name))
                    for key in total: total[key] += branch[key]
                elif stat.S_ISREG(value.st_mode): total["logical"] += value.st_size
                if (total["entries"] > effective_limits()["entries"]
                    or total["logical"] > effective_limits()["logical"] + EXTRA_EVIDENCE_BYTES + SQLITE_STORE_BYTES
                    or total["allocated"] > COMBINED_ALLOCATION_BYTES):
                    raise ValueError("B06 combined supplements exceed admission")
        current = os.stat(BASE, follow_symlinks=False)
        if (current.st_dev,current.st_ino) != (original.st_dev,original.st_ino):
            raise ValueError("B06 inventory root changed")
    finally: os.close(fd)
    return total


def current_resources() -> dict:
    preceding = json.loads(resources.PRECEDING.read_text())
    base = base_inventory(); total = base.copy()
    for name in preceding["supplement_roots"]:
        root = REPO / name; value = inventory(root)
        value["entries"] += 1; value["allocated"] += root.lstat().st_blocks * 512
        for key in total: total[key] += value[key]
    tooling = sum((base if REPO / name == BASE else inventory(REPO / name))["allocated"]
        + (REPO / name).lstat().st_blocks * 512 for name in preceding["conservative_tooling_union"])
    # Earlier envelopes conservatively included the whole BASE. Keep those old
    # charges, but count the newly admitted full-scope result stores as evidence,
    # not compiler/build products. Every byte remains in combined allocation.
    if FULL_SCOPE_STORE_ROOT.exists() and str(BASE.relative_to(REPO)) in preceding["conservative_tooling_union"]:
        tooling -= full_scope_inventory(FULL_SCOPE_STORE_ROOT)["allocated"] + FULL_SCOPE_STORE_ROOT.lstat().st_blocks * 512
    fs = os.statvfs(BASE)
    return dict(combined=total,tooling_allocated=tooling,cache=resources.allocation(resources.CACHE),
        free=fs.f_bavail*fs.f_frsize)


def inspect() -> dict:
    old = json.loads(resources.PRECEDING.read_text())
    before = current_resources()
    known = set(old["supplement_roots"])
    latest = max(p for p in known if p.startswith(".build/evidence/ui-"))
    added = sorted(p for p in (REPO / ".build/test-fixtures").glob("analysis-*")
                   if str(p.relative_to(REPO)) not in known)
    added += sorted(p for p in (REPO / ".build/evidence").glob("ui-*")
                    if re.fullmatch(r"ui-\d{8}T\d{6}\.\d+Z", p.name)
                    and str(p.relative_to(REPO)) > latest and str(p.relative_to(REPO)) not in known)
    combined = before["combined"].copy()
    for root in added:
        anchored(root)
        value = inventory(root)
        value["entries"] += 1
        value["allocated"] += root.lstat().st_blocks * 512
        for k in combined: combined[k] += value[k]
    cache_original = json.loads((BASE / "model-profile-run-daa11eb3e4374ac2916faea59705ec80/receipt.json").read_text())["after_cache"]["allocated"]
    isolated = REPO / ".build/b06-consumer-profile-build"
    anchored(isolated)
    tooling = before["tooling_allocated"] + inventory(isolated)["allocated"] + isolated.lstat().st_blocks * 512
    tooling += max(0, before["cache"]["allocated"] - cache_original)
    eligible = [p for p in added if p.parent == REPO / ".build/evidence" and p.name > PRE_EXTENSION_UI]
    extension = BASE / "evidence-extension-20261018"
    if extension.exists(): eligible.append(extension)
    credit = evidence_credit(eligible)
    store_credit, store_sessions = sqlite_credit()
    selected_state = selected_trash_state_credit()
    base_charge = dict(combined, logical=combined["logical"] - credit - store_credit - selected_state)
    return dict(schema=1, combined=combined, original_allowance_charge=base_charge,
                qualification_control_supplement=dict(bytes=CONTROL_LOGICAL_BYTES,
                    frozen_source_corpus_limit=LIMITS["logical"],frozen_source_corpus_entries=LIMITS["entries"]),
                selected_trash_state=dict(approved_bytes=SELECTED_TRASH_STATE_BYTES, eligible_logical=selected_state,
                    remaining_bytes=SELECTED_TRASH_STATE_BYTES-selected_state),
                extra_evidence=dict(approved_bytes=EXTRA_EVIDENCE_BYTES, eligible_logical=credit,
                                    remaining_bytes=max(0, EXTRA_EVIDENCE_BYTES - credit)),
                sqlite_qualification=dict(approved_bytes=SQLITE_STORE_BYTES, per_session_bytes=SQLITE_SESSION_BYTES,
                    full_scope_per_session_bytes=FULL_SCOPE_SESSION_BYTES,
                    eligible_logical=store_credit, remaining_bytes=SQLITE_STORE_BYTES-store_credit, sessions=store_sessions),
                isolated_tooling_allocated=tooling,
                additional_native_roots=[str(p.relative_to(REPO)) for p in added], free=before["free"],
                limits=effective_limits(), extra_test_entries=EXTRA_TEST_ENTRIES,
                passed=credit <= EXTRA_EVIDENCE_BYTES and all(base_charge[k] <= effective_limits()[k] for k in base_charge)
                       and tooling <= TOOLING_BYTES and before["free"] >= FREE_SPACE_FLOOR)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--admit-native", action="store_true", help="Also reserve 210 entries / 1 MiB logical / 2 MiB allocated for one focused run.")
    parser.add_argument("--admit-native-reuse", action="store_true", help="Reserve 32 evidence entries / 1 MiB logical / 2 MiB allocated; the app must reuse an owned generated fixture.")
    parser.add_argument("--admit-analysis-reuse", action="store_true", help="Reserve 12 entries for the known analysis-only capture list, 1 MiB logical / 2 MiB allocated, using an existing fixture.")
    parser.add_argument("--admit-paged", action="store_true", help="Reserve 12 entries, 64 KiB original bytes, 56 MiB generated stores and 128 MiB isolated tooling; one writer at a time.")
    parser.add_argument("--admit-full-scope", action="store_true", help="Reserve 12 entries, 64 KiB original bytes, one 512 MiB generated store and 128 MiB tooling under the accepted full-scope packet.")
    args = parser.parse_args()
    report = inspect()
    if args.admit_full_scope:
        if args.admit_paged or args.admit_native or args.admit_native_reuse or args.admit_analysis_reuse:
            raise ValueError("Choose one projection")
        report["full_scope_projection"] = dict(entries=12, original_logical=65536,
            stores=FULL_SCOPE_SESSION_BYTES, allocated=FULL_SCOPE_SESSION_BYTES + (2 << 20), tooling=128 << 20)
        report["passed"] &= (report["combined"]["entries"] + 12 <= report["limits"]["entries"]
            and report["original_allowance_charge"]["logical"] + 65536 <= effective_limits()["logical"]
            and report["sqlite_qualification"]["remaining_bytes"] >= FULL_SCOPE_SESSION_BYTES
            and report["combined"]["allocated"] + FULL_SCOPE_SESSION_BYTES + (2 << 20) <= COMBINED_ALLOCATION_BYTES
            and report["isolated_tooling_allocated"] + (128 << 20) <= TOOLING_BYTES
            and report["free"] - FULL_SCOPE_SESSION_BYTES - (130 << 20) >= FREE_SPACE_FLOOR)
    if args.admit_paged:
        if args.admit_native or args.admit_native_reuse or args.admit_analysis_reuse:
            raise ValueError("Choose one projection")
        report["paged_projection"] = dict(entries=12, original_logical=65536, stores=56 << 20,
            allocated=56 << 20, tooling=128 << 20)
        report["passed"] &= (report["combined"]["entries"] + 12 <= report["limits"]["entries"]
            and report["original_allowance_charge"]["logical"] + 65536 <= effective_limits()["logical"]
            and report["sqlite_qualification"]["remaining_bytes"] >= 56 << 20
            and report["combined"]["allocated"] + (56 << 20) <= COMBINED_ALLOCATION_BYTES
            and report["isolated_tooling_allocated"] + (184 << 20) <= TOOLING_BYTES
            and report["free"] - (184 << 20) >= FREE_SPACE_FLOOR)
    projection = dict(entries=210, logical=1 << 20, allocated=2 << 20)
    if sum((args.admit_native, args.admit_native_reuse, args.admit_analysis_reuse)) > 1: raise ValueError("Choose one native projection")
    reuse = args.admit_native_reuse or args.admit_analysis_reuse
    if reuse: projection["entries"] = ANALYSIS_REUSE_ENTRIES if args.admit_analysis_reuse else 32
    if args.admit_native or reuse:
        report["native_projection"] = projection
        # Reuse mode creates evidence only; it may consume the reviewed extra
        # allowance. New-fixture mode keeps its original stricter admission.
        charge = report["original_allowance_charge"] if reuse else report["combined"]
        report["passed"] &= all(charge[k] + projection[k] <= report["limits"][k]
            + (report["extra_evidence"]["remaining_bytes"] if reuse and k == "logical" else 0)
            for k in projection)
        report["passed"] &= report["free"] - projection["allocated"] >= FREE_SPACE_FLOOR
    print(json.dumps(report, indent=2))
    if not report["passed"]: raise SystemExit("B06 resource admission refused; preserved evidence is not removed")


if __name__ == "__main__": main()
