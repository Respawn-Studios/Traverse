#!/usr/bin/env python3
"""Finite generated core controls for native rename security metadata."""
import json
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse import run
from distribution.traverse_packet import REPO,TOOLING,reserve,directory,put,audit,measure,MIB

parser=argparse.ArgumentParser();parser.add_argument('--configuration',choices=['debug','release'],default='debug')
parser.add_argument('--regression',action='store_true');args=parser.parse_args()
case=reserve('traverse-native-rename-security-core')
put(case/'inputs.json',dict(generatedOnly=True,maximumSourceBytes=64*1024,maximumCaseBytes=64*MIB,
    maximumCaseEntries=1024,nativeSandboxClaim=False,fullFingerprintUnchanged=True))
env=dev.environment()
env.update(MAC_EXPLORER_RENAME_SECURITY_TEST_ROOT=str(case/'source'))
log=case/'evidence/core.log'
began=time.monotonic()
scratch=REPO/('.build/swift-tests-release' if args.configuration=='release' else '.build/swift-tests')
selected='NativeRenameSecurityTests'
if args.regression:selected += '|recoverableMoveAndRenameUndo|recoverableCopyAndUndoRetainsCopiedObject|undoRejectsEditedCopiedBytesAndPreservesBoth|TransferContinuationTests|NameOnlyRenameTests'
command=['xcrun','swift','test','--package-path',str(REPO/'Packages/ExplorerKit'),'--configuration',args.configuration,
    '--scratch-path',str(scratch),'--cache-path',str(REPO/'.build/swift-cache'),
    '--config-path',str(REPO/'.build/swift-config'),'--security-path',str(REPO/'.build/swift-security'),
    '--swift-sdks-path',str(REPO/'.build/swift-sdks'),'--disable-keychain','--disable-netrc',
    '--disable-dependency-cache','--manifest-cache','local','--disable-automatic-resolution','--jobs','4',
    '-Xswiftc','-warnings-as-errors','-Xswiftc','-module-cache-path','-Xswiftc',str(REPO/'.build/compiler-cache/swift'),
    '--filter',selected,'--no-parallel']
with log.open('xb') as output:
    child=subprocess.Popen(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
    try:actual=child.wait(timeout=300)
    finally:
        if child.poll() is None:
            import signal
            os.killpg(child.pid,signal.SIGTERM);child.wait(timeout=5)
usage=measure(case)
passed=actual==0 and usage['bytes']<=64*MIB and usage['entries']<=1024
phases=[]
if passed and args.configuration=='debug':
    child_command=command[:]
    child_command[child_command.index('--filter')+1]='NativeRenameCrashProcessTests/child'
    child_command.append('--skip-build')
    for phase in ['interrupt','inspect','recover','reverse-interrupt','reverse-inspect','reverse-recover']:
        childenv=dict(env,MAC_EXPLORER_RENAME_CRASH_ACTION=phase)
        phase_log=case/'evidence'/('process-'+phase+'.log')
        with phase_log.open('xb') as output:
            result=subprocess.run(child_command,cwd=REPO,env=childenv,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=45)
        events=[json.loads(line.split('TRAVERSE_RENAME_CHILD ',1)[1]) for line in phase_log.read_text(errors='replace').splitlines() if 'TRAVERSE_RENAME_CHILD ' in line]
        action=phase.removeprefix('reverse-')
        expected='crash' if action=='interrupt' else action
        valid=len(events)==1 and events[0].get('phase')==expected and events[0].get('reverse')==phase.startswith('reverse-') and (result.returncode!=0 if action=='interrupt' else result.returncode==0)
        phases.append(dict(phase=phase,actualExit=result.returncode,events=events,passed=valid))
        if not valid:passed=False;break
    if len(phases)!=6 or not all(p['passed'] for p in phases):passed=False
    elif len({p['events'][0]['pid'] for p in phases})!=6:passed=False
usage=measure(case)
passed=passed and usage['bytes']<=64*MIB and usage['entries']<=1024
put(case/'result.json',dict(passed=passed,actualExit=actual,seconds=time.monotonic()-began,caseUsage=usage,packet=audit()))
put(case/'evidence/process-results.json',dict(configuration=args.configuration,phases=phases,passed=passed))
print(json.dumps(dict(case=case.name,passed=passed,actualExit=actual)),flush=True)
if not passed:raise SystemExit(1)
