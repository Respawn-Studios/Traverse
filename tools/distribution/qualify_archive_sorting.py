#!/usr/bin/env python3
"""Finite generated-only ordering of complete ZIP metadata results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import zipfile

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,reserve,put,audit,measure,MIB
from qualify_foundation import wait_generated


def digest(path):
    value=hashlib.sha256()
    with path.open('rb')as stream:
        for block in iter(lambda:stream.read(65536),b''):value.update(block)
    return value.hexdigest()


def native(args):
    root=reserve('traverse-archive-sorting');(root/'source/Destination').mkdir(mode=0o700)
    with zipfile.ZipFile(root/'source/Small.zip','x',compression=zipfile.ZIP_DEFLATED)as archive:
        for i in range(600):
            archive.writestr(f'Folder/Entry {i:03}.txt',b'S'*i,compress_type=zipfile.ZIP_STORED if i%3==0 else zipfile.ZIP_DEFLATED)
        archive.writestr('Read me.txt',b'Generated ordering fixture.\n')
    if not args.record_motion:
        with zipfile.ZipFile(root/'source/Large.zip','x',compression=zipfile.ZIP_DEFLATED)as archive:
            for i in range(100000):archive.writestr(f'Item {i:06}.txt',b'X'*(i%997))
    initial={p.name:digest(p)for p in (root/'source').iterdir()if p.is_file()}
    with zipfile.ZipFile(root/'source/Small.zip')as archive:records=[x for x in archive.infolist()if x.filename.startswith('Folder/')]
    def natural(name):return tuple(int(x)if x.isdigit()else x.casefold()for x in re.split(r'(\d+)',name))
    def primary(record,field):
        if field=='logical':return record.file_size
        if field=='packed':return record.compress_size
        if field=='method':return natural('Stored'if record.compress_type==0 else 'Deflate')
        return natural(Path(record.filename).name)
    expected={}
    for field in ['name','logical','packed','method']:
        for descending in [False,True]:
            # Python's stable two-pass order is independent of the Swift
            # comparator: equal primary values retain natural-name order.
            ties=sorted(records,key=lambda x:(natural(Path(x.filename).name),x.filename.encode()))
            expected[field+('-descending'if descending else '-ascending')]=[x.filename for x in sorted(ties,key=lambda x:primary(x,field),reverse=descending)]
    scale=sorted(range(100000),key=lambda i:(-(i%997),i))
    selected_hash=hashlib.sha256(b'S'*17).hexdigest()
    put(root/'oracle.json',dict(orderedPages=expected,scaleFirst512Names=[f'Item {i:06}.txt'for i in scale[:512]],
        selectedSHA256=selected_hash,selectedPath='Folder/Entry 017.txt'))
    names=['App/MacExplorer/Features/Archives/ArchiveBrowser.swift','App/MacExplorer/Features/Archives/ArchiveRowsView.swift','App/MacExplorer/Development/Checks/ArchiveSortingVerification.swift',
        'App/MacExplorer/Features/Archives/ArchiveExtractionWindow.swift','App/MacExplorer/Development/Checks/NativeMotionRecorder.swift','App/MacExplorer/App.swift',
        'Packages/ExplorerKit/Sources/LocalStorage/ZIPArchiveModels.swift','Packages/ExplorerKit/Sources/LocalStorage/ZIPArchiveSorting.swift',str(Path(__file__).resolve().relative_to(REPO))]
    hashes={n:digest(REPO/n)for n in names};binary=dev.APP/'Contents/MacOS/Mac Explorer';binary_hash=digest(binary)
    subprocess.run(['codesign','--verify','--strict','--deep',str(dev.APP)],check=True,capture_output=True,timeout=30)
    if measure(root/'source')['bytes']>32*MIB:raise RuntimeError('Generated source allowance reached before native launch')
    put(root/'inputs.json',dict(sourceSHA256=hashes,binarySHA256=binary_hash,sourceHashes=initial,recordMotion=args.record_motion,
        maximumCaseBytes=96*MIB,maximumCaseEntries=2048,maximumSourceBytes=32*MIB,maximumEvidenceBytes=16*MIB,
        maximumPeakBytes=256*MIB,maximumMainActorGapSeconds=0.4,maximumUncachedSortMilliseconds=5000,
        maximumFirstFolderMilliseconds=5000,maximumCachedPageMilliseconds=250,generatedOnly=True,network=0,personalArchives=0))
    env=dev.environment(tooling=False);env.update(MAC_EXPLORER_TEST_ROOT=str(root),MAC_EXPLORER_STATE_ROOT=str(root/'state'),MAC_EXPLORER_CACHE_ROOT=str(root/'cache'))
    log=root/'evidence/native.log'
    with log.open('xb')as output:
        child=subprocess.Popen([str(binary),'--verify-ui','--check-archive-sorting']+(['--record-motion']if args.record_motion else ['--offscreen']),
            cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        put(root/'evidence/process.json',dict(pid=child.pid,binarySHA256=binary_hash))
        stats,failure,contained,forced=wait_generated(child,log,root/'evidence',deadline=100)
    result=json.loads((root/'result.json').read_bytes())if(root/'result.json').is_file()else None
    actual=json.loads((root/'evidence/ordered-pages.json').read_bytes())if(root/'evidence/ordered-pages.json').is_file()else None
    metrics=result.get('metrics',{})if result else {}
    retained_ok=False
    if 'retainedUndoArea'in metrics:
        area=root/'source/Destination'/metrics['retainedUndoArea'];payload=area/'payload/Folder/Entry 017.txt'
        retained_ok=area.parent==root/'source/Destination'and not area.is_symlink()and (area/'.mac-explorer-recovery-v1').read_text()=='MacExplorer recovery v1\n'+metrics['retainedUndoOperation']+'\nRetained until explicit cleanup.\n'
        found=[];pending=[area/'payload']
        while pending:
            folder=pending.pop()
            if not stat.S_ISDIR(folder.lstat().st_mode):raise RuntimeError('Unexpected retained payload directory')
            for item in folder.iterdir():
                value=item.lstat()
                if stat.S_ISDIR(value.st_mode):pending.append(item)
                elif stat.S_ISREG(value.st_mode)and value.st_nlink==1 and value.st_size<=MIB:found.append(item)
                else:raise RuntimeError('Unexpected retained payload')
        retained_ok=retained_ok and found==[payload]and digest(payload)==selected_hash
    usage=measure(root)
    scale_ok=metrics.get('scaleExercised')is False if args.record_motion else metrics.get('scaleExercised')is True \
        and metrics.get('scaleFirst512Names')==[f'Item {i:06}.txt'for i in scale[:512]]and metrics.get('scaleGlobalFirst256Names')==[f'Item {i:06}.txt'for i in scale[:256]]
    oracles=actual==expected and scale_ok \
        and metrics.get('previewSHA256')==selected_hash and metrics.get('extractedSHA256')==selected_hash and retained_ok
    passed=child.returncode==0 and not contained and result is not None and result.get('passed')is True and oracles \
        and stats.ru_maxrss<=256*MIB and usage['bytes']<=96*MIB and usage['entries']<=2048 and measure(root/'source')['bytes']<=32*MIB and measure(root/'evidence')['bytes']<=16*MIB \
        and hashes=={n:digest(REPO/n)for n in names}and binary_hash==digest(binary)and all(digest(root/'source'/n)==value for n,value in initial.items())
    put(root/'evidence/qualification.json',dict(passed=passed,native=result,actualExit=child.returncode,contained=contained,forced=forced,
        failure=failure,peakRSSBytes=stats.ru_maxrss,independentOrderingAndPayloads=oracles,retainedUndoPayload=retained_ok,usage=usage,packet=audit()))
    timing={k:v for k,v in metrics.items()if k.endswith('Milliseconds')or k=='scaleExercised'}
    print(json.dumps(dict(case=root.name,passed=passed,checks=len(result.get('checks',[]))if result else 0,
        failures=result.get('failures')if result else [failure],peakRSSBytes=stats.ru_maxrss,timing=timing)),flush=True)
    if not passed:raise SystemExit(1)


def main():
    parser=argparse.ArgumentParser()
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--baseline',action='store_true');mode.add_argument('--tests',action='store_true');mode.add_argument('--native',action='store_true')
    parser.add_argument('--record-motion',action='store_true')
    parser.add_argument('--configuration',choices=['debug','release'],default='debug')
    args=parser.parse_args()
    if args.record_motion and not args.native:parser.error('Recording requires the native generated packet')
    if args.native:return native(args)
    root=reserve('traverse-archive-sorting')
    sources=['Packages/ExplorerKit/Sources/LocalStorage/ZIPArchiveModels.swift',
        'Packages/ExplorerKit/Tests/LocalStorageTests/ZIPSortLegacyDiagnostic.swift',str(Path(__file__).resolve().relative_to(REPO))]
    if not args.baseline:sources+=['Packages/ExplorerKit/Sources/LocalStorage/ZIPArchiveSorting.swift','Packages/ExplorerKit/Tests/LocalStorageTests/ZIPArchiveSortingTests.swift']
    hashes={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in sources}
    put(root/'inputs.json',dict(sourceSHA256=hashes,baseline=args.baseline,configuration=args.configuration,generatedOnly=True,
        maximumCaseBytes=96*MIB,maximumCaseEntries=2048,maximumSourceBytes=32*MIB,maximumEvidenceBytes=16*MIB,network=0,personalArchives=0))
    keys=['MAC_EXPLORER_ARCHIVE_SORT_TEST_ROOT','MAC_EXPLORER_ARCHIVE_SORT_BASELINE']
    previous={k:os.environ.get(k)for k in keys}
    os.environ.update(MAC_EXPLORER_ARCHIVE_SORT_TEST_ROOT=str(root),MAC_EXPLORER_ARCHIVE_SORT_BASELINE='1'if args.baseline else '0')
    failure=None;log=None
    try:
        log=dev.test('archiveSortLegacyDiagnostic'if args.baseline else 'ZIPArchiveSortingTests',args.configuration,serial=True)
        counts=re.findall(r'Test run with (\d+) tests? in [^\n]* passed',log.read_text())
        if sum(map(int,counts))!=(1 if args.baseline else 12)or'skipped'in log.read_text():raise RuntimeError('Exact finite test scope must execute')
        if args.baseline and json.loads((root/'evidence/legacy-order.json').read_bytes()).get('fixedOrderIsNotLargestFirst')is not True:raise RuntimeError('Baseline did not reproduce fixed ordering')
    except BaseException as error:failure=type(error).__name__+': '+str(error)
    finally:
        for key,value in previous.items():
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value
    usage=measure(root)
    passed=failure is None and usage['bytes']<=96*MIB and usage['entries']<=2048 and measure(root/'source')['bytes']<=32*MIB and measure(root/'evidence')['bytes']<=16*MIB \
        and hashes=={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in sources}
    put(root/'result.json',dict(characterized=passed,featureGatePassed=passed and not args.baseline,failure=failure,
        testLog=str(log.relative_to(REPO))if log else None,usage=usage,packet=audit()))
    print(json.dumps(dict(case=root.name,characterized=passed,featureGatePassed=passed and not args.baseline,failure=failure)),flush=True)
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
