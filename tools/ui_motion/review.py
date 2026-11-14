#!/usr/bin/env python3
"""Bounded entry point for the optional generated-movie contact-sheet compiler."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/smb_reader'))
from packet import TOOLING_LIMIT, TOOLING,MIB,environment,usage


def require_headroom(measure):
    # Media imports expanded a cold SDK cache by about 80 MiB during the first
    # experiment. Reserve 96 MiB (observed cold growth plus safety room).
    if measure['bytes']+96*MIB>TOOLING_LIMIT:raise RuntimeError('Contact-sheet compiler requires 96 MiB free inside the approved tooling cap; no child started')


def main():
    if len(sys.argv) not in [2,3] or str(uuid.UUID(sys.argv[1])).upper()!=sys.argv[1] or len(sys.argv)==3 and sys.argv[2] not in ['--completion','--identity','--foundation','--download','--upload','--native']:raise RuntimeError('Exact generated recording case required')
    require_headroom(usage(TOOLING,TOOLING_LIMIT))
    env=os.environ.copy();env.update(environment())
    child=subprocess.Popen(['/usr/bin/xcrun','swift','-module-cache-path',str(TOOLING/'swift-module-cache'),
        str(REPO/'tools/ui_motion/review.swift'),*sys.argv[1:]],cwd=REPO,env=env,start_new_session=True)
    reason=None;began=time.monotonic()
    try:
        while child.poll() is None:
            value=usage(TOOLING,TOOLING_LIMIT,building=True,compiler_locks=True)
            if value['bytes']+16*MIB>TOOLING_LIMIT:reason='Media compiler safety margin'
            if time.monotonic()-began>30:reason='Media compiler deadline'
            if reason:break
            time.sleep(.025)
    finally:
        if child.poll() is None:
            os.killpg(child.pid,signal.SIGTERM)
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=3)
    usage(TOOLING,TOOLING_LIMIT)
    if reason or child.returncode:raise RuntimeError(reason or 'Generated movie analysis failed; originals preserved')
    print(json.dumps(dict(passed=True,actualCompilerExit=child.returncode)))


if __name__=='__main__':main()
