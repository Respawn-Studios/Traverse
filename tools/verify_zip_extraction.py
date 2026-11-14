#!/usr/bin/env python3
"""Bounded generated-only guarded ZIP extraction qualification."""
from __future__ import annotations
import argparse
import ctypes
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
BASE=ROOT/'.build/b09-extraction'

def generated_quarantine(source: Path) -> None:
    """Apple's bundled Python omits os.setxattr; use the public fd API."""
    case=source.parent.parent
    if source.name!='Generated.zip' or source.parent.name!='source' or case.parent!=BASE \
        or source.resolve()!=source or str(uuid.UUID(case.name)).upper()!=case.name \
        or not (case/'reservation.json').is_file():raise RuntimeError('Unadmitted generated quarantine fixture')
    data=b'0081;65000001;MacExplorer-B09-Qualification;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B'
    native=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    call=native.fsetxattr;call.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int];call.restype=ctypes.c_int
    fd=os.open(source,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        facts=os.fstat(fd)
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=1 or facts.st_uid!=os.getuid():raise RuntimeError('Unsafe generated archive')
        if call(fd,b'com.apple.quarantine',data,len(data),0,2)!=0:raise RuntimeError('Generated quarantine setup failed ('+str(ctypes.get_errno())+')')
    finally:os.close(fd)

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
        if size>reservation['bytes'] or entries>reservation['entries'] or reservation['bytes']>128*MIB:raise RuntimeError('ZIP extraction case exceeded admission')
        for key,value in dict(bytes=size,entries=entries,reservedBytes=reservation['bytes'],reservedEntries=reservation['entries'],payload=reservation['payload'],evidence=evidence).items():totals[key]+=value
    if totals['reservedBytes']>2048*MIB or totals['reservedEntries']>16384 or totals['payload']>192*MIB or totals['evidence']>32*MIB:raise RuntimeError('ZIP extraction allowance exhausted')
    return totals

def admit(size: int=64*MIB,entries: int=512,payload: int=8*MIB) -> Path:
    local_directory('b09-extraction')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);before=usage()
        if before['reservedBytes']+size>2048*MIB or before['reservedEntries']+entries>16384 or before['payload']+payload>192*MIB:raise RuntimeError('Insufficient ZIP extraction headroom')
        case=BASE/str(uuid.uuid4()).upper();case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size,entries=entries,payload=payload)))
        for name in ('source','evidence'):(case/name).mkdir(mode=0o700)
        return case

def fixture(case: Path,scale: bool,streamed: bool=False,compressible: bool=False) -> Path:
    source=case/'source/Generated.zip';generator=random.Random(0xB093)
    count=8 if scale else 2;length=2*MIB if scale else 128*1024
    class StreamingSink:
        def __init__(self, output):self.output=output
        def write(self, value):return self.output.write(value)
        def tell(self):return self.output.tell()
        def flush(self):return self.output.flush()
        def seek(self, *_):raise OSError('Generated non-seekable ZIP sink')
    with source.open('xb') as output:
        with zipfile.ZipFile(StreamingSink(output) if streamed else output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
            archive.writestr('Empty folder/','');archive.writestr('Empty.txt',b'')
            for index in range(count):
                with archive.open(f'Documents/Stream {index+1:02}.bin','w',force_zip64=streamed and index%2==0) as member:
                    for _ in range(length//65536):member.write(bytes(65536) if compressible else generator.randbytes(65536))
    (case/'evidence/source.json').write_text(json.dumps(dict(sha256=hashlib.sha256(source.read_bytes()).hexdigest(),files=count+1,folders=2,decodedBytes=count*length)))
    return source

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument('--audit',action='store_true');parser.add_argument('--tests',action='store_true')
    parser.add_argument('--native',action='store_true');parser.add_argument('--scale',action='store_true')
    parser.add_argument('--foreground',action='store_true');parser.add_argument('--drive',action='store_true')
    parser.add_argument('--streamed',action='store_true');parser.add_argument('--compressible',action='store_true')
    parser.add_argument('--processes',action='store_true')
    parser.add_argument('--quarantine',action='store_true')
    parser.add_argument('--configuration',choices=('debug','release'),default='debug');args=parser.parse_args()
    if args.quarantine and not (args.native or args.processes):parser.error('--quarantine needs --native or --processes')
    if args.audit:print(json.dumps(usage(),indent=2));return 0
    if args.processes:
        env=environment(tooling=False)
        command=['xcrun','swift','test','--package-path',str(ROOT/'Packages/ExplorerKit'),'--configuration','debug',
            '--scratch-path',str(local_directory('swift-tests')),'--cache-path',str(local_directory('swift-cache')),
            '--config-path',str(local_directory('swift-config')),'--security-path',str(local_directory('swift-security')),
            '--swift-sdks-path',str(local_directory('swift-sdks')),'--disable-keychain','--disable-netrc','--disable-dependency-cache',
            '--manifest-cache','local','--disable-automatic-resolution','--jobs','4','--skip-build','--no-parallel',
            '--filter','ZIPExtractionProcessTests/child']
        binary=ROOT/'.build/swift-tests/out/Products/Debug/LocalStorageTests.xctest/Contents/MacOS/LocalStorageTests'
        inputs=[binary,Path(__file__).resolve(),*sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift')),
            *sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            ROOT/'Packages/ExplorerKit/Tests/LocalStorageTests/ZIPExtractionProcessTests.swift',ROOT/'Packages/ExplorerKit/Tests/LocalStorageTests/ZIPArchiveTests.swift']
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        cases=[]
        boundaries=('produced','intent','rename','reverse-rename') if args.quarantine else ('payloadCreated','produced','synced','intent','rename','committed','reverse-before','reverse-rename')
        for boundary in boundaries:
            case=admit(size=8*MIB,entries=128,payload=4096);report=dict(passed=False,boundary=boundary,inputs=hashes)
            childenv=env.copy();childenv.update(MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_ROOT=str(case),MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_BOUNDARY=boundary)
            if args.quarantine:childenv['MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_QUARANTINE']='1'
            def invoke(action: str,crash: bool=False) -> dict:
                childenv['MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_ACTION']=action
                output=case/'evidence'/f'{action}.log'
                with output.open('x') as stream:result=subprocess.run(command,cwd=ROOT,env=childenv,stdout=stream,stderr=subprocess.STDOUT,timeout=60)
                events=[json.loads(line.split('MAC_EXPLORER_ARCHIVE_CHILD ',1)[1]) for line in output.read_text(errors='replace').splitlines() if 'MAC_EXPLORER_ARCHIVE_CHILD ' in line]
                if len(events)!=1 or (result.returncode==0)==crash or events[0].get('event')!=('crash' if crash else action):raise RuntimeError(f'Extraction process {action}/{boundary} failed; preserve {case.relative_to(ROOT)}')
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
                if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Extraction process inputs changed')
                report['passed']=True
            finally:(case/'evidence/process.json').write_text(json.dumps(report,indent=2,sort_keys=True))
            cases.append(dict(root=str(case.relative_to(ROOT)),boundary=boundary,passed=True))
        print(json.dumps(dict(cases=cases,usage=usage()),indent=2));return 0
    if args.tests:
        import dev
        case=admit();os.environ['MAC_EXPLORER_ZIP_EXTRACTION_TEST_ROOT']=str(case/'source')
        print(f'Generated extraction case: {case.relative_to(ROOT)}',flush=True)
        dev.test('ZIPExtractionTests',configuration=args.configuration,serial=True)
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),usage=usage()),indent=2));return 0
    if args.native:
        case=admit(size=128*MIB if args.scale else 32*MIB,entries=256,payload=33*MIB if args.scale else MIB if args.quarantine else 2*MIB)
        source=fixture(case,args.scale,args.streamed,args.compressible)
        if args.quarantine:
            generated_quarantine(source)
        env=environment(tooling=False);env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
            MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs=[binary,Path(__file__).resolve(),*sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift')),
            *sorted((ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            ROOT/'App/MacExplorer/Features/Archives/ArchiveExtractionWindow.swift',ROOT/'App/MacExplorer/Development/Checks/ArchiveExtractionVerification.swift',source]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        print(f'Generated native extraction case: {case.relative_to(ROOT)}',flush=True)
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-zip-extraction','--analysis-source',str(case)]
                +([] if args.foreground or args.drive else ['--offscreen'])+(['--zip-extraction-scale'] if args.scale else [])
                +(['--drive-zip-extraction'] if args.drive else [])+(['--zip-extraction-streamed'] if args.streamed else [])+(['--zip-extraction-compressible'] if args.compressible else [])
                +(['--zip-extraction-quarantine'] if args.quarantine else []),cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=240 if args.drive else 120)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in inputs):raise RuntimeError('Extraction native inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file():raise RuntimeError(f'Native extraction failed; preserve {case.relative_to(ROOT)}')
        report=json.loads((case/'evidence/native.json').read_bytes());print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2))
        if not report['passed']:raise RuntimeError('Native extraction gates did not pass')
        return 0
    parser.error('Choose --tests, --processes, --native or --audit')

if __name__=='__main__':raise SystemExit(main())
