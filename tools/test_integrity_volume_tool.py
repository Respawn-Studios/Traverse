#!/usr/bin/env python3
"""Small owned-process checks; never invokes a disk/image tool."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
from verify_integrity_volume import OwnedToolFailure, ROOT, tool


class IntegrityVolumeToolTests(unittest.TestCase):
    def test_success_drains_both_streams(self):
        result = tool([sys.executable, "-c", "import os; os.write(1,b'result'); os.write(2,b'ignored')"], timeout=2)
        self.assertEqual(result, b"result")

    def test_nonzero_has_fixed_facts_without_output_or_arguments(self):
        secret = "generated-private-diagnostic-sentinel"
        with self.assertRaises(OwnedToolFailure) as caught:
            tool([sys.executable, "-c", "import os,sys; os.write(1,sys.argv[1].encode()); os.write(2,b'error'); sys.exit(7)", secret], timeout=2)
        facts = caught.exception.facts
        self.assertEqual((facts["reason"], facts["childState"], facts["returnCode"]), ("nonzeroExit", "exited", 7))
        self.assertTrue(facts["stdoutEOF"] and facts["stderrEOF"])
        self.assertEqual((facts["stdoutBytes"], facts["stderrBytes"]), (len(secret), 5))
        self.assertNotIn(secret, str(caught.exception))
        self.assertNotIn(sys.executable, str(caught.exception))

    def test_running_timeout_snapshots_before_owned_stop_and_reap(self):
        with self.assertRaises(OwnedToolFailure) as caught:
            tool([sys.executable, "-c", "import os,time; os.write(1,b'ready'); time.sleep(5)"], timeout=0.15)
        facts = caught.exception.facts
        self.assertEqual((facts["reason"], facts["childState"], facts["returnCode"]), ("timeout", "running", None))
        self.assertFalse(facts["stdoutEOF"] or facts["stderrEOF"])
        self.assertEqual(facts["stdoutBytes"], 5)
        self.assertGreaterEqual(facts["elapsedSeconds"], facts["timeoutSeconds"])
        self.assertLess(facts["elapsedSeconds"], 1)

    def test_exited_child_with_inherited_pipes_is_timeout_not_success(self):
        area = ROOT / ".build/fixtures"
        area.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="integrity-tool-pipes-", dir=area) as temporary:
            receipt = Path(temporary) / "owned-processes.json"
            # The direct child exits0; its finite grandchild really inherits
            # both pipes. No simulated selector or synthetic Popen state.
            script = """import json,os,sys,time
parent=os.getpid()
child=os.fork()
if child:
    with open(sys.argv[1], 'x') as f: json.dump({'parent':parent,'child':child},f)
    os._exit(0)
time.sleep(0.5)
os._exit(0)
"""
            try:
                with self.assertRaises(OwnedToolFailure) as caught:
                    tool([sys.executable, "-c", script, str(receipt)], timeout=0.15)
                facts = caught.exception.facts
                self.assertEqual((facts["reason"], facts["childState"], facts["returnCode"]), ("timeout", "exitedWithOpenPipes", 0))
                self.assertFalse(facts["stdoutEOF"] or facts["stderrEOF"])
                self.assertEqual((facts["stdoutBytes"], facts["stderrBytes"]), (0, 0))
                self.assertLess(facts["elapsedSeconds"], 1)
                self.assertNotIn(temporary, str(caught.exception))
            finally:
                # The exact generated grandchild is finite. Observe its actual
                # exit/reap before disposing state, even if an assertion fails.
                if receipt.exists():
                    owned = json.loads(receipt.read_text())
                    self.drain_owned_pid(owned["child"], group=owned["parent"])
                    self.assert_pid_absent(owned["parent"])

    def assert_pid_absent(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        self.fail("Generated process did not drain")

    def drain_owned_pid(self, pid, *, group):
        end = time.monotonic() + 3
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.01)
        # No arbitrary PID/group cleanup. Signal only this still-matching
        # generated descendant if its bounded self-exit did not complete.
        try:
            if os.getpgid(pid) != group:
                self.fail("Generated descendant ownership changed")
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        end = time.monotonic() + 3
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.01)
        self.fail("Generated descendant did not drain")


if __name__ == "__main__":
    unittest.main()
