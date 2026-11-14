#!/usr/bin/env python3
"""Local direct-child control-pipe check; no app, server or network."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0,str(Path(__file__).resolve().parent))
import packet


CHILD = '''
import sys
for label in ("first", "second"):
    print("READY " + label, file=sys.stderr, flush=True)
    if sys.stdin.buffer.readline() != (label + "\\n").encode():
        raise SystemExit(5)
'''


class ControlledStdinTests(unittest.TestCase):
    def test_two_observed_messages_reach_only_the_owned_child(self):
        parent = packet.REPO/'.build/test-fixtures'
        parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='controlled-stdin-',dir=parent) as owned:
            root = Path(owned)
            (root/'evidence').mkdir(mode=0o700)
            sent = set()
            def observe(_pid):
                lines = (root/'evidence/control.stderr').read_text().splitlines()
                for label in ('first','second'):
                    if label not in sent and 'READY '+label in lines:
                        sent.add(label)
                        return (label+'\n').encode()
                return None
            with patch.object(packet,'environment',return_value={'PATH':'/usr/bin:/bin'}), \
                    patch.object(packet,'audit',return_value={}), \
                    patch.object(packet.d,'measure',return_value={'bytes':0}):
                result,stdout,stderr = packet.run(
                    [sys.executable,'-B','-c',CHILD],root,'control',timeout=5,
                    native=True,observer=observe,controlled_stdin=True)
            self.assertTrue(result['passed'])
            self.assertEqual(result['controlledStdinMessages'],2)
            self.assertEqual(result['controlledStdinBytes'],len(b'first\nsecond\n'))
            self.assertEqual(stdout.read_bytes(),b'')
            self.assertEqual(stderr.read_text().splitlines(),['READY first','READY second'])
            self.assertEqual(sent,{'first','second'})

    def test_control_requires_one_native_direct_observer(self):
        with self.assertRaises(RuntimeError):
            packet.run(['/usr/bin/true'],Path('/unused'),'control',controlled_stdin=True)
        with self.assertRaises(RuntimeError):
            packet.run(['/usr/bin/true'],Path('/unused'),'control',native=True,
                       observer=lambda _pid:None,input_bytes=b'x',controlled_stdin=True)

    def test_oversized_control_reaps_the_exact_child(self):
        parent = packet.REPO/'.build/test-fixtures'
        parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='controlled-refusal-',dir=parent) as owned:
            root = Path(owned)
            (root/'evidence').mkdir(mode=0o700)
            with patch.object(packet,'environment',return_value={'PATH':'/usr/bin:/bin'}), \
                    patch.object(packet,'audit',return_value={}), \
                    patch.object(packet.d,'measure',return_value={'bytes':0}):
                with self.assertRaisesRegex(RuntimeError,'input bound'):
                    packet.run([sys.executable,'-B','-c',CHILD],root,'control',timeout=5,
                               native=True,observer=lambda _pid:b'x'*129,
                               controlled_stdin=True)
            pid = json.loads((root/'evidence/control.started.json').read_bytes())['pid']
            with self.assertRaises(ChildProcessError):
                os.waitpid(pid,os.WNOHANG)


if __name__ == '__main__':unittest.main()
