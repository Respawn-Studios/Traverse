#!/usr/bin/env python3
"""Generated private-label qualification; native reference setup stays contained."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,reserve,put,audit,measure,MIB
from qualify_foundation import wait_generated


def native(args):
    root=reserve('traverse-private-labels')
    source=root/'source/Generated.txt';source.write_bytes(b'Generated private label reference fixture.\n')
    (root/'source/Generated Folder').mkdir(mode=0o700)
    source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    binary=dev.APP/'Contents/MacOS/Mac Explorer'
    subprocess.run(['codesign','--verify','--strict','--deep',str(dev.APP)],check=True,capture_output=True,timeout=30)
    names=['App/MacExplorer/Features/PrivateNames/PrivateLabelAddition.swift','App/MacExplorer/Development/Checks/PrivateLabelAdditionVerification.swift',
        'App/MacExplorer/Features/PrivateNames/PrivateNames.swift','App/MacExplorer/Features/PrivateNames/PrivateNamesLibrary.swift','App/MacExplorer/Development/Checks/NativeMotionRecorder.swift',
        'Packages/ExplorerKit/Sources/FileMemory/NameLabelAddition.swift','Packages/ExplorerKit/Sources/FileMemory/SessionNameIndex.swift',
        str(Path(__file__).resolve().relative_to(REPO))]
    hashes={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in names};binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest()
    put(root/'inputs.json',dict(sourceSHA256=hashes,binarySHA256=binary_hash,generatedOnly=True,recordMotion=args.record_motion,privacyControl=args.privacy_control,
        maximumCaseBytes=64*MIB,maximumCaseEntries=1024,maximumSourceBytes=4*MIB,maximumEvidenceBytes=8*MIB,
        maximumPeakBytes=256*MIB,sourceContentSHA256=source_hash,generatedRememberSetupOnly=True,
        personalCatalogs=0,network=0,keychain=0))
    env=dev.environment(tooling=False);env.update(MAC_EXPLORER_TEST_ROOT=str(root),MAC_EXPLORER_STATE_ROOT=str(root/'state'),MAC_EXPLORER_CACHE_ROOT=str(root/'cache'))
    command=[str(binary),'--verify-ui','--check-private-labels']+(['--record-motion']if args.record_motion else ['--offscreen'])+(['--label-privacy-control']if args.privacy_control else [])
    log=root/'evidence/native.log'
    with log.open('xb')as output:
        child=subprocess.Popen(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        put(root/'evidence/process.json',dict(pid=child.pid,binarySHA256=binary_hash))
        stats,failure,contained,forced=wait_generated(child,log,root/'evidence',deadline=90)
    result=json.loads((root/'result.json').read_bytes())if(root/'result.json').is_file()else None
    usage=measure(root);data=measure(root/'source');evidence=measure(root/'evidence')
    passed=child.returncode==0 and not contained and result is not None and result.get('passed')is True \
        and stats.ru_maxrss<=256*MIB and usage['bytes']<=64*MIB and usage['entries']<=1024 and data['bytes']<=4*MIB and evidence['bytes']<=8*MIB \
        and source_hash==hashlib.sha256(source.read_bytes()).hexdigest() and binary_hash==hashlib.sha256(binary.read_bytes()).hexdigest() \
        and hashes=={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in names}
    put(root/'evidence/qualification.json',dict(passed=passed,native=result,actualExit=child.returncode,peakRSSBytes=stats.ru_maxrss,
        contained=contained,forced=forced,failure=failure,caseUsage=usage,sourceUsage=data,evidenceUsage=evidence,packet=audit()))
    print(json.dumps(dict(case=root.name,passed=passed,native=result)),flush=True)
    if not passed:raise SystemExit(1)


def main():
    parser=argparse.ArgumentParser();mode=parser.add_mutually_exclusive_group(required=True);mode.add_argument('--tests',action='store_true');mode.add_argument('--native',action='store_true');mode.add_argument('--original-index',action='store_true')
    parser.add_argument('--configuration',choices=['debug','release'],default='debug');parser.add_argument('--record-motion',action='store_true');parser.add_argument('--privacy-control',action='store_true');args=parser.parse_args()
    if args.native:return native(args)
    if args.record_motion:parser.error('Recording requires the exact native case')
    root=reserve('traverse-private-labels')
    sources=['Packages/ExplorerKit/Sources/FileMemory/NameLabelAddition.swift','Packages/ExplorerKit/Sources/FileMemory/SessionNameIndex.swift',
        'Packages/ExplorerKit/Sources/FileMemory/PersistentNameStore.swift','Packages/ExplorerKit/Sources/FileMemory/NameIndexDatabase.swift',
        'Packages/ExplorerKit/Tests/FileMemoryTests/NameLabelAdditionTests.swift']
    test_filter='NameLabelAdditionTests';expected_tests=10
    if args.original_index:
        originals=['Packages/ExplorerKit/Tests/FileMemoryTests/NameInputTests.swift','Packages/ExplorerKit/Tests/FileMemoryTests/NameIndexTests.swift']
        sources+=originals
        names=[name for path in originals for name in re.findall(r'@Test\s+func\s+(\w+)',(REPO/path).read_text())]
        if len(names)!=13:raise RuntimeError('Original regression scope changed; review the finite packet')
        test_filter='('+'|'.join(re.escape(name)for name in names)+')';expected_tests=13
    hashes={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in sources}
    put(root/'inputs.json',dict(sourceSHA256=hashes,configuration=args.configuration,originalIndex=args.original_index,testFilter=test_filter,expectedTests=expected_tests,maximumCaseBytes=64*MIB,maximumCaseEntries=1024,
        maximumSourceBytes=4*MIB,maximumEvidenceBytes=8*MIB,generatedOnly=True,nativeReferenceReads=0,personalCatalogs=0))
    previous=os.environ.get('MAC_EXPLORER_LABEL_TEST_ROOT');os.environ['MAC_EXPLORER_LABEL_TEST_ROOT']=str(root/'source')
    failure=None;log=None
    try:
        log=dev.test(test_filter,args.configuration,serial=True)
        text=log.read_text();reports=re.findall(r'Test run with (\d+) tests? in [^\n]* passed',text)
        if sum(map(int,reports))!=expected_tests or 'skipped' in text:raise RuntimeError('Every focused qualification test must run')
    except BaseException as error:failure=type(error).__name__
    finally:
        if previous is None:os.environ.pop('MAC_EXPLORER_LABEL_TEST_ROOT',None)
        else:os.environ['MAC_EXPLORER_LABEL_TEST_ROOT']=previous
    usage=measure(root);data=measure(root/'source')
    passed=failure is None and usage['bytes']<=64*MIB and usage['entries']<=1024 and data['bytes']<=4*MIB \
        and hashes=={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in sources}
    put(root/'result.json',dict(passed=passed,error=failure,testLog=str(log.relative_to(REPO))if log else None,caseUsage=usage,sourceUsage=data,packet=audit()))
    print(json.dumps(dict(case=root.name,passed=passed,error=failure)),flush=True)
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
