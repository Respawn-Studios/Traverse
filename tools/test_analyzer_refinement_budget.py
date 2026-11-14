#!/usr/bin/env python3
"""Pure metadata controls for the reviewed evidence-only allowance.

No test artifacts or file bodies are created; fake directory facts exercise
credit eligibility. Existing fixture/evidence and tooling inventories remain.
"""
import importlib.util
import os
from pathlib import Path
import stat
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent / "analyzer"))
import refinement_budget as budget


class Entry:
    def __init__(self, suffix, size, mode=stat.S_IFREG, *, name="", links=1, uid=None):
        self.suffix = suffix; self.size = size; self.mode = mode; self.name = name
        self.links = links; self.uid = os.geteuid() if uid is None else uid
    def lstat(self): return SimpleNamespace(st_mode=self.mode, st_size=self.size,
        st_nlink=self.links, st_uid=self.uid)


class Root:
    def __init__(self, *entries): self.entries = entries
    def iterdir(self): return iter(self.entries)


class EvidenceCreditTests(unittest.TestCase):
    def credit(self, *entries):
        with patch.object(budget, "anchored", lambda root: None):
            return budget.evidence_credit([Root(*entries)])

    def test_only_bounded_screenshots_and_small_receipts_receive_credit(self):
        self.assertEqual(self.credit(Entry(".png", 100_000), Entry(".jpg", 20_000),
            Entry(".json", 1_000), Entry(".sqlite", 50_000), Entry(".html", 100), Entry("", 999)), 121_000)

    def test_large_json_and_images_are_not_relabelled_as_receipts(self):
        self.assertEqual(self.credit(Entry(".json", 65_537), Entry(".png", (1 << 20) + 1)), 0)
        self.assertEqual(self.credit(Entry(".json", 65_536), Entry(".png", 1 << 20)), 65_536 + (1 << 20))

    def test_symlinks_directories_and_empty_placeholders_get_no_credit(self):
        self.assertEqual(self.credit(Entry(".png", 100, stat.S_IFLNK),
            Entry(".json", 100, stat.S_IFDIR), Entry(".json", 0)), 0)

    def test_credit_never_changes_the_fixture_and_tooling_limits(self):
        self.assertEqual(budget.EXTRA_EVIDENCE_BYTES, 16 << 20)
        self.assertEqual(budget.LIMITS, {"entries": 220_000, "logical": 1 << 30, "allocated": 2 << 30})
        self.assertEqual(budget.PRE_EXTENSION_UI, "ui-20261017T193513.860162Z")

    def test_analysis_reuse_reserves_the_known_output_set_without_new_fixture_slots(self):
        self.assertGreaterEqual(budget.ANALYSIS_REUSE_ENTRIES, 7 + 3 + 1)
        self.assertLess(budget.ANALYSIS_REUSE_ENTRIES, 32)

    def test_full_scope_amendment_preserves_original_corpus_and_legacy_session_limits(self):
        self.assertEqual(budget.effective_limits(), {"entries": 222472, "logical": 1 << 30,
            "allocated": 12 << 30, "tooling": 3 << 30})
        self.assertEqual(budget.LIMITS["entries"], 220000)
        self.assertEqual(budget.SQLITE_SESSION_BYTES, 32 << 20)
        self.assertEqual(budget.FREE_SPACE_FLOOR, 8 << 30)

    def test_sqlite_and_sidecars_share_one_session_limit(self):
        self.assertEqual(budget.sqlite_session_credit([Entry(".sqlite", 30 << 20, name="result.sqlite"),
            Entry("", 2 << 20, name="result.sqlite-journal")]), 32 << 20)
        with self.assertRaises(ValueError):
            budget.sqlite_session_credit([Entry(".sqlite", 32 << 20, name="result.sqlite"),
                Entry("", 1, name="result.sqlite-wal")])

    def test_sqlite_credit_never_includes_arbitrary_files(self):
        self.assertEqual(budget.sqlite_session_credit([Entry(".sqlite", 100, name="other.sqlite"),
            Entry(".json", 100, name="owner.json"), Entry(".sqlite", 25, name="result.sqlite")]), 25)

    def test_sqlite_uncertain_identity_mode_and_links_refuse_admission(self):
        for value in [Entry("", 5, stat.S_IFLNK, name="result.sqlite"),
            Entry("", 5, stat.S_IFREG | 0o644, name="result.sqlite"),
            Entry("", 5, name="result.sqlite", links=2), Entry("", 5, name="result.sqlite", uid=os.geteuid()+1)]:
            with self.assertRaises(ValueError): budget.sqlite_session_credit([value])

    def test_store_allowance_is_separate_from_source_and_evidence_bytes(self):
        self.assertEqual((budget.SQLITE_STORE_BYTES, budget.SQLITE_SESSION_BYTES), (8 << 30,32 << 20))
        self.assertEqual(budget.EXTRA_EVIDENCE_BYTES,16 << 20)
        self.assertEqual(budget.effective_limits()["logical"], 1 << 30)

    def test_large_session_is_admitted_only_with_explicit_full_scope_limit(self):
        files = [Entry("", (2 << 30) - (12 << 20), name="result.sqlite"),
                 Entry("", 12 << 20, name="result.sqlite-journal")]
        with self.assertRaises(ValueError): budget.sqlite_session_credit(files)
        self.assertEqual(budget.sqlite_session_credit(files, limit=budget.FULL_SCOPE_SESSION_BYTES), 2 << 30)
        with self.assertRaises(ValueError):
            budget.sqlite_session_credit(files + [Entry("", 1, name="result.sqlite-wal")],
                limit=budget.FULL_SCOPE_SESSION_BYTES)

    def test_native_pool_lock_is_empty_private_and_never_database_credit(self):
        valid = Entry("", 0, stat.S_IFREG | 0o600, name="pool.lock")
        self.assertTrue(budget.full_scope_pool_lock(valid.name, valid.lstat()))
        self.assertFalse(budget.full_scope_pool_lock("another.lock", valid.lstat()))
        self.assertEqual(budget.sqlite_session_credit([valid]), 0)
        for bad in [Entry("",1,stat.S_IFREG|0o600), Entry("",0,stat.S_IFREG|0o644),
                    Entry("",0,stat.S_IFLNK|0o600), Entry("",0,stat.S_IFREG|0o600,links=2),
                    Entry("",0,stat.S_IFREG|0o600,uid=os.geteuid()+1)]:
            with self.assertRaises(ValueError): budget.full_scope_pool_lock("pool.lock",bad.lstat())

    def test_selected_trash_state_credit_is_bounded_and_not_source_or_catalog_credit(self):
        class Node(Entry):
            def __init__(self, name, *children, mode=stat.S_IFDIR|0o700, size=0, links=1):
                super().__init__("", size, mode, name=name, links=links); self.children = children
            def __truediv__(self, name): return next(n for n in self.children if n.name == name)
            def iterdir(self): return iter(self.children)
        def credit(file):
            history = Node('operation-recovery', file)
            base = Node('base', Node('location-fixture-'+'a'*32, Node('PrivateState', history)))
            with patch.object(budget,'BASE',base), patch.object(budget,'anchored',lambda _:None), patch.object(budget.os.path,'lexists',lambda _:True):
                return budget.selected_trash_state_credit()
        self.assertEqual(credit(Node('operations-v2.sqlite',mode=stat.S_IFREG|0o600,size=1024)),1024)
        for item in [Node('unrecognized',mode=stat.S_IFREG|0o600,size=1),
                     Node('operations-v2.sqlite',mode=stat.S_IFLNK|0o600,size=1),
                     Node('operations-v2.sqlite',mode=stat.S_IFREG|0o644,size=1),
                     Node('operations-v2.sqlite',mode=stat.S_IFREG|0o600,size=1,links=2),
                     Node('operations-v2.sqlite',mode=stat.S_IFREG|0o600,size=(1<<20)+1)]:
            with self.assertRaises(ValueError): credit(item)
        self.assertEqual(budget.SELECTED_TRASH_STATE_BYTES,1<<20)
        self.assertEqual(budget.effective_limits()['logical'],1<<30)


if __name__ == "__main__": unittest.main()
