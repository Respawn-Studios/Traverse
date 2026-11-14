#!/usr/bin/env python3
"""One additional immutable code copy for the already-admitted final negative.

The original512MiB cohort and64MiB runtime keep their immutable limits/inputs.
This separately admits128MiB for the sixth App copy inside the aggregate limit.
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'tools/analysis_reuse'), str(REPO/'tools')]
import native as n
import development as d
ROOT = d.ROOT/'9E1C96F3-DA12-43C6-8BA5-6B78E82100E0'
BUILD = d.ROOT/'0A183501-2F00-4144-974E-35C2C38702DD'
ACTION = 'analysis-reuse-final-negative-code'
LIMITS = dict(bytes=128<<20, entries=512, appCopies=1, runtimeLanes=['16'])
FILES = ['App/MacExplorer/Application/ApplicationStorageAnalysis.swift','App/MacExplorer/Features/StorageAnalysis/StorageAnalysisWindow.swift']
def tools(): return {str(Path(__file__)):d.digest(Path(__file__)), str(REPO/'tools/analysis_reuse/native.py'):d.digest(REPO/'tools/analysis_reuse/native.py')}
def budget(code):
    v=d.measure(code)
    if max(v['bytes'],v['allocatedBytes'])>LIMITS['bytes'] or v['entries']>LIMITS['entries']:raise RuntimeError('Separate final-code allowance')
    return v
def prepare():
    if n.cases(ACTION):raise RuntimeError('One separate final-negative code copy')
    v=n.admitted(ROOT)
    if not all(n.load(ROOT/'runs'/str(i).zfill(2)/'result.json')['passed'] for i in range(1,16)):
        raise RuntimeError('All earlier actual positive/negative lanes must pass')
    if d.native_sources()!=v['positiveGraph']:raise RuntimeError('Exact restored positive source required')
    code=d.reserve(ACTION);before={s:(REPO/s).read_bytes() for s in FILES}
    for s,b in before.items():
        p=code/'source/positive'/s;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
    item=v['expectedNativeCases']['16'];patch=n.PACKET/'negative-controls'/item['negativePatch']
    d.put(code/'admission.json',dict(master=n.MASTER,limits=LIMITS,tools=tools(),runtime=ROOT.name,
        originalCodeCase=v['codeCase'],originalCodeCeiling=n.LIMITS['codeBytes'],
        reason='sixth immutable App copy refused prospectively by original512MiB code ceiling',
        aggregateCeilingUnchanged=True,patchSHA256=d.digest(patch),originalRuntimeInputsSHA256=d.digest(ROOT/'inputs.json'),
        sourceBefore={s:d.digest(REPO/s) for s in FILES},build=BUILD.name))
    expected=None
    try:
        subprocess.run(['git','apply','--check',str(patch)],cwd=REPO,check=True)
        subprocess.run(['git','apply',str(patch)],cwd=REPO,check=True)
        expected={s:d.digest(REPO/s) for s in FILES}
        p=n.whole_app(BUILD)
        app=code/'source/negative04.app';shutil.copytree(d.APP,app,symlinks=True)
        info=app/'Contents/Info.plist';values=plistlib.loads(info.read_bytes())
        values.update(CFBundleIdentifier='local.macexplorer.preview',CFBundleName='Traverse reuse qualification',
            MacExplorerDistributionChannel='development-preview',MacExplorerReviewCase=ROOT.name,
            MacExplorerReviewStorage='repository-v1',TraverseVerificationOnly=True,TraverseAnalysisReuseVariant='negative04')
        values.pop('CFBundleDocumentTypes',None);values.pop('CFBundleURLTypes',None);info.write_bytes(plistlib.dumps(values))
        subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--preserve-metadata=entitlements,flags,runtime',str(app)],check=True,capture_output=True,timeout=60)
        subprocess.run(['codesign','--verify','--strict','--deep',str(app)],check=True,capture_output=True,timeout=30)
        binary=app/'Contents/MacOS'/values['CFBundleExecutable']
        n.whole_app(BUILD)
        d.put(code/'evidence/negative04.json',dict(app=str(app),binary=str(binary),binarySHA256=d.digest(binary),
            infoSHA256=d.digest(info),build=BUILD.name,sourceGraph=p['sourceSHA256'],helpers=p['helpersSHA256'],
            actualBuildReceiptSHA256=d.digest(BUILD/'evidence/build.json'),originalProductUnchanged=True))
        budget(code);d.audit()
    finally:
        if expected is not None:
            if any(d.digest(REPO/s)!=h for s,h in expected.items()):raise RuntimeError('Concurrent source change; refuse restoration')
            for s,b in before.items():
                if (REPO/s).read_bytes()!=b:(REPO/s).write_bytes(b)
            d.put(code/'evidence/source-restored.json',dict(files={s:d.digest(REPO/s) for s in FILES},restored=d.native_sources()==v['positiveGraph']))
    print(json.dumps(dict(codeCase=code.name,sealed=True,originalLimitsUnchanged=True)),flush=True)
def run(code):
    a=n.load(code/'admission.json');v=n.admitted(ROOT)
    if code not in n.cases(ACTION) or a['tools']!=tools() or a['limits']!=LIMITS or d.digest(ROOT/'inputs.json')!=a['originalRuntimeInputsSHA256']:
        raise RuntimeError('Exact separate final-code admission')
    binding=n.load(code/'evidence/negative04.json');app=Path(binding['app']);lane='16';item=v['expectedNativeCases'][lane]
    command=[binding['binary'],'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-analysis-session-reuse',
        '--analysis-reuse-case',lane,'--analysis-reuse-worker',v['worker'],'--offscreen']
    folder=ROOT/'runs'/lane
    if folder.exists():raise RuntimeError('Final lane consumed; preserve failures')
    if n.budget(ROOT)['entries']+64>n.LIMITS['entries']:raise RuntimeError('Original runtime headroom')
    lock=os.open(ROOT/'runtime.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        n.fcntl.flock(lock,n.fcntl.LOCK_EX|n.fcntl.LOCK_NB)
        folder.mkdir(mode=0o700);generated,bodies=n.fixture(ROOT,lane)
        d.put(folder/'attempt.json',dict(command=command,visible=False,limits=n.LIMITS,binding=binding,separateCodeCase=code.name))
        env=n.common.environment(ROOT);env['MAC_EXPLORER_TEST_ROOT']=str(ROOT)
        def validate():
            n.admitted(ROOT)
            if d.digest(Path(binding['binary']))!=binding['binarySHA256'] or d.digest(app/'Contents/Info.plist')!=binding['infoSHA256']:
                raise RuntimeError('Sealed actual code changed')
            n.budget(ROOT);budget(code)
        actual,out,err=n.common.process_owner(command,ROOT,'reuse-16','runtime',n.LIMITS['rssBytes'],n.LIMITS['seconds'],
            env,n.LIMITS['processes'],n.LIMITS['bytes'],n.LIMITS['entries'],validate)
        reports=[json.loads(line[len(b'MAC_EXPLORER_ANALYSIS_REUSE '):]) for line in out.read_bytes().splitlines() if line.startswith(b'MAC_EXPLORER_ANALYSIS_REUSE ')]
        if len(reports)!=1 or out.stat().st_size+err.stat().st_size>65536:raise RuntimeError('One actual bounded native report')
        report=reports[0]
        good=actual['actualExit']==20 and actual['actualProcessAndDescendantDrain'] and actual['observer']['drained'] and not actual['contained'] and not actual['forced']
        good=good and report.get('case')==lane and report.get('variant')=='negative04' and report.get('outcome')==item['expectedOutcome']
        good=good and report.get('semanticNegativeObserved') is True and report.get('failureCode')==item['semanticFailure']
        good=good and report.get('ownerIdle') is True and report.get('activityCount')==0 and report.get('scheduledDiscardJoinReturned') is True and report.get('queryHookTimeoutCount')==0
        validate();n.check_fixture(generated,bodies,False)
        d.put(folder/'result.json',dict(passed=bool(good),process=actual,controls=report,nativeBudget=n.budget(ROOT),separateCodeCase=code.name))
        print(json.dumps(dict(case=ROOT.name,lane=lane,passed=bool(good),outcome=report.get('outcome'),failure=report.get('failureCode'))),flush=True)
        if not good:raise SystemExit(1)
    finally:
        if folder.is_dir() and (folder/'attempt.json').is_file() and not (folder/'result.json').exists():
            d.put(folder/'result.json',dict(passed=False,runnerFailure='IncompleteQualification',process=locals().get('actual'),controls=locals().get('report')))
        os.close(lock)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('stage',choices=['prepare','run']);p.add_argument('--case');a=p.parse_args()
    if a.stage=='prepare' and not a.case:prepare()
    elif a.stage=='run' and a.case:run(d.ROOT/a.case)
    else:p.error('Exact completion stage')
