#!/usr/bin/env python3
"""Admitted generated-only ZIP browser tests; no extraction or personal input."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid
import zipfile

sys.dont_write_bytecode=True
from dev import ROOT, environment, local_directory
MIB=1024**2
BASE=ROOT/'.build/b09-zip-browser'

def usage() -> dict:
    if BASE.resolve()!=BASE: raise RuntimeError('Redirected ZIP qualification root')
    totals=dict(bytes=0,entries=1,reservedBytes=0,reservedEntries=1,payload=0,evidence=0)
    for case in BASE.iterdir():
        if case.name=='.budget.lock':continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():raise RuntimeError('Unknown case')
        reservation=json.loads((case/'reservation.json').read_bytes()); size=0;entries=0;evidence=0;pending=[case]
        while pending:
            path=pending.pop();info=path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISREG,stat.S_ISDIR,stat.S_ISLNK,stat.S_ISFIFO)):
                raise RuntimeError('Unexpected fixture node')
            amount=max(info.st_size,info.st_blocks*512);size+=amount;entries+=1
            if stat.S_ISDIR(info.st_mode):pending.extend(path.iterdir())
            elif path.parent==case/'evidence':evidence+=amount
        if size>reservation['bytes'] or entries>reservation['entries'] or reservation['bytes']>64*MIB:raise RuntimeError('ZIP case exceeded admission')
        for key,value in dict(bytes=size,entries=entries,reservedBytes=reservation['bytes'],reservedEntries=reservation['entries'],payload=reservation['payload'],evidence=evidence).items():totals[key]+=value
    if totals['reservedBytes']>1024*MIB or totals['reservedEntries']>16384 or totals['payload']>32*MIB or totals['evidence']>32*MIB:
        raise RuntimeError('ZIP packet allowance exhausted')
    return totals

def admit(size: int=32*MIB,entries: int=512,payload: int=MIB) -> Path:
    local_directory('b09-zip-browser')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);before=usage()
        if before['reservedBytes']+size>1024*MIB or before['reservedEntries']+entries>16384 or before['payload']+payload>32*MIB:
            raise RuntimeError('Insufficient ZIP packet headroom')
        case=BASE/str(uuid.uuid4()).upper();case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size,entries=entries,payload=payload)))
        for name in ('source','evidence'):(case/name).mkdir(mode=0o700)
        return case

def fixture(case: Path,count: int=32) -> Path:
    source=case/'source/Generated.zip'
    payloads=[('Documents/Notes.txt',b'Generated archive notes. No personal data.\n'),('Documents/Café 日本語.txt',b'Generated Unicode archive member.\n')]
    with zipfile.ZipFile(source,'x',compression=zipfile.ZIP_DEFLATED,allowZip64=True) as archive:
        if count==32:
            for name,data in payloads:archive.writestr(name,data)
            archive.writestr('Empty folder/','')
        for index in range(count):archive.writestr((f'Folder {index//1000:03}/' if count==32 else '')+f'Item {index:06}.txt',b'')
    (case/'evidence/source.json').write_text(json.dumps(dict(sha256=hashlib.sha256(source.read_bytes()).hexdigest(),entries=count+(3 if count==32 else 0),payloadBytes=sum(len(data) for _,data in payloads) if count==32 else 0)))
    return source

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument('--tests',action='store_true');parser.add_argument('--configuration',choices=('debug','release'),default='debug')
    parser.add_argument('--audit',action='store_true');parser.add_argument('--native',action='store_true')
    parser.add_argument('--scale',action='store_true');parser.add_argument('--foreground',action='store_true')
    parser.add_argument('--drive',action='store_true');args=parser.parse_args()
    if args.audit:print(json.dumps(usage(),indent=2));return 0
    if args.tests:
        import dev
        case=admit();os.environ['MAC_EXPLORER_B09_TEST_ROOT']=str(case/'source')
        print(f'Generated ZIP test case: {case.relative_to(ROOT)}',flush=True)
        dev.test('ZIPArchiveTests|ZIPArchiveDiskTests|BrowserShortcutTests',configuration=args.configuration,serial=True)
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),usage=usage()),indent=2));return 0
    if args.native:
        case=admit(size=64*MIB);source=fixture(case,100000 if args.scale else 32)
        env=environment(tooling=False);env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
            MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs=[binary,Path(__file__).resolve(),*sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            ROOT/'App/MacExplorer/Features/Archives/ArchiveBrowser.swift',ROOT/'App/MacExplorer/Development/Checks/ArchiveBrowserVerification.swift',source]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-zip-browser','--analysis-source',str(case)]
                +([] if args.foreground or args.drive else ['--offscreen'])+(['--zip-scale'] if args.scale else [])
                +(['--drive-archive-browser'] if args.drive else []),cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=330 if args.drive else 120)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('ZIP qualification inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file():raise RuntimeError(f'Native ZIP QA failed; preserve {case.relative_to(ROOT)}')
        report=json.loads((case/'evidence/native.json').read_bytes());print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2))
        if not report['passed']:raise RuntimeError('Native ZIP gates did not pass')
        return 0
    parser.error('Choose --tests, --native or --audit')

if __name__=='__main__':raise SystemExit(main())
