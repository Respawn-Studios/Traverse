#!/usr/bin/env python3
"""Run only the explicit loopback generated-share test, with runtime home intact."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode=True
from dev import ROOT, environment, local_directory

MIB=1024**2
BASE=ROOT/'.build/b10-native-smb'
SERVER_CASE='AC036E86-07C4-43DC-8062-80BD7ED81270'

def run_native(command, env, run, case, lifecycle, controller):
    """Never let a monitor exception abandon a real pending native child."""
    retained=[]
    try:
        return monitor_native(command, env, run, case, lifecycle, controller,
                              lambda value: retained.append(value))
    finally:
        process=retained[0] if retained else None
        if process is not None and process.poll() is None:
            try:
                (run/'monitor-exception-pending.json').write_text(json.dumps(dict(nativePID=process.pid,
                    pending=True,nativeDrainProven=False,retryAllowed=False)))
                print('Monitor failed; retaining actual native child until exit. Do not retry.',flush=True)
            finally:
                # Even receipt/log I/O failure must retain the actual child.
                while process.poll() is None:time.sleep(0.1)
            (run/'monitor-exception-exit.json').write_text(json.dumps(dict(returnCode=process.returncode)))

def monitor_native(command, env, run, case, lifecycle, controller, retain):
    """A watchdog records uncertainty; it never kills a pending native request."""
    with (run/'native.log').open('xb') as output:
        process=subprocess.Popen(command,cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT)
        retain(process)
        (run/'native-process.json').write_text(json.dumps(dict(pid=process.pid)))
        deadline=time.monotonic()+180
        offline_attempted=False
        server_stopped=False
        restored=False
        uncertain=False
        while process.poll() is None:
            if lifecycle and not offline_attempted:
                attempts=[p for p in case.glob('native-*') if p.is_dir() and not p.is_symlink()]
                for attempt in attempts:
                    ready=attempt/'offline-ready.json'
                    if not ready.exists(): continue
                    facts=ready.lstat()
                    if not stat.S_ISREG(facts.st_mode) or facts.st_size>4096 or facts.st_uid!=os.getuid():
                        raise RuntimeError('Offline barrier changed; native process retained')
                    try: state=json.loads(ready.read_bytes())
                    except json.JSONDecodeError: continue
                    if state!={'session':case.name,'readerHeld':True,'activeReaders':1,'nativeCallbackCompleted':True}:
                        raise RuntimeError('Offline barrier not admitted; native process retained')
                    offline_attempted=True
                    result=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=15','ubuntuserver',
                        'python3','-','stop',SERVER_CASE,'--session',case.name],input=controller,capture_output=True,timeout=40)
                    if len(result.stdout)+len(result.stderr)>65536: raise RuntimeError('Offline receipt exceeded its bound')
                    (run/'server-stop.log').write_bytes(result.stdout+result.stderr)
                    if result.returncode==0 and json.loads(result.stdout).get('phase')=='stopped':
                        server_stopped=True
                        with (attempt/'offline-stop-confirmed').open('xb') as acknowledged:
                            acknowledged.write((case.name+'\n').encode());acknowledged.flush();os.fsync(acknowledged.fileno())
                    break
            if time.monotonic()>deadline and not uncertain:
                uncertain=True
                (run/'outcome-uncertain.json').write_text(json.dumps(dict(nativePID=process.pid,pending=True,
                    nativeDrainProven=False,retryAllowed=False)))
                print('Native outcome uncertain; retaining runner and actual child until exit. Do not retry.',flush=True)
                if server_stopped:
                    result=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=15','ubuntuserver',
                        'python3','-','restore-drain',SERVER_CASE,'--session',case.name],input=controller,capture_output=True,timeout=40)
                    if len(result.stdout)+len(result.stderr)>65536:raise RuntimeError('Drain restoration receipt exceeded its bound')
                    (run/'server-drain-restore.log').write_bytes(result.stdout+result.stderr)
                    if result.returncode:raise RuntimeError('Drain-only restoration refused; native child retained')
                    restored=True
            time.sleep(0.1)
        if uncertain:
            if restored:
                result=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=15','ubuntuserver',
                    'python3','-','stop',SERVER_CASE,'--session',case.name],input=controller,capture_output=True,timeout=40)
                (run/'server-drain-stop.log').write_bytes(result.stdout+result.stderr)
                if result.returncode:raise RuntimeError('Restored generated server needs final stop; preserve session')
            (run/'late-exit.json').write_text(json.dumps(dict(returnCode=process.returncode,watchdogExceeded=True)))
            raise RuntimeError('Native process has now exited after uncertainty; preserve the failed session')
        return process.returncode

def usage():
    totals=dict(bytes=0,entries=1,reservedBytes=0,reservedEntries=1)
    for case in BASE.iterdir():
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir(): raise RuntimeError('Unexpected SMB packet entry')
        receipt=json.loads((case/'reservation.json').read_bytes())
        size=entries=0; pending=[case]; device=case.stat().st_dev
        while pending:
            item=pending.pop(); facts=item.lstat()
            if facts.st_dev != device: raise RuntimeError('A retained mount prevents ordinary fixture accounting')
            size+=max(facts.st_size,facts.st_blocks*512); entries+=1
            if stat.S_ISDIR(facts.st_mode): pending.extend(item.iterdir())
            elif not stat.S_ISREG(facts.st_mode): raise RuntimeError('Unexpected SMB fixture type')
        if size>receipt['bytes'] or entries>receipt['entries']: raise RuntimeError('SMB case admission exceeded')
        totals['bytes']+=size; totals['entries']+=entries
        totals['reservedBytes']+=receipt['bytes']; totals['reservedEntries']+=receipt['entries']
    if totals['reservedBytes']>128*MIB or totals['reservedEntries']>1024: raise RuntimeError('SMB packet admission exhausted')
    return totals

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('case')
    parser.add_argument('--audit',action='store_true')
    parser.add_argument('--signed-app',action='store_true')
    parser.add_argument('--internal-mount',action='store_true')
    parser.add_argument('--lifecycle',action='store_true')
    parser.add_argument('--soft-mount',action='store_true')
    parser.add_argument('--admit',action='store_true')
    parser.add_argument('--configuration',choices=['debug','release'],default='debug'); args=parser.parse_args()
    local_directory('b10-native-smb')
    case=BASE/str(uuid.UUID(args.case)).upper()
    if args.admit:
        previous=usage()
        if previous['reservedBytes']+16*MIB>128*MIB or previous['reservedEntries']+128>1024:
            raise RuntimeError('No room for the corrected session')
        case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(version=1,bytes=16*MIB,entries=128),sort_keys=True))
        print(json.dumps(dict(admitted=case.name,usage=usage()),indent=2));return
    if case.name!=args.case or not case.is_dir() or case.resolve()!=case: raise RuntimeError('No exact admitted SMB packet')
    before=usage()
    if args.audit: print(json.dumps(before,indent=2)); return
    configuration=args.configuration.title()
    scratch='swift-tests' if args.configuration=='debug' else 'swift-tests-release'
    binary=ROOT/f'.build/{scratch}/out/Products/{configuration}/LocalStorageTests.xctest/Contents/MacOS/LocalStorageTests'
    if args.signed_app:
        if args.configuration!='debug': raise RuntimeError('The controlled signed-app entry is Debug only')
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        if (case/'signed-app-native.json').exists(): raise RuntimeError('Preserved signed-app result is already complete')
    if args.internal_mount and (not args.signed_app or not (case/'internal-mount-approved').is_file() or (case/'internal-mount-used').exists()):
        raise RuntimeError('One-shot temporary comparison is not admitted')
    if args.lifecycle and (not args.internal_mount or not (case/'lifecycle-approved').is_file()):
        raise RuntimeError('Corrected lifecycle session is not admitted')
    if args.soft_mount and (not args.lifecycle or
            (case/'soft-mount-approved').read_bytes()!=('One explicit soft B10 session\n'+case.name+'\n').encode()):
        raise RuntimeError('Explicit soft-mount follow-up is not admitted')
    sources=[Path(__file__).resolve(),binary,ROOT/'Packages/ExplorerKit/Tests/LocalStorageTests/SMBNativeQualificationTests.swift']
    sources.extend(sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('*.swift')))
    sources.extend(sorted((ROOT/'Packages/ExplorerKit/Sources/ExplorerCore').glob('SMB*.swift')))
    sources.append(ROOT/'Packages/ExplorerKit/Sources/ExplorerCore/FileActivityGate.swift')
    if args.signed_app: sources.extend([ROOT/'App/MacExplorer/Development/Checks/UIVerification.swift',ROOT/'App/MacExplorer/App.swift'])
    sources.append(ROOT/'tools/b10_samba_server.py')
    hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    run=case/('runner-'+str(uuid.uuid4()).upper()); run.mkdir(mode=0o700)
    (run/'inputs.json').write_text(json.dumps(hashes,sort_keys=True))
    frozen=run/'frozen-sources';frozen.mkdir(mode=0o700)
    for path in sources:
        if path==binary:continue
        relative=str(path.relative_to(ROOT))
        prior=subprocess.run(['git','show','HEAD:'+relative],cwd=ROOT,capture_output=True)
        if prior.returncode or hashlib.sha256(prior.stdout).hexdigest()!=hashes[relative]:
            (frozen/relative.replace('/','__')).write_bytes(path.read_bytes())
    developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
    helper=developer/'Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
    platform=developer/'Platforms/MacOSX.platform/Developer'
    env=environment(tooling=False)
    env.update(DYLD_FRAMEWORK_PATH=str(platform/'Library/Frameworks'),DYLD_LIBRARY_PATH=str(platform/'usr/lib'),
        MAC_EXPLORER_B10_NATIVE_CASE=str(case),MAC_EXPLORER_STATE_ROOT=str(case/'app-state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'))
    # Build-only Foundation home overrides must not enter a native NetFS process.
    if 'CFFIXED_USER_HOME' in env: raise RuntimeError('Build-only home entered native qualification')
    print('Native SMB runtime: '+str(run.relative_to(ROOT)),flush=True)
    command=[str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--offscreen','--check-smb-native','--analysis-source',str(case)] if args.signed_app else [str(helper),'--test-bundle-path',str(binary),'--testing-library','swift-testing','--filter','SMBNativeQualificationTests']
    if args.internal_mount: command.append('--b10-internal-mount')
    if args.lifecycle:command.append('--b10-lifecycle')
    if args.soft_mount:command.append('--b10-soft-mount')
    return_code=run_native(command,env,run,case,args.lifecycle,(ROOT/'tools/b10_samba_server.py').read_bytes())
    if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in sources):
        raise RuntimeError('Native SMB inputs changed during qualification')
    after=usage()
    (run/'process.json').write_text(json.dumps(dict(returnCode=return_code,usage=after),sort_keys=True))
    if return_code: raise RuntimeError('Native SMB check failed; preserve '+str(run.relative_to(ROOT)))
    if args.signed_app:
        receipt=case/'signed-app-native.json'
        if not receipt.is_file():raise RuntimeError('No signed-app receipt')
        report=json.loads(receipt.read_bytes())
        if report.get('ownedUnmount') is not True or (args.lifecycle and
                (report.get('passed') is not True or report.get('mountRequests')!=2)):
            raise RuntimeError('Signed-app lifecycle is not qualified')
    print(json.dumps(dict(passed=True,root=str(run.relative_to(ROOT)),usage=after),indent=2))

if __name__=='__main__':main()
