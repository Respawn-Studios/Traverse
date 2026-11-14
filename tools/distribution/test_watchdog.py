#!/usr/bin/env python3
"""Real owned-child deadline/reaping controls in one reserved generated case."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import qualify_foundation as q
from distribution.packet import ROOT,directory,put,audit


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--case',required=True);args=parser.parse_args()
    if str(uuid.UUID(args.case)).upper()!=args.case:raise RuntimeError('Canonical reserved sandbox case required')
    case=ROOT/args.case
    if case.resolve()!=case or json.loads((case/'reservation.json').read_bytes()).get('packet')!='sandbox-foundation-v1':
        raise RuntimeError('Exact generated packet required')
    audit();root=directory(case/'evidence'/('watchdog-'+str(uuid.uuid4()).upper()))
    put(root/'deadline.json',dict(preserved='preceding failure'))
    before=(root/'deadline.json').read_bytes();results=[]
    def run(name,command,expected,*,ignore=False,broken_receipt=False):
        log=root/(name+'.log');saved=q.put
        with log.open('xb') as output:
            child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
            try:
                if ignore:
                    end=time.monotonic()+2
                    while not log.stat().st_size and time.monotonic()<end:time.sleep(.01)
                    if 'ready' not in log.read_text():raise RuntimeError('Controlled signal handler did not start')
                if broken_receipt:
                    def refuse(*a,**kw):raise OSError('Generated diagnostic failure')
                    q.put=refuse
                stats,failure,contained,forced=q.wait_generated(child,log,root,
                    deadline=.06 if expected else 2,term_grace=.06,maximum_containment=1)
            finally:
                q.put=saved
                if child.poll() is None:child.kill();child.wait(timeout=2)
        if child.returncode!=expected or bool(failure)!=bool(expected) or contained!=bool(expected) \
                or ignore and not forced or broken_receipt and 'diagnostic receipt unavailable' not in failure:
            raise RuntimeError('Actual child lifetime did not match the controlled case')
        results.append(dict(name=name,actualChildExit=child.returncode,reaped=True,
            failure=failure,contained=contained,forced=forced,peakRSSBytes=stats.ru_maxrss))
    run('repeat-a',['/bin/sleep','10'],-signal.SIGTERM)
    run('repeat-b',['/bin/sleep','10'],-signal.SIGTERM)
    run('failed-receipt',['/bin/sleep','10'],-signal.SIGTERM,broken_receipt=True)
    run('ignored-term',[sys.executable,'-B','-c',
        'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("ready",flush=True);time.sleep(10)'],
        -signal.SIGKILL,ignore=True)
    run('ordinary-exit',[sys.executable,'-B','-c','pass'],0)
    if (root/'deadline.json').read_bytes()!=before:raise RuntimeError('Preceding evidence was overwritten')
    put(root/'result.json',dict(passed=True,actualControls=len(results),results=results,
        previousReceiptPreserved=True,watchdogSHA256=hashlib.sha256(Path(q.__file__).read_bytes()).hexdigest(),packet=audit()))
    print(json.dumps(dict(passed=True,actualControls=len(results),allChildrenReaped=True,evidence=str(root))))


if __name__=='__main__':main()
