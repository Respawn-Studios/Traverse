"""Pure refusal controls; no generated artifacts or SQLite/file writes."""
import errno
import importlib.util
import os
import sqlite3
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
path=Path(__file__).parent/"analyzer/paged_result/qualify.py"
spec=importlib.util.spec_from_file_location("paged_controller_controls",path)
controller=importlib.util.module_from_spec(spec);spec.loader.exec_module(controller)


class ResultSchemaTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(":memory:")
        self.db.executescript((path.parent/"PagedStore.sql").read_text())

    def tearDown(self):self.db.close()

    def test_old_table_is_unavailable_and_new_profile_is_explicit(self):
        self.assertEqual(self.db.execute("PRAGMA user_version").fetchone(),(2,))
        self.assertEqual(self.db.execute("SELECT revision,aggregates,transaction_rows FROM profile").fetchone(),(2,0,128))
        with self.assertRaises(sqlite3.OperationalError):self.db.execute("SELECT * FROM nodes")

    def test_unreviewed_profile_and_transaction_bounds_refuse(self):
        for aggregate,rows in [(2,128),(-1,128),(0,1025),(1,0)]:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute("UPDATE profile SET aggregates=?,transaction_rows=?",(aggregate,rows))

    def test_a_second_directory_identity_cannot_be_a_parent(self):
        identity=(11).to_bytes(8,"big")+(100).to_bytes(8,"big")
        self.db.executemany("INSERT INTO observations_v2 VALUES(?,0,?,1,?,NULL,NULL,zeroblob(52))",[(1,b"one",identity),(2,b"alias",identity)])
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO observations_v2 VALUES(3,2,x'6368696c64',0,NULL,NULL,NULL,zeroblob(52))")
        self.db.execute("INSERT INTO observations_v2 VALUES(3,1,x'6368696c64',0,NULL,NULL,NULL,zeroblob(52))")

    def test_uncommitted_nodes_and_direct_totals_rollback_together(self):
        self.db.execute("BEGIN IMMEDIATE")
        self.db.execute("INSERT INTO observations_v2 VALUES(1,0,x'61',0,NULL,NULL,NULL,zeroblob(52))")
        self.db.execute("INSERT INTO direct_totals VALUES(0,zeroblob(140))")
        self.db.execute("ROLLBACK")
        self.assertEqual(self.db.execute("SELECT count(*) FROM observations_v2").fetchone(),(1,))
        self.assertEqual(self.db.execute("SELECT count(*) FROM direct_totals").fetchone(),(0,))


class OwnedSessionCreationTests(unittest.TestCase):
    def test_missing_anchor_never_attempts_a_path_based_mutation(self):
        with patch.object(controller,"directory_fd",side_effect=OSError(errno.ELOOP,"generated")),\
             patch.object(controller.os,"mkdir") as mkdir,patch.object(controller.os,"open") as opening:
            with self.assertRaises(OSError):controller.Owner()
            mkdir.assert_not_called();opening.assert_not_called()

    def test_existing_container_is_opened_relative_to_anchor_with_no_follow(self):
        with patch.object(controller,"directory_fd",return_value=100),\
             patch.object(controller.os,"mkdir",side_effect=FileExistsError) as mkdir,\
             patch.object(controller.os,"open",side_effect=OSError(errno.ELOOP,"generated")) as opening,\
             patch.object(controller.os,"close") as close:
            with self.assertRaises(OSError):controller.Owner()
            mkdir.assert_called_once_with(controller.budget.SQLITE_STORE_ROOT.name,mode=0o700,dir_fd=100)
            self.assertEqual(opening.call_args.kwargs["dir_fd"],100)
            self.assertTrue(opening.call_args.args[1]&controller.NOFOLLOW_ANY)
            close.assert_called_once_with(100)

    def test_widened_container_cannot_create_a_session_or_database(self):
        for facts in [SimpleNamespace(st_uid=os.geteuid(),st_mode=0o40755),
                      SimpleNamespace(st_uid=os.geteuid()+1,st_mode=0o40700)]:
            with patch.object(controller,"directory_fd",return_value=100),\
                 patch.object(controller.os,"mkdir",side_effect=FileExistsError) as mkdir,\
                 patch.object(controller.os,"open",return_value=101) as opening,\
                 patch.object(controller.os,"fstat",return_value=facts),patch.object(controller.os,"close") as close:
                with self.assertRaises(ValueError):controller.Owner()
                self.assertEqual(mkdir.call_count,1);self.assertEqual(opening.call_count,1)
                self.assertEqual({c.args[0] for c in close.call_args_list},{100,101})


if __name__=="__main__":unittest.main()
