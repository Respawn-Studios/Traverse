#!/usr/bin/env python3
"""Generated-only admission for the bounded Duplicate packet."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode=True
from dev import ROOT, environment, local_directory
MIB=1024**2
BASE=ROOT/'.build/b09-duplicate'

def usage() -> dict:
    if BASE.resolve()!=BASE:raise RuntimeError('Redirected Duplicate root')
    totals=dict(bytes=0,entries=1,reservedBytes=0,reservedEntries=1,payload=0,evidence=0)
    for case in BASE.iterdir():
        if case.name=='.budget.lock':continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():raise RuntimeError('Unknown Duplicate case')
        reservation=json.loads((case/'reservation.json').read_bytes());size=0;entries=0;evidence=0;pending=[case]
        while pending:
            path=pending.pop();info=path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISREG,stat.S_ISDIR,stat.S_ISLNK,stat.S_ISFIFO)):raise RuntimeError('Unexpected fixture node')
            amount=max(info.st_size,info.st_blocks*512);size+=amount;entries+=1
            if stat.S_ISDIR(info.st_mode):pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):evidence+=amount
        if size>reservation['bytes'] or entries>reservation['entries'] or reservation['bytes']>64*MIB:raise RuntimeError('Duplicate case exceeded admission')
        for key,value in dict(bytes=size,entries=entries,reservedBytes=reservation['bytes'],reservedEntries=reservation['entries'],payload=reservation['payload'],evidence=evidence).items():totals[key]+=value
    if totals['reservedBytes']>1024*MIB or totals['reservedEntries']>16384 or totals['payload']>64*MIB or totals['evidence']>32*MIB:raise RuntimeError('Duplicate allowance exhausted')
    return totals

def admit(size: int=16*MIB,entries: int=256,payload: int=MIB) -> Path:
    local_directory('b09-duplicate')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);before=usage()
        if before['reservedBytes']+size>1024*MIB or before['reservedEntries']+entries>16384 or before['payload']+payload>64*MIB:raise RuntimeError('Insufficient Duplicate headroom')
        case=BASE/str(uuid.uuid4()).upper();case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size,entries=entries,payload=payload)))
        for name in ('source','evidence'):(case/name).mkdir(mode=0o700)
        return case

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument('--audit',action='store_true');parser.add_argument('--tests',action='store_true')
    parser.add_argument('--native',action='store_true');parser.add_argument('--scale',action='store_true')
    parser.add_argument('--foreground',action='store_true');parser.add_argument('--drive',action='store_true')
    parser.add_argument('--processes',action='store_true')
    parser.add_argument('--configuration',choices=('debug','release'),default='debug');args=parser.parse_args()
    if args.audit:print(json.dumps(usage(),indent=2));return 0
    if args.processes:
        env=environment(tooling=False)
        command=['xcrun','swift','test','--package-path',str(ROOT/'Packages/ExplorerKit'),'--configuration','debug',
            '--scratch-path',str(local_directory('swift-tests')),'--cache-path',str(local_directory('swift-cache')),
            '--config-path',str(local_directory('swift-config')),'--security-path',str(local_directory('swift-security')),
            '--swift-sdks-path',str(local_directory('swift-sdks')),'--disable-keychain','--disable-netrc','--disable-dependency-cache',
            '--manifest-cache','local','--disable-automatic-resolution','--jobs','4','--skip-build','--no-parallel',
            '--filter','DuplicateProcessTests/child']
        binary=ROOT/'.build/swift-tests/out/Products/Debug/FileOperationsTests.xctest/Contents/MacOS/FileOperationsTests'
        inputs=[binary,Path(__file__).resolve(),ROOT/'Packages/ExplorerKit/Tests/FileOperationsTests/DuplicateProcessTests.swift',
            *sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift'))]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs};cases=[]
        for boundary in ('intent','rename','committed','reverse-before','reverse-rename'):
            case=admit(size=8*MIB,entries=128,payload=4096);report=dict(passed=False,boundary=boundary,inputs=hashes)
            childenv=env.copy();childenv.update(MAC_EXPLORER_DUPLICATE_PROCESS_ROOT=str(case),MAC_EXPLORER_DUPLICATE_PROCESS_BOUNDARY=boundary)
            def invoke(action: str,crash: bool=False) -> dict:
                childenv['MAC_EXPLORER_DUPLICATE_PROCESS_ACTION']=action
                output=case/'evidence'/f'{action}.log'
                with output.open('x') as stream:result=subprocess.run(command,cwd=ROOT,env=childenv,stdout=stream,stderr=subprocess.STDOUT,timeout=60)
                events=[json.loads(line.split('MAC_EXPLORER_DUPLICATE_CHILD ',1)[1]) for line in output.read_text(errors='replace').splitlines() if 'MAC_EXPLORER_DUPLICATE_CHILD ' in line]
                if len(events)!=1 or (result.returncode==0)==crash or events[0].get('event')!=('crash' if crash else action):raise RuntimeError(f'Duplicate process {action}/{boundary} failed; preserve {case.relative_to(ROOT)}')
                return events[0]
            def snapshot() -> dict:
                return {str(path.relative_to(case)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (case/'source').rglob('*') if path.is_file()}
            try:
                report['interrupted']=invoke('reverse' if boundary.startswith('reverse-') else 'forward',True)
                before=snapshot();report['inspection']=invoke('inspect')
                if snapshot()!=before:raise RuntimeError('Passive Duplicate inspection changed original evidence')
                shutil.copytree(case/'source/journal',case/'evidence/catalog-before-recovery');report['recovery']=invoke('recover')
                if len({report[key]['pid'] for key in ('interrupted','inspection','recovery')})!=3:raise RuntimeError('Duplicate crash qualification reused a process')
                if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Duplicate process inputs changed')
                report['passed']=True
            finally:(case/'evidence/process.json').write_text(json.dumps(report,indent=2,sort_keys=True))
            cases.append(dict(root=str(case.relative_to(ROOT)),boundary=boundary,passed=True))
        print(json.dumps(dict(cases=cases,usage=usage()),indent=2));return 0
    if args.tests:
        import dev
        case=admit(size=32*MIB,entries=1024,payload=MIB)
        os.environ['MAC_EXPLORER_DUPLICATE_TEST_ROOT']=str(case/'source')
        print(f'Generated Duplicate case: {case.relative_to(ROOT)}',flush=True)
        dev.test('DuplicateTests|BrowserShortcutTests',configuration=args.configuration,serial=True)
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),usage=usage()),indent=2));return 0
    if args.native:
        case=admit(size=64*MIB if args.scale else 16*MIB,entries=1024 if args.scale else 256,payload=16*MIB if args.scale else MIB)
        parent=case/'source/Items';parent.mkdir(mode=0o700)
        if args.scale:
            for index in range(128):(parent/f'File {index:03}.bin').write_bytes(bytes([index])*32768)
        else:
            (parent/'Report.txt').write_text('generated report')
            for name in ('Folder','Example.app'):
                (parent/name).mkdir();(parent/name/'Nested.txt').write_text('generated nested')
        env=environment(tooling=False);env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
            MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs=[binary,Path(__file__).resolve(),ROOT/'App/MacExplorer/Browser/BrowserDuplicate.swift',ROOT/'App/MacExplorer/Development/Checks/DuplicateVerification.swift',
            ROOT/'App/MacExplorer/Application/ApplicationTransferQueue.swift',ROOT/'App/MacExplorer/Browser/BrowserViewController.swift',
            ROOT/'App/MacExplorer/Browser/BrowserShortcutRouting.swift',ROOT/'Packages/ExplorerKit/Sources/ExplorerCore/BrowserShortcuts.swift',
            *sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift'))]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        print(f'Generated native Duplicate case: {case.relative_to(ROOT)}',flush=True)
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-duplicate','--analysis-source',str(case)]
                +([] if args.foreground or args.drive else ['--offscreen'])+(['--duplicate-scale'] if args.scale else [])
                +(['--drive-duplicate'] if args.drive else []),cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=240 if args.drive else 120)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Duplicate native inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file():raise RuntimeError(f'Native Duplicate failed; preserve {case.relative_to(ROOT)}')
        report=json.loads((case/'evidence/native.json').read_bytes())
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2))
        if not report['passed']:raise RuntimeError('Native Duplicate gates did not pass')
        return 0
    parser.error('Choose --tests, --native or --audit')

if __name__=='__main__':raise SystemExit(main())
