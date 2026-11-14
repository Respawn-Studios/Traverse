#!/usr/bin/env python3
"""Bounded generated-only selected ZIP extraction qualification."""
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
BASE=ROOT/'.build/b09-selected-extraction'

def usage() -> dict:
    if BASE.resolve()!=BASE:raise RuntimeError('Redirected ZIP extraction qualification root')
    totals=dict(bytes=0,entries=1,reservedBytes=0,reservedEntries=1,payload=0,evidence=0)
    for case in BASE.iterdir():
        if case.name=='.budget.lock':continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():raise RuntimeError('Unknown ZIP extraction case')
        reservation=json.loads((case/'reservation.json').read_bytes());size=0;entries=0;evidence=0;pending=[case]
        while pending:
            path=pending.pop();info=path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISREG,stat.S_ISDIR,stat.S_ISLNK,stat.S_ISFIFO)):raise RuntimeError('Unexpected extraction fixture node')
            amount=max(info.st_size,info.st_blocks*512);size+=amount;entries+=1
            if stat.S_ISDIR(info.st_mode):pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):evidence+=amount
        if size>reservation['bytes'] or entries>reservation['entries'] or reservation['bytes']>64*MIB:raise RuntimeError('ZIP extraction case exceeded admission')
        for key,value in dict(bytes=size,entries=entries,reservedBytes=reservation['bytes'],reservedEntries=reservation['entries'],payload=reservation['payload'],evidence=evidence).items():totals[key]+=value
    if totals['reservedBytes']>1024*MIB or totals['reservedEntries']>8192 or totals['payload']>64*MIB or totals['evidence']>32*MIB:raise RuntimeError('ZIP extraction allowance exhausted')
    return totals

def admit(size: int=32*MIB,entries: int=512,payload: int=MIB) -> Path:
    local_directory('b09-selected-extraction')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);before=usage()
        if before['reservedBytes']+size>1024*MIB or before['reservedEntries']+entries>8192 or before['payload']+payload>64*MIB:raise RuntimeError('Insufficient ZIP extraction headroom')
        case=BASE/str(uuid.uuid4()).upper();case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size,entries=entries,payload=payload)))
        for name in ('source','evidence'):(case/name).mkdir(mode=0o700)
        return case

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument('--audit',action='store_true');parser.add_argument('--tests',action='store_true')
    parser.add_argument('--native',action='store_true');parser.add_argument('--foreground',action='store_true');parser.add_argument('--drive',action='store_true')
    parser.add_argument('--configuration',choices=('debug','release'),default='debug');args=parser.parse_args()
    if args.audit:print(json.dumps(usage(),indent=2));return 0
    if args.tests:
        import dev
        case=admit(payload=128*1024);os.environ['MAC_EXPLORER_ZIP_SELECTED_TEST_ROOT']=str(case/'source')
        print(f'Generated selected extraction case: {case.relative_to(ROOT)}',flush=True)
        dev.test('ZIPSelectedExtractionTests|ZIPArchiveTests',configuration=args.configuration,serial=True)
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),usage=usage()),indent=2));return 0
    if args.native:
        case=admit(size=64*MIB,entries=512,payload=20*MIB)
        source=case/'source/Generated.zip';generator=random.Random(0xB097)
        members={'Selected/Keep.txt':b'generated selected body'*4096,'Selected/Deep/Nested.bin':b'generated nested data'*4096}
        with zipfile.ZipFile(source,'w',compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('Selected/Empty/','')
            for name,body in members.items():archive.writestr(name,body)
            with archive.open('Unselected.bin','w') as member:
                for _ in range(256):member.write(generator.randbytes(65536))
        expected={name:hashlib.sha256(body).hexdigest() for name,body in members.items()}
        before=hashlib.sha256(source.read_bytes()).hexdigest()
        (case/'evidence/source.json').write_text(json.dumps(dict(archiveSHA256=before,selectedHashes=expected,logicalBytes=sum(map(len,members.values())))))
        env=environment(tooling=False);env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
            MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs=[binary,Path(__file__).resolve(),ROOT/'App/MacExplorer/Features/Archives/ArchiveBrowser.swift',ROOT/'App/MacExplorer/Features/Archives/ArchiveExtractionWindow.swift',
            ROOT/'App/MacExplorer/Development/Checks/SelectedArchiveExtractionVerification.swift',*sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            *sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift'))]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        print(f'Generated native selected extraction case: {case.relative_to(ROOT)}',flush=True)
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-selected-extraction','--analysis-source',str(case)]
                +([] if args.foreground or args.drive else ['--offscreen'])+(['--drive-selected-extraction'] if args.drive else []),
                cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=240 if args.drive else 120)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Selected extraction inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file():raise RuntimeError(f'Native selected extraction failed; preserve {case.relative_to(ROOT)}')
        if hashlib.sha256(source.read_bytes()).hexdigest()!=before:raise RuntimeError('Selected extraction changed its original archive')
        actual=json.loads((case/'evidence/output.json').read_bytes())
        if actual!=expected:raise RuntimeError('Selected output differs from independent Python archive source')
        report=json.loads((case/'evidence/native.json').read_bytes());report['independentPythonContents']=True
        (case/'evidence/native-independent.json').write_text(json.dumps(report,indent=2,sort_keys=True))
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2))
        if not report['passed']:raise RuntimeError('Selected extraction gates did not pass')
        return 0
    parser.error('Choose --tests, --native or --audit')

if __name__=='__main__':raise SystemExit(main())
