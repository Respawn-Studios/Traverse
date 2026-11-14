#!/usr/bin/env python3
"""Generated-only admission for the bounded batch Rename packet."""
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
BASE=ROOT/'.build/b09-batch-rename'

def usage() -> dict:
    if BASE.resolve()!=BASE:raise RuntimeError('Redirected batch Rename root')
    totals=dict(bytes=0,entries=1,reservedBytes=0,reservedEntries=1,payload=0,evidence=0)
    for case in BASE.iterdir():
        if case.name=='.budget.lock':continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():raise RuntimeError('Unknown batch Rename case')
        reservation=json.loads((case/'reservation.json').read_bytes());size=0;entries=0;evidence=0;pending=[case]
        while pending:
            path=pending.pop();info=path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISREG,stat.S_ISDIR,stat.S_ISLNK,stat.S_ISFIFO)):raise RuntimeError('Unexpected fixture node')
            amount=max(info.st_size,info.st_blocks*512);size+=amount;entries+=1
            if stat.S_ISDIR(info.st_mode):pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):evidence+=amount
        if size>reservation['bytes'] or entries>reservation['entries'] or reservation['bytes']>64*MIB:raise RuntimeError('Batch Rename case exceeded admission')
        for key,value in dict(bytes=size,entries=entries,reservedBytes=reservation['bytes'],reservedEntries=reservation['entries'],payload=reservation['payload'],evidence=evidence).items():totals[key]+=value
    if totals['reservedBytes']>512*MIB or totals['reservedEntries']>8192 or totals['payload']>16*MIB or totals['evidence']>16*MIB:raise RuntimeError('Batch Rename allowance exhausted')
    return totals

def admit(size: int=16*MIB,entries: int=256,payload: int=MIB) -> Path:
    local_directory('b09-batch-rename')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);before=usage()
        if before['reservedBytes']+size>512*MIB or before['reservedEntries']+entries>8192 or before['payload']+payload>16*MIB:raise RuntimeError('Insufficient batch Rename headroom')
        case=BASE/str(uuid.uuid4()).upper();case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size,entries=entries,payload=payload)))
        for name in ('source','evidence'):(case/name).mkdir(mode=0o700)
        return case

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument('--audit',action='store_true')
    parser.add_argument('--tests',action='store_true');parser.add_argument('--configuration',choices=('debug','release'),default='debug')
    parser.add_argument('--native',action='store_true');parser.add_argument('--scale',action='store_true')
    parser.add_argument('--foreground',action='store_true');parser.add_argument('--drive',action='store_true')
    parser.add_argument('--processes',action='store_true')
    args=parser.parse_args()
    if args.audit:print(json.dumps(usage(),indent=2));return 0
    if args.processes:
        sources=sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift'))
        worker=ROOT/'tools/BatchRenameQualificationWorker.swift';inputs=[*sources,worker,Path(__file__).resolve()]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        identity=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
        binaries=local_directory('batch-rename-worker');binary=binaries/identity
        env=environment(tooling=False);compiler_log=binaries/(identity+'.log')
        command=['xcrun','swiftc','-O','-swift-version','6','-warnings-as-errors','-parse-as-library','-j','2','-num-threads','2',
            '-module-cache-path',str(local_directory('compiler-cache/batch-rename-worker')),'-o',str(binary),*[str(path) for path in sources],str(worker)]
        if not binary.exists():
            with compiler_log.open('x') as output:subprocess.run(command,cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=300,check=True)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Batch process build inputs changed')
        cases=[]
        for phase,boundary in [('forward','first-commit'),('forward','second-intent'),('forward','second-syscall'),('forward','second-commit'),('reverse','first-commit'),('reverse','second-syscall')]:
            case=admit(size=8*MIB,entries=96,payload=4096)
            report=dict(phase=phase,boundary=boundary,passed=False,sourceHashes=hashes,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),compilerLog=str(compiler_log.relative_to(ROOT)))
            def invoke(action: str,expected: int=0) -> dict:
                child=subprocess.run([str(binary),action,str(case),boundary],cwd=ROOT,env=env,capture_output=True,text=True,timeout=60)
                (case/'evidence'/f'{action}.log').write_text(child.stdout+child.stderr)
                if child.returncode!=expected:raise RuntimeError(f'Batch child {action}/{boundary} exited {child.returncode}; preserve {case.relative_to(ROOT)}')
                return json.loads(child.stdout)
            try:
                report['interrupted']=invoke(phase,86)
                before={str(path.relative_to(case)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (case/'source').rglob('*') if path.is_file()}
                report['inspected']=invoke('inspect')
                after={str(path.relative_to(case)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (case/'source').rglob('*') if path.is_file()}
                if before!=after:raise RuntimeError('Passive batch crash inspection changed its generated files/catalog')
                shutil.copytree(case/'source/journal',case/'evidence/catalog-before-recovery')
                report['recovered']=invoke('recover')
                if len({report[key]['pid'] for key in ('interrupted','inspected','recovered')})!=3:raise RuntimeError('Batch process evidence reused a process')
                report['passed']=True
            finally:(case/'evidence/process.json').write_text(json.dumps(report,indent=2,sort_keys=True))
            cases.append(dict(root=str(case.relative_to(ROOT)),phase=phase,boundary=boundary,passed=True))
        print(json.dumps(dict(cases=cases,usage=usage()),indent=2));return 0
    if args.tests:
        import dev
        case=admit();os.environ['MAC_EXPLORER_BATCH_RENAME_TEST_ROOT']=str(case/'source')
        print(f'Generated batch Rename test case: {case.relative_to(ROOT)}',flush=True)
        dev.test('BatchRenameRuleTests|BatchRenameTests',configuration=args.configuration,serial=True)
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),usage=usage()),indent=2));return 0
    if args.native:
        case=admit(size=16*MIB,entries=768 if args.scale else 256)
        parent=case/'source/Items';parent.mkdir(mode=0o700)
        if args.scale:
            for index in range(512):(parent/f'Item {index:04}.txt').write_bytes(f'Generated Rename item {index}.\n'.encode())
        else:
            (parent/'A.txt').write_bytes(b'Generated A.\n');(parent/'B.txt').write_bytes(b'Generated B.\n')
            (parent/'Folder').mkdir();(parent/'Folder/Child.txt').write_bytes(b'Generated child.\n')
        env=environment(tooling=False);env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
            MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs=[binary,Path(__file__).resolve(),*sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift')),
            *sorted((ROOT/'App/MacExplorer').glob('*.swift'))]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-batch-rename','--analysis-source',str(case)]
                +([] if args.foreground or args.drive else ['--offscreen'])+(['--batch-rename-scale'] if args.scale else [])
                +(['--drive-batch-rename'] if args.drive else []),cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=330 if args.drive else 150)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Batch Rename qualification inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file():raise RuntimeError(f'Native batch Rename failed; preserve {case.relative_to(ROOT)}')
        report=json.loads((case/'evidence/native.json').read_bytes());print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2))
        if not report['passed']:raise RuntimeError('Native batch Rename gates did not pass')
        return 0
    parser.error('Choose --tests, --native, --processes or --audit')

if __name__=='__main__':raise SystemExit(main())
