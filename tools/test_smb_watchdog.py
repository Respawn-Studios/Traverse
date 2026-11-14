#!/usr/bin/env python3
"""Offline regression: a watchdog must keep ownership through actual child exit."""
from __future__ import annotations
import json
from pathlib import Path
import sys
import uuid
from unittest.mock import patch

sys.dont_write_bytecode = True
import qualify_smb_native as packet

def main():
    # Same retained generated case; no network, native process or extra session.
    case = packet.BASE/'933A3CED-64D0-47E0-A51F-E6D9E30746E2'
    packet.usage()
    run = case/('watchdog-'+str(uuid.uuid4()).upper()); run.mkdir(mode=0o700)
    class Process:
        pid = 0
        returncode = 0
        polls = 0
        exited = False
        def poll(self):
            self.polls += 1
            if self.polls == 2:
                assert (run/'outcome-uncertain.json').is_file(), 'Watchdog did not record uncertainty'
            self.exited = self.polls >= 3
            return self.returncode if self.exited else None
    child = Process()
    with patch.object(packet.subprocess, 'Popen', return_value=child), \
         patch.object(packet.time, 'monotonic', side_effect=[0, 181, 182]), \
         patch.object(packet.time, 'sleep'):
        try: packet.run_native([], {}, run, case, False, b'')
        except RuntimeError as error:
            assert child.exited, 'Runner exited while the child was still pending'
            assert 'now exited' in str(error)
        else: raise AssertionError('An uncertain run became success')
    assert json.loads((run/'late-exit.json').read_bytes()) == dict(returnCode=0, watchdogExceeded=True)
    exception_run = case/('watchdog-monitor-failure-'+str(uuid.uuid4()).upper()); exception_run.mkdir(mode=0o700)
    class PendingProcess:
        pid = 0
        returncode = 0
        polls = 0
        exited = False
        def poll(self):
            self.polls += 1; self.exited = self.polls >= 3
            return self.returncode if self.exited else None
    pending = PendingProcess()
    with patch.object(packet.subprocess, 'Popen', return_value=pending), \
         patch.object(packet.time, 'monotonic', side_effect=RuntimeError('Injected monitor failure')), \
         patch.object(packet.time, 'sleep'):
        try: packet.run_native([], {}, exception_run, case, False, b'')
        except RuntimeError as error:
            assert pending.exited and 'Injected monitor failure' in str(error)
        else: raise AssertionError('Monitor failure became success')
    assert (exception_run/'monitor-exception-pending.json').is_file()
    assert (exception_run/'monitor-exception-exit.json').is_file()
    io_run=case/('watchdog-receipt-failure-'+str(uuid.uuid4()).upper());io_run.mkdir(mode=0o700)
    pending=PendingProcess()
    with patch.object(packet.subprocess, 'Popen', return_value=pending), \
         patch.object(Path, 'write_text', side_effect=OSError('Injected receipt I/O failure')), \
         patch.object(packet.time, 'sleep'):
        try: packet.run_native([], {}, io_run, case, False, b'')
        except OSError:
            assert pending.exited, 'Receipt failure abandoned a pending child'
        else: raise AssertionError('Receipt failure became success')
    with (run/'passed.json').open('x') as output:
        json.dump(dict(passed=True,offline=True,childWasRetained=True,uncertaintyNeverBecameSuccess=True),output)
    print('Offline watchdog ownership regression passed')
    print(json.dumps(packet.usage(),sort_keys=True))

if __name__ == '__main__': main()
