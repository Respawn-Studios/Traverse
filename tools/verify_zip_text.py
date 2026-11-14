#!/usr/bin/env python3
"""Focused generated ZIP text-preview controls; no personal source or network."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid
import zipfile

sys.dont_write_bytecode=True
import dev
from zip_text_packet import reserve,audit,put,ROOT,MIB
from qualify_foundation import wait_generated


def test_counts(text,expected,regressions):
    # The framework's final "Test run with ..." line is not another test.
    completed=re.findall(r'^✔ Test ([^\n]*\([^\n]*\)) passed after ',text,re.M)
    skipped=re.findall(r'^➜ Test ([^\n]+) skipped\.',text,re.M)
    allowed={'selectedArchiveReadChangesNoSourceAndMaterializesNoMembers()', 'realSourceReplacementAndPathRedirectionAreRefused()',
        'cancelledMetadataReadRetainsActualActivityUntilDrained()', 'explicitCheckDoesNotMaterializeOrChangeTheSource()',
        'changedSourceCannotBeReportedAsACorruptStableArchive()', 'cancelledBodyCheckRetainsActualLeaseAndRefusesOverlappingReads()'}
    passed=len(completed)==expected and len(set(completed))==expected \
        and (not skipped or regressions and set(skipped).issubset(allowed)) \
        and bool(re.search(r'Test run with '+str(expected+len(skipped))+r' tests.*passed',text))
    return dict(passed=bool(passed),executedTests=len(completed),notExercised=skipped)


def native(args):
    if args.case:
        if str(uuid.UUID(args.case)).upper()!=args.case:raise RuntimeError('Canonical ZIP preview case required')
        case=ROOT/args.case
        if case.resolve()!=case or json.loads((case/'reservation.json').read_bytes()).get('action')!='native-100k':
            raise RuntimeError('Generated native preview reservation required')
    else:
        case=reserve('native-100k')
        with zipfile.ZipFile(case/'source/Generated.zip','x',compression=zipfile.ZIP_STORED,allowZip64=True) as archive:
            archive.writestr('Docs/Readme.txt','Generated read-only ZIP preview\n\nCafé · 日本語 · 👩‍💻\n\nThis is generated text. No personal document is involved.\n<html>stays plain text</html>\n')
            archive.writestr('Docs/Second.txt','Generated second member.\n')
            archive.writestr('Docs/Binary.bin',bytes([0,1,2,255]))
            text=('Generated complete-boundary text line.\n'*8000).encode()[:256*1024]
            archive.writestr('Docs/Limit.txt',text)
            for index in range(99_996):archive.writestr(f'Generated {index:06}.bin',b'')
    count=len(list((case/'evidence').glob('process-*.json')))
    # Five retained entries include two normal runs, two debugger traces and a
    # failed debugger submission which never launched the app. The consolidated
    # allowance admits the repaired native surface and final shipped checks.
    if count>=8:raise RuntimeError('Native ZIP preview launch allowance exhausted')
    run=count+1
    binary=dev.APP/'Contents/MacOS/Mac Explorer'
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(dev.APP)],check=True,capture_output=True,timeout=30)
    hashes={str(path.relative_to(dev.ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [binary,Path(__file__).resolve(),*sorted((dev.ROOT/'App/MacExplorer').glob('Archive*.swift')),
            *sorted((dev.ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift'))]}
    put(case/f'inputs-{run}.json',dict(hashes=hashes,sourceSHA256=hashlib.sha256((case/'source/Generated.zip').read_bytes()).hexdigest(),
        members=100000,generatedOnly=True,compositorCapture=args.capture))
    env=dev.environment(tooling=False)
    env.update(MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'))
    command=[str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-zip-text-preview','--analysis-source',str(case)]
    command+=['--capture-zip-text-preview'] if args.capture else ['--offscreen']
    log=case/f'evidence/native-{run}.log';began=time.monotonic()
    with log.open('xb') as stream:
        child=subprocess.Popen(command,cwd=dev.ROOT,env=env,stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        put(case/f'evidence/process-{run}.json',dict(pid=child.pid,generatedOnly=True))
        stats,failure,contained,forced=wait_generated(child,log,case/'evidence',deadline=120)
    file=case/'evidence/native.json';report=json.loads(file.read_bytes()) if file.is_file() else None
    passed=child.returncode==0 and failure is None and report is not None and report.get('passed') is True and stats.ru_maxrss<=256*MIB
    reentrant='reentrant operation in its NSTableView delegate' in log.read_text(errors='replace')
    if reentrant:passed=False;failure='Native table delegate reentrancy warning'
    if any(hashlib.sha256((dev.ROOT/key).read_bytes()).hexdigest()!=value for key,value in hashes.items()):passed=False;failure='Native ZIP preview inputs changed'
    if report is not None:file.rename(case/f'evidence/native-result-{run}.json')
    for image in ['preview-content.png','preview-window.png']:
        if (case/'evidence'/image).is_file():(case/'evidence'/image).rename(case/'evidence'/image.replace('.png',f'-{run}.png'))
    put(case/f'result-{run}.json',dict(passed=passed,native=report,actualExit=child.returncode,failure=failure,
        parentPeakRSSBytes=stats.ru_maxrss,elapsedSeconds=time.monotonic()-began,generatedContainment=contained,
        forcedContainment=forced,nativeTableReentrancyWarning=reentrant,packet=audit()))
    print(json.dumps(dict(case=case.name,run=run,passed=passed,report=report,peakRSSBytes=stats.ru_maxrss)),flush=True)
    if not passed:raise SystemExit(1)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--configuration',choices=['debug','release'],default='debug')
    parser.add_argument('--native',action='store_true');parser.add_argument('--capture',action='store_true');parser.add_argument('--case')
    parser.add_argument('--regressions',action='store_true');args=parser.parse_args()
    if args.capture and not args.native:parser.error('Capture requires a native generated run')
    if args.case and not args.native:parser.error('Only read-only native fixtures may be reused')
    if args.native and args.configuration!='debug':parser.error('Native qualification hooks are DEBUG-only; Release is built separately')
    if args.native:native(args);return
    case=reserve('core-'+args.configuration+('-parser-regressions' if args.regressions else ''),amount=32*MIB,entries=256)
    os.environ['MAC_EXPLORER_ZIP_TEXT_TEST_ROOT']=str(case/'source')
    inputs={str(p.relative_to(dev.ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [*sorted((dev.ROOT/'Packages/ExplorerKit/Sources/LocalStorage').glob('ZIP*.swift')),
            dev.ROOT/'Packages/ExplorerKit/Tests/LocalStorageTests/ZIPTextPreviewTests.swift']}
    put(case/'inputs.json',dict(hashes=inputs,metadataOnlyDefault=True,automaticBodyReads=0,personalFiles=0))
    before=set((dev.BUILD/'logs').glob('test-*.log'));failure=None
    pattern='ZIPTextPreviewTests|ZIPArchiveTests|ZIPContentTests|ZIPDataDescriptorTests' if args.regressions else 'ZIPTextPreviewTests'
    expected=39 if args.regressions else 18
    not_exercised=[]
    try:dev.test(pattern,configuration=args.configuration,serial=True)
    except Exception:failure='Focused ZIP preview test execution failed'
    logs=set((dev.BUILD/'logs').glob('test-*.log'))-before
    if len(logs)!=1:failure='Exact focused test log missing'
    else:
        log=logs.pop();shutil.copyfile(log,case/'evidence/tests.log')
        text=log.read_text(errors='replace')
        counts=test_counts(text,expected,args.regressions)
        if not counts['passed']:
            failure=failure or 'Expected executed preview/parser controls differ; inspect retained discovery skips'
        not_exercised=counts['notExercised']
    if any(hashlib.sha256((dev.ROOT/key).read_bytes()).hexdigest()!=value for key,value in inputs.items()):failure='ZIP preview inputs changed during qualification'
    put(case/'result.json',dict(passed=failure is None,failure=failure,executedTests=expected if failure is None else None,
        notExercised=not_exercised,notExercisedReason='Separate older disk-suite environments are not admitted by this packet',
        packet=audit(),personalFiles=0,networkRequests=0))
    print(json.dumps(dict(case=case.name,passed=failure is None,failure=failure)),flush=True)
    if failure:raise SystemExit(1)


if __name__=='__main__':main()
