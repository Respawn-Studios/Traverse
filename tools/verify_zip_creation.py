#!/usr/bin/env python3
"""Bounded generated-only portable ZIP creation qualification."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import stat
import subprocess
import sys
import uuid
import zipfile

sys.dont_write_bytecode=True
from dev import ROOT, environment, local_directory
MIB=1024**2
BASE=ROOT/'.build/b09-zip-creation'

def usage() -> dict:
    if BASE.resolve()!=BASE:raise RuntimeError('Redirected ZIP creation qualification root')
    totals=dict(bytes=0,entries=1,reservedBytes=0,reservedEntries=1,payload=0,evidence=0)
    for case in BASE.iterdir():
        if case.name=='.budget.lock':continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():raise RuntimeError('Unknown ZIP creation case')
        reservation=json.loads((case/'reservation.json').read_bytes());size=0;entries=0;evidence=0;pending=[case]
        while pending:
            path=pending.pop();info=path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISREG,stat.S_ISDIR,stat.S_ISLNK,stat.S_ISFIFO)):raise RuntimeError('Unexpected creation fixture node')
            amount=max(info.st_size,info.st_blocks*512);size+=amount;entries+=1
            if stat.S_ISDIR(info.st_mode):pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):evidence+=amount
        if size>reservation['bytes'] or entries>reservation['entries'] or reservation['bytes']>128*MIB:raise RuntimeError('ZIP creation case exceeded admission')
        for key,value in dict(bytes=size,entries=entries,reservedBytes=reservation['bytes'],reservedEntries=reservation['entries'],payload=reservation['payload'],evidence=evidence).items():totals[key]+=value
    if totals['reservedBytes']>2048*MIB or totals['reservedEntries']>16384 or totals['payload']>256*MIB or totals['evidence']>64*MIB:raise RuntimeError('ZIP creation allowance exhausted')
    return totals

def admit(size: int=64*MIB,entries: int=1024,payload: int=8*MIB) -> Path:
    local_directory('b09-zip-creation')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);before=usage()
        if before['reservedBytes']+size>2048*MIB or before['reservedEntries']+entries>16384 or before['payload']+payload>256*MIB:raise RuntimeError('Insufficient ZIP creation headroom')
        case=BASE/str(uuid.uuid4()).upper();case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size,entries=entries,payload=payload)))
        for name in ('source','evidence'):(case/name).mkdir(mode=0o700)
        return case

def fixture(case: Path,scale: bool) -> Path:
    source=case/'source/Input';folder=source/'Folder';(folder/'Empty').mkdir(parents=True,mode=0o700)
    generator=random.Random(0xB095);count=8 if scale else 2;length=2*MIB if scale else 128*1024
    for index in range(count):
        with (folder/f'Stream {index+1:02}.bin').open('xb') as stream:
            for _ in range(length//65536):stream.write(generator.randbytes(65536))
    (folder/'Zero.txt').write_bytes(b'');(source/'Root.txt').write_bytes(b'generated root')
    hashes={str(path.relative_to(source)):hashlib.sha256(path.read_bytes()).hexdigest() for path in source.rglob('*') if path.is_file()}
    (case/'evidence/source.json').write_text(json.dumps(dict(hashes=hashes,files=count+2,folders=2,logicalBytes=count*length+14)))
    return source

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
            '--filter','ZIPCreationProcessTests/child']
        binary=ROOT/'.build/swift-tests/out/Products/Debug/LocalStorageTests.xctest/Contents/MacOS/LocalStorageTests'
        inputs=[binary,Path(__file__).resolve(),*sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift')),
            *sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            ROOT/'Packages/ExplorerKit/Tests/LocalStorageTests/ZIPCreationProcessTests.swift',ROOT/'Packages/ExplorerKit/Tests/LocalStorageTests/ZIPArchiveTests.swift']
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        cases=[]
        for boundary in ('payloadCreated','produced','synced','intent','rename','committed','reverse-before','reverse-rename'):
            case=admit(size=8*MIB,entries=128,payload=4096);report=dict(passed=False,boundary=boundary,inputs=hashes)
            childenv=env.copy();childenv.update(MAC_EXPLORER_ZIP_CREATION_PROCESS_ROOT=str(case),MAC_EXPLORER_ZIP_CREATION_PROCESS_BOUNDARY=boundary)
            def invoke(action: str,crash: bool=False) -> dict:
                childenv['MAC_EXPLORER_ZIP_CREATION_PROCESS_ACTION']=action
                output=case/'evidence'/f'{action}.log'
                with output.open('x') as stream:result=subprocess.run(command,cwd=ROOT,env=childenv,stdout=stream,stderr=subprocess.STDOUT,timeout=60)
                events=[json.loads(line.split('MAC_EXPLORER_ARCHIVE_CHILD ',1)[1]) for line in output.read_text(errors='replace').splitlines() if 'MAC_EXPLORER_ARCHIVE_CHILD ' in line]
                if len(events)!=1 or (result.returncode==0)==crash or events[0].get('event')!=('crash' if crash else action):raise RuntimeError(f'Creation process {action}/{boundary} failed; preserve {case.relative_to(ROOT)}')
                return events[0]
            def snapshot() -> dict:
                return {str(path.relative_to(case)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (case/'source').rglob('*') if path.is_file()}
            try:
                report['interrupted']=invoke('reverse' if boundary.startswith('reverse-') else 'forward',True)
                before=snapshot();report['inspection']=invoke('inspect')
                if snapshot()!=before:raise RuntimeError('Passive crash inspection changed generated files/catalog')
                shutil.copytree(case/'source/Process/journal',case/'evidence/catalog-before-recovery')
                report['recovery']=invoke('recover')
                if len({report[key]['pid'] for key in ('interrupted','inspection','recovery')})!=3:raise RuntimeError('Crash qualification reused its process')
                if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Creation process inputs changed')
                report['passed']=True
            finally:(case/'evidence/process.json').write_text(json.dumps(report,indent=2,sort_keys=True))
            cases.append(dict(root=str(case.relative_to(ROOT)),boundary=boundary,passed=True))
        print(json.dumps(dict(cases=cases,usage=usage()),indent=2));return 0
    if args.tests:
        import dev
        case=admit();os.environ['MAC_EXPLORER_ZIP_CREATION_TEST_ROOT']=str(case/'source')
        print(f'Generated creation case: {case.relative_to(ROOT)}',flush=True)
        dev.test('ZIPCreationTests',configuration=args.configuration,serial=True)
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),usage=usage()),indent=2));return 0
    if args.native:
        case=admit(size=128*MIB if args.scale else 32*MIB,entries=256,payload=50*MIB if args.scale else 3*MIB)
        source=fixture(case,args.scale)
        env=environment(tooling=False);env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
            MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs=[binary,Path(__file__).resolve(),*sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift')),
            *sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            ROOT/'App/MacExplorer/Features/Archives/ArchiveCreationWindow.swift',ROOT/'App/MacExplorer/Development/Checks/ArchiveCreationVerification.swift',*sorted(path for path in source.rglob('*') if path.is_file())]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        print(f'Generated native creation case: {case.relative_to(ROOT)}',flush=True)
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-zip-creation','--analysis-source',str(case)]
                +([] if args.foreground or args.drive else ['--offscreen'])+(['--zip-creation-scale'] if args.scale else [])
                +(['--drive-zip-creation'] if args.drive else []),cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=240 if args.drive else 120)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Creation native inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file():raise RuntimeError(f'Native creation failed; preserve {case.relative_to(ROOT)}')
        report=json.loads((case/'evidence/native.json').read_bytes())
        expected=json.loads((case/'evidence/source.json').read_bytes())['hashes']
        with zipfile.ZipFile(case/'evidence/Created.zip') as archive:
            if archive.testzip() is not None:raise RuntimeError('Independent Python ZIP CRC validation failed')
            actual={item.filename:hashlib.sha256(archive.read(item)).hexdigest() for item in archive.infolist() if not item.is_dir()}
            if actual!=expected:raise RuntimeError('Independent Python ZIP source comparison failed')
        report['independentPythonContents']=True
        (case/'evidence/native-independent.json').write_text(json.dumps(report,indent=2,sort_keys=True))
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2))
        if not report['passed']:raise RuntimeError('Native creation gates did not pass')
        return 0
    parser.error('Choose --tests, --processes, --native or --audit')

if __name__=='__main__':raise SystemExit(main())
