#!/usr/bin/env python3
"""One native generated foundation packet; no global defaults or personal data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import sys
sys.dont_write_bytecode = True
import dev
from foundation_packet import reserve,audit,directory,put,MIB


def wait_generated(child,log,evidence,*,deadline=60,term_grace=3,maximum_containment=8):
    """Reap this exact unreaped generated child, including failed containment.

    Never used for user-file mutations, network/credentials or shared apps.
    A signal/deadline always fails qualification; it is not graceful drain.
    """
    began=time.monotonic();failure=None;containment=None;forced=False
    def note(kind,value):
        # Containment must never depend on diagnostics succeeding. Keep every
        # run's receipt distinct, including callers sharing a retained case.
        nonlocal failure
        try:put(evidence/(log.stem+'-'+str(child.pid)+'-'+kind+'.json'),value)
        except OSError:
            failure=(failure or 'Generated containment required')+'; diagnostic receipt unavailable'
    while True:
        found,status,stats=os.wait4(child.pid,os.WNOHANG)
        if found:
            child.returncode=os.waitstatus_to_exitcode(status)
            return stats,failure,containment is not None,forced
        if failure is None and (time.monotonic()-began>deadline or log.stat().st_size>512*1024):
            failure='Generated native deadline or log bound';containment=time.monotonic()
            try:os.kill(child.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            note('deadline',dict(pid=child.pid,reason=failure,generatedOnly=True))
        if containment is not None and time.monotonic()-containment>term_grace and not forced:
            try:os.kill(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            forced=True
        if containment is not None and time.monotonic()-containment>maximum_containment:
            note('retained-process',dict(pid=child.pid,reason='Exact generated containment not verified'))
            raise RuntimeError('Generated process still retained; inspect before retry')
        time.sleep(.02)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('scenario',choices=['incoming-folders','quick-profiles','motion-modes','portable-storage','bundled-notices','bundled-notices-lifetime','support-details'])
    parser.add_argument('--record',action='store_true');parser.add_argument('--capture',action='store_true');args=parser.parse_args()
    if args.record and args.scenario!='motion-modes':raise RuntimeError('Only generated motion mode recording is admitted')
    if args.capture and args.scenario!='support-details':raise RuntimeError('Explicit capture is limited to generated Support Details')
    case=reserve(args.scenario,amount=8*MIB,entries=64 if args.scenario=='support-details' else 512)
    directory(case/'evidence');directory(case/'source')
    for name in ['Folder A','Café 100% complete','Profile Folder','Bundle.app']: directory(case/'source'/name)
    (case/'source/Plain.txt').write_text('generated incoming-folder refusal fixture\n')
    if args.scenario=='motion-modes':
        for index in range(4):(case/f'source/Folder A/Generated {index}.txt').write_text('Generated motion fixture\n')
    (case/'source/Folder Link').symlink_to(case/'source/Folder A',target_is_directory=True)
    if args.scenario=='quick-profiles':
        directory(case/'corrupt');(case/'corrupt/launch-profiles-v1.json').write_bytes(b'{generated-invalid')
    if args.scenario=='portable-storage':
        directory(case/'source/Library');directory(case/'source/Scan Root');directory(case/'source/Operation Root')
        (case/'source/Scan Root/Generated.txt').write_text('Generated metadata scan file\n')
        (case/'source/Scan Root/Generated.swift').write_text('// Generated source-name fixture\n')
    binary=dev.APP/'Contents/MacOS/Mac Explorer'
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(dev.APP)],check=True,capture_output=True,timeout=30)
    put(case/'inputs.json',dict(scenario=args.scenario,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        generatedOnly=True,personalCatalogs=0,keychainQueries=0,systemDefaultChanges=0,actualSingleWindowRecording=args.record,
        actualSingleWindowCapture=args.capture))
    env=dev.environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),MAC_EXPLORER_TEST_ROOT=str(case))
    began=time.monotonic()
    with (case/'evidence/native.log').open('xb') as log:
        child=subprocess.Popen([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--offscreen',
            '--check-'+args.scenario,*(['--record-motion-modes'] if args.record else []),
            *(['--capture-support-details'] if args.capture else []),'--analysis-source',str(case)],cwd=dev.ROOT,env=env,stdin=subprocess.DEVNULL,
            stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        put(case/'evidence/process.json',dict(pid=child.pid,ownProcessGroup=child.pid))
        stats,failure,contained,forced=wait_generated(child,case/'evidence/native.log',case/'evidence')
    report=case/'evidence/native.json';value=json.loads(report.read_bytes()) if report.is_file() else None
    passed=failure is None and child.returncode==0 and value is not None and value.get('passed') is True and stats.ru_maxrss<=256*MIB
    put(case/'result.json',dict(passed=passed,actualExit=child.returncode,native=value,parentPeakRSSBytes=stats.ru_maxrss,
        elapsedSeconds=time.monotonic()-began,failure=failure,generatedContainment=contained,
        forcedContainment=forced,gracefulDrainQualified=failure is None,packet=audit()))
    print(json.dumps(dict(case=case.name,passed=passed)))
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
