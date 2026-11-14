#!/usr/bin/env python3
"""Fixed generated-only batch-label crash/I/O/cold recovery controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,reserve,directory,put,audit,measure,MIB
from qualify_foundation import wait_generated


def image(path):
    result={}
    for p in path.iterdir():
        info=p.lstat()
        if not stat.S_ISREG(info.st_mode)or info.st_nlink!=1 or info.st_size>4*MIB:raise RuntimeError('Unknown generated catalog entry')
        result[p.name]=dict(sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=info.st_size,mode=stat.S_IMODE(info.st_mode))
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--scenario',choices=['firstRow','lastRow','committed','journalSync','databaseWrite']);args=parser.parse_args()
    report=reserve('traverse-private-labels')
    sources=list((REPO/'Packages/ExplorerKit/Sources/FileMemory').glob('*.swift'))+[REPO/'Packages/ExplorerKit/Tests/FileMemoryTests/NameLabelProcessTests.swift',
        REPO/'Packages/ExplorerKit/Tests/NameStoreFaultSupport/NameStoreFaultSupport.c',Path(__file__).resolve()]
    hashes={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
    selected=[args.scenario]if args.scenario else ['firstRow','lastRow','committed','journalSync','databaseWrite']
    put(report/'inputs.json',dict(sourceSHA256=hashes,scenarios=selected,maximumCaseBytes=64*MIB,maximumCaseEntries=1024,
        maximumSourceBytes=4*MIB,maximumEvidenceBytes=8*MIB,generatedOnly=True,network=0,personalCatalogs=0))
    # Build the worker with no process authority; the guarded test returns before
    # reading/creating a catalog. Actual qualification below uses fresh helpers.
    build_log=dev.test('privateLabelsProcessQualificationWorker','debug',serial=True)
    swift=Path(subprocess.check_output(['xcrun','--find','swift'],text=True).strip())
    helper=swift.parent.parent/'libexec/swift/pm/swiftpm-testing-helper'
    platform=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())/'Platforms/MacOSX.platform/Developer'
    binary=REPO/'.build/swift-tests/out/Products/Debug/FileMemoryTests.xctest/Contents/MacOS/FileMemoryTests'
    executable_hash=hashlib.sha256(binary.read_bytes()).hexdigest()
    rows=[];failure=None
    try:
        for scenario in selected:
            case=reserve('traverse-private-labels')
            row=dict(case=case.name,scenario=scenario,passed=False,phases=[]);rows.append(row)
            put(case/'inputs.json',dict(sourceSHA256=hashes,binarySHA256=executable_hash,scenario=scenario,generatedOnly=True,
                maximumCaseBytes=64*MIB,maximumCaseEntries=1024,maximumSourceBytes=4*MIB,maximumEvidenceBytes=8*MIB))
            for phase in ['seed','write','recover','cold']:
                if hashes!={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources} \
                    or executable_hash!=hashlib.sha256(binary.read_bytes()).hexdigest():raise RuntimeError('Worker sources changed')
                env=dev.environment(tooling=False);env.update(DYLD_FRAMEWORK_PATH=str(platform/'Library/Frameworks'),DYLD_LIBRARY_PATH=str(platform/'usr/lib'),
                    MAC_EXPLORER_LABEL_PROCESS_ROOT=str(case),MAC_EXPLORER_LABEL_PROCESS_PHASE=phase,MAC_EXPLORER_LABEL_PROCESS_SCENARIO=scenario)
                if phase=='cold':before=image(case/'source/catalog')
                log=case/'evidence'/('label-process-'+phase+'.log')
                with log.open('xb')as output:
                    child=subprocess.Popen([str(helper),'--test-bundle-path',str(binary),'--testing-library','swift-testing','--filter','privateLabelsProcessQualificationWorker'],
                        cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
                    put(case/'evidence'/('label-process-'+phase+'.started.json'),dict(pid=child.pid,binarySHA256=executable_hash))
                    stats,reason,contained,forced=wait_generated(child,log,case/'evidence',deadline=20)
                status=child.returncode
                put(case/'evidence'/('label-process-'+phase+'.process.json'),dict(actualExit=status,peakRSSBytes=stats.ru_maxrss,
                    contained=contained,forced=forced,failure=reason))
                receipt=case/'evidence'/('process-'+phase+'.json')
                result=json.loads(receipt.read_bytes())if receipt.is_file()else None
                expected=86 if phase=='write'and scenario in ['firstRow','lastRow','committed']else 0
                ok=status==expected and not contained and stats.ru_maxrss<=256*MIB and result is not None and result.get('passed')is True and result.get('pid')==child.pid
                row['phases'].append(dict(phase=phase,actualExit=status,contained=contained,receipt=result,passed=ok))
                if not ok:raise RuntimeError('Generated label process control failed: '+scenario+'/'+phase)
                if phase=='write':
                    original=image(case/'source/catalog');copy=directory(case/'evidence/retained-before-recovery')
                    for name in original:shutil.copyfile(case/'source/catalog'/name,copy/name);os.chmod(copy/name,0o600)
                    if image(copy)!=original:raise RuntimeError('Failed catalog snapshot mismatch')
                    put(case/'evidence/retained-before-recovery.json',original)
                if phase=='cold'and image(case/'source/catalog')!=before:raise RuntimeError('Cold read changed generated storage')
            usage=measure(case)
            if usage['bytes']>64*MIB or usage['entries']>1024 or measure(case/'source')['bytes']>4*MIB or measure(case/'evidence')['bytes']>8*MIB:
                raise RuntimeError('Generated process case limit')
            row['passed']=True;put(case/'result.json',row);audit()
            print(json.dumps(dict(case=case.name,scenario=scenario,passed=True)),flush=True)
    except BaseException as error:failure=type(error).__name__+': '+str(error)
    passed=failure is None and len(rows)==len(selected)and all(row['passed']for row in rows)
    put(report/'result.json',dict(passed=passed,failure=failure,cases=rows,buildOnlyLog=str(build_log.relative_to(REPO)),packet=audit()))
    print(json.dumps(dict(report=report.name,passed=passed,failure=failure)),flush=True)
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
