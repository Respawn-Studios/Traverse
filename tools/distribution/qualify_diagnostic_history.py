#!/usr/bin/env python3
"""Generated-only diagnostic-store failure/rotation/privacy qualification."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO, reserve, put, audit, measure, MIB

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug','release'], default='debug')
args = parser.parse_args()
case = reserve('traverse-local-diagnostic-history-core')
put(case/'inputs.json', dict(generatedOnly=True, personalFiles=0, networkRequests=0,
    maximumCaseBytes=64*MIB, maximumCaseEntries=2048, maximumSeconds=300))
env = dev.environment()
env['TRAVERSE_DIAGNOSTIC_TEST_ROOT'] = str(case/'source')
scratch = REPO/('.build/swift-tests-release' if args.configuration == 'release' else '.build/swift-tests')
command = ['xcrun','swift','test','--package-path',str(REPO/'Packages/ExplorerKit'),
    '--configuration',args.configuration,'--scratch-path',str(scratch),
    '--cache-path',str(REPO/'.build/swift-cache'),'--config-path',str(REPO/'.build/swift-config'),
    '--security-path',str(REPO/'.build/swift-security'),'--swift-sdks-path',str(REPO/'.build/swift-sdks'),
    '--disable-keychain','--disable-netrc','--disable-dependency-cache','--manifest-cache','local',
    '--disable-automatic-resolution','--jobs','4','-Xswiftc','-warnings-as-errors',
    '-Xswiftc','-module-cache-path','-Xswiftc',str(REPO/'.build/compiler-cache/swift'),
    '--filter','DiagnosticHistoryTests|OperationDiagnosticsTests','--no-parallel']
began = time.monotonic()
with (case/'evidence/core.log').open('xb') as output:
    child = subprocess.Popen(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,
        stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
    try: actual = child.wait(timeout=300)
    finally:
        if child.poll() is None: os.killpg(child.pid,signal.SIGTERM); child.wait(timeout=5)
phases = []
if actual == 0 and args.configuration == 'debug':
    child_command = command[:]
    child_command[child_command.index('--filter')+1] = 'DiagnosticHistoryProcessTests/child'
    child_command.append('--skip-build')
    for boundary in ['beforeAppend','beforeSync']:
        for action in ['interrupt','reopen']:
            child_env = dict(env, TRAVERSE_DIAGNOSTIC_PROCESS_ACTION=action,
                TRAVERSE_DIAGNOSTIC_PROCESS_BOUNDARY=boundary)
            with (case/'evidence'/('process-'+boundary+'-'+action+'.log')).open('xb') as output:
                result = subprocess.run(child_command,cwd=REPO,env=child_env,stdin=subprocess.DEVNULL,
                    stdout=output,stderr=subprocess.STDOUT,timeout=45)
            lines = (case/'evidence'/('process-'+boundary+'-'+action+'.log')).read_text(errors='replace').splitlines()
            events = [json.loads(line.split('TRAVERSE_DIAGNOSTIC_CHILD ',1)[1]) for line in lines if 'TRAVERSE_DIAGNOSTIC_CHILD ' in line]
            valid = len(events)==1 and events[0].get('boundary')==boundary \
                and events[0].get('action')==('interrupted' if action=='interrupt' else 'reopened') \
                and (result.returncode != 0 if action=='interrupt' else result.returncode==0)
            phases.append(dict(boundary=boundary,action=action,actualExit=result.returncode,passed=valid,events=events))
    if len(phases)!=4 or not all(p['passed']for p in phases) or len({p['events'][0]['pid']for p in phases if p['events']})!=4:
        actual = 1
put(case/'evidence/processes.json',dict(phases=phases))
usage = measure(case)
passed = actual == 0 and usage['bytes'] <= 64*MIB and usage['entries'] <= 2048
put(case/'result.json',dict(passed=passed, actualExit=actual, seconds=time.monotonic()-began,
    caseUsage=usage, packet=audit()))
print(json.dumps(dict(case=case.name,passed=passed,actualExit=actual)),flush=True)
if not passed: raise SystemExit(1)
