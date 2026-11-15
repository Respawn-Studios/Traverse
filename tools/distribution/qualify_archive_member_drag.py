#!/usr/bin/env python3
"""Generated archive-member drag and observed-destination qualification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import zipfile

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,reserve,put,audit,measure,MIB,directory,require_case
from qualify_foundation import wait_generated


def native(args):
    packet_audit=audit
    ordinary_receipt=None
    if args.ordinary_build:
        ordinary_receipt,ordinary_proof=dev.compiled_debug_inputs(require_current_source=True)
    if args.development or args.ordinary_build:
        import development as development_packet
        action='archive-promise-internal-regression'if args.external_promises else'archive-native-regression'
        if args.external_promises:
            admitted=[p for p in development_packet.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action')in ['native-archive-promise-export','native-archive-promise-gesture','native-archive-promise-finder','archive-promise-internal-regression']]
            own=[p for p in admitted if json.loads(p.read_bytes()).get('action')=='archive-promise-internal-regression']
            if len(admitted)>=16 or len(own)>=2:raise RuntimeError('Ordinary promise/internal-regression scope exhausted')
        root=development_packet.reserve(action);packet_audit=development_packet.audit
        current=development_packet.native_sources()
        if args.ordinary_build:
            if ordinary_proof['sourceSHA256']!=current:raise RuntimeError('Ordinary source inventory changed')
            with (root/'evidence/compiled-inputs.json').open('xb')as output:
                os.fchmod(output.fileno(),0o600);output.write(ordinary_receipt)
        else:
            loaded=development_packet.APP/'Contents/MacOS/Mac Explorer.debug.dylib'
            identity=development_packet.digest(loaded);matched=False
            for receipt in sorted(development_packet.ROOT.glob('*/evidence/source.json'),key=lambda p:p.stat().st_mtime_ns,reverse=True):
                proof=json.loads(receipt.read_text());passed=receipt.with_name('build.json')
                if proof.get('loadedSHA256')==identity and proof.get('sourceSHA256')==current and passed.is_file()and json.loads(passed.read_text()).get('passed'):matched=True;break
            if not matched:raise RuntimeError('Build the current development sources first')
    else:root=reserve('traverse-archive-member-drag')
    for name in ['Source','Destination','Alternative']:(root/'source'/name).mkdir(mode=0o700)
    (root/'source/Destination/Existing Folder').mkdir(mode=0o700)
    source=root/'source/Source/Generated.zip'
    payloads={'Group A/Report.txt':b'Generated first report.\n','Group B/Report.txt':b'Generated second report, with different bytes.\n'}
    with zipfile.ZipFile(source,'x',compression=zipfile.ZIP_DEFLATED)as archive:
        for name,payload in payloads.items():archive.writestr(name,payload)
        for index in range(130):archive.writestr(f'Item {index:03}.txt',b'')
        archive.writestr('Selected/',b'')
        archive.writestr('Selected/Selected Child.txt',b'Generated absorbed child.\n')
    with zipfile.ZipFile(root/'source/Source/Unsupported.zip','x',compression=zipfile.ZIP_BZIP2)as archive:archive.writestr('Unsupported.txt',b'Generated unsupported codec fixture.')
    source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    original_archives={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in (root/'source/Source').iterdir()}
    expected={name:hashlib.sha256(payload).hexdigest()for name,payload in payloads.items()}
    names=['App/MacExplorer/Features/Archives/ArchiveMemberDrag.swift','App/MacExplorer/Development/Checks/ArchiveMemberDragVerification.swift','App/MacExplorer/Features/Archives/ArchiveBrowser.swift',
        'App/MacExplorer/Features/Archives/ArchiveRowsView.swift','App/MacExplorer/Features/Archives/ArchiveExtractionWindow.swift','App/MacExplorer/Browser/BrowserDragDrop.swift',
        'App/MacExplorer/Browser/FileIconBrowserView.swift','App/MacExplorer/Browser/VolumeBrowserView.swift','App/MacExplorer/App.swift','App/MacExplorer/Development/Checks/NativeMotionRecorder.swift',
        'Packages/ExplorerKit/Sources/FileOperations/ArchiveProduction.swift','Packages/ExplorerKit/Sources/LocalStorage/ZIPExtraction.swift',str(Path(__file__).resolve().relative_to(REPO))]
    hashes={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in names}
    if args.development or args.ordinary_build:hashes.update(current)
    app=development_packet.APP if args.development else dev.APP
    subprocess.run(['codesign','--verify','--strict','--deep',str(app)],check=True,capture_output=True,timeout=30)
    maximum_case=(64 if args.development or args.ordinary_build else 96)*MIB
    if args.pointer_image:
        if not args.gesture_review:raise RuntimeError('Image reuse requires the exact pointer control')
        if any(root.parent.glob('*/evidence/reused-pointer-image.json')):raise RuntimeError('Single retained-image pointer comparison exhausted')
        prior=require_case(args.pointer_image)
        if json.loads((prior/'reservation.json').read_bytes()).get('action')!='traverse-archive-member-drag':raise RuntimeError('Wrong retained image owner')
        old=json.loads((prior/'inputs.json').read_bytes())
        app=prior/'artifacts/Archive Gesture Review.app'
        if app.resolve()!=app or app.is_symlink():raise RuntimeError('Redirected retained image')
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if info.get('TraverseVerificationOnly')is not True or info.get('CFBundleIdentifier')!='local.traverse.archive.drag.'+prior.name.lower():raise RuntimeError('Retained image lacks the isolated identity')
        if any(old['sourceSHA256'].get(n)!=digest for n,digest in hashes.items()if n!=str(Path(__file__).resolve().relative_to(REPO))):raise RuntimeError('Retained image source is no longer current')
        if hashlib.sha256((app/'Contents/MacOS/Mac Explorer').read_bytes()).hexdigest()!=old['binarySHA256']:raise RuntimeError('Retained image has changed')
        subprocess.run(['codesign','--verify','--strict','--deep',str(app)],check=True,capture_output=True,timeout=30)
        put(root/'evidence/reused-pointer-image.json',dict(priorCase=prior.name,appPath=str(app),additionalImageBytes=0,finiteLaunches=1))
    elif args.gesture_review:
        if sum(1 for p in root.parent.glob('*/artifacts/Archive Gesture Review.app'))>=3:raise RuntimeError('Finite isolated pointer-app allowance exhausted')
        maximum_case=256*MIB
        app=directory(root/'artifacts')/'Archive Gesture Review.app'
        shutil.copytree(dev.APP,app,symlinks=True)
        info=app/'Contents/Info.plist';metadata=plistlib.loads(info.read_bytes())
        metadata['CFBundleIdentifier']='local.traverse.archive.drag.'+root.name.lower()
        metadata['TraverseVerificationOnly']=True;info.write_bytes(plistlib.dumps(metadata))
        subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True,timeout=30)
        subprocess.run(['codesign','--verify','--strict','--deep',str(app)],check=True,capture_output=True,timeout=30)
        cold=root/'evidence/inert-unscoped-launch.log'
        cold_env=dev.environment(tooling=False)
        cold_env.update(MAC_EXPLORER_STATE_ROOT=str(root/'inert-state'),MAC_EXPLORER_CACHE_ROOT=str(root/'inert-cache'))
        with cold.open('xb')as output:
            refused=subprocess.run([str(app/'Contents/MacOS/Mac Explorer')],cwd=REPO,env=cold_env,stdin=subprocess.DEVNULL,
                stdout=output,stderr=subprocess.STDOUT,timeout=5)
        if refused.returncode!=0 or cold.read_bytes()!=b'TRAVERSE_ISOLATED_REVIEW_REQUIRES_VERIFICATION\n'or(root/'inert-state').exists()or(root/'inert-cache').exists():raise RuntimeError('Generated app does not refuse ordinary launch')
    binary=app/'Contents/MacOS/Mac Explorer';binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest()
    put(root/'inputs.json',dict(sourceSHA256=hashes,binarySHA256=binary_hash,generatedArchiveSHA256=source_hash,expectedExtractedSHA256=expected,
        recordMotion=args.record_motion,gestureReview=args.gesture_review,hitTestControl=args.hit_test_control,qualifyExternalPromises=args.external_promises,originalArchiveSHA256=original_archives,maximumCaseBytes=maximum_case,maximumCaseEntries=2048,maximumSourceBytes=32*MIB,
        maximumEvidenceBytes=16*MIB,generatedOnly=True,personalArchives=0,network=0))
    env=dev.environment(tooling=False);env.update(MAC_EXPLORER_TEST_ROOT=str(root),MAC_EXPLORER_STATE_ROOT=str(root/'state'),MAC_EXPLORER_CACHE_ROOT=str(root/'cache'))
    log=root/'evidence/native.log'
    if args.gesture_review:print(json.dumps(dict(case=root.name,waitingForNativeGesture=True)),flush=True)
    with log.open('xb')as output:
        child=subprocess.Popen([str(binary),'--verify-ui','--check-archive-member-drag']+(['--gesture-review']if args.gesture_review else ['--record-motion']if args.record_motion else ['--offscreen'])+(['--drag-hit-test-control']if args.hit_test_control else [])+(['--qualify-external-promises']if args.external_promises else []),
            cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        put(root/'evidence/process.json',dict(pid=child.pid,binarySHA256=binary_hash,appPath=str(app)))
        stats,failure,contained,forced=wait_generated(child,log,root/'evidence',deadline=180 if args.gesture_review else 90)
    result=json.loads((root/'result.json').read_bytes())if(root/'result.json').is_file()else None
    usage=measure(root)
    metrics=result.get('metrics',{})if result else {}
    workflow=metrics.get('nativeGestureReview')is True if args.gesture_review else bool(metrics.get('publicDragHitTests'))if args.hit_test_control else metrics.get('extractedHashes')==expected
    retained_verified=None
    if not args.gesture_review and not args.hit_test_control and 'retainedUndoArea'in metrics:
        area=root/'source/Destination'/metrics['retainedUndoArea'];found={};pending=[area/'payload']
        retained_verified=area.parent==root/'source/Destination'and not area.is_symlink()and (area/'.mac-explorer-recovery-v1').read_text()=='MacExplorer recovery v1\n'+metrics['retainedUndoOperation']+'\nRetained until explicit cleanup.\n'
        while pending:
            folder=pending.pop()
            if not stat.S_ISDIR(folder.lstat().st_mode):raise RuntimeError('Unexpected generated recovery root')
            for item in folder.iterdir():
                facts=item.lstat()
                if stat.S_ISDIR(facts.st_mode):pending.append(item)
                elif stat.S_ISREG(facts.st_mode)and facts.st_nlink==1 and facts.st_size<=MIB:
                    fd=os.open(item,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
                    with os.fdopen(fd,'rb')as source_file:found[str(item.relative_to(area/'payload'))]=hashlib.sha256(source_file.read(MIB+1)).hexdigest()
                else:raise RuntimeError('Unexpected generated recovery item')
        retained_verified=retained_verified and found==expected
        workflow=workflow and retained_verified
    elif not args.gesture_review and not args.hit_test_control:workflow=False
    ordinary_unchanged=True
    if args.ordinary_build:
        try:ordinary_unchanged=dev.compiled_debug_inputs(require_current_source=True)[0]==ordinary_receipt
        except(OSError,ValueError,RuntimeError):ordinary_unchanged=False
    passed=child.returncode==0 and not contained and result is not None and result.get('passed')is True and ordinary_unchanged \
        and workflow and stats.ru_maxrss<=256*MIB \
        and usage['bytes']<=maximum_case and usage['entries']<=2048 and measure(root/'source')['bytes']<=32*MIB and measure(root/'evidence')['bytes']<=16*MIB \
        and source_hash==hashlib.sha256(source.read_bytes()).hexdigest()and binary_hash==hashlib.sha256(binary.read_bytes()).hexdigest() \
        and original_archives=={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in (root/'source/Source').iterdir()} \
        and hashes=={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in hashes}
    put(root/'evidence/qualification.json',dict(passed=passed,native=result,actualExit=child.returncode,peakRSSBytes=stats.ru_maxrss,
        ordinaryBuild=args.ordinary_build,ordinaryBuildUnchanged=ordinary_unchanged,
        contained=contained,forced=forced,failure=failure,independentRetainedUndoPayloads=retained_verified,usage=usage,packet=packet_audit()))
    print(json.dumps(dict(case=root.name,passed=passed,native=result)),flush=True)
    if not passed:raise SystemExit(1)


def main():
    parser=argparse.ArgumentParser();mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--baseline',action='store_true');mode.add_argument('--tests',action='store_true')
    mode.add_argument('--native',action='store_true')
    parser.add_argument('--configuration',choices=['debug','release'],default='debug')
    build=parser.add_mutually_exclusive_group()
    build.add_argument('--development',action='store_true',help='Current historical development product; callback regressions only')
    build.add_argument('--ordinary-build',action='store_true',help='Use the current ordinary Debug receipt and existing64MiB development fixture; no copied app')
    parser.add_argument('--external-promises',action='store_true',help='Two finite ordinary-promise/private-marker regression cases')
    parser.add_argument('--pointer-image',help='One finite pointer comparison using an unchanged, retained isolated image')
    appearance=parser.add_mutually_exclusive_group();appearance.add_argument('--record-motion',action='store_true');appearance.add_argument('--gesture-review',action='store_true');appearance.add_argument('--hit-test-control',action='store_true');args=parser.parse_args()
    if args.pointer_image and not(args.native and args.gesture_review):parser.error('Retained image requires the isolated native gesture mode')
    if (args.development or args.ordinary_build)and(not args.native or args.configuration!='debug'or args.pointer_image or args.gesture_review or args.record_motion or args.hit_test_control):parser.error('Development admission is the bounded offscreen Debug callback regression only')
    if args.external_promises and not(args.native and(args.development or args.ordinary_build)):parser.error('Promise regression requires generated development native mode')
    if args.native:return native(args)
    if args.record_motion:parser.error('Motion requires the exact native case')
    root=reserve('traverse-archive-member-drag')
    sources=['Packages/ExplorerKit/Sources/FileOperations/ArchiveProduction.swift','Packages/ExplorerKit/Sources/LocalStorage/ZIPExtraction.swift',
        'Packages/ExplorerKit/Tests/LocalStorageTests/ArchiveDropDestinationTests.swift','Packages/ExplorerKit/Tests/LocalStorageTests/ArchiveMemberLegacyDiagnostics.swift',str(Path(__file__).resolve().relative_to(REPO))]
    hashes={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in sources}
    put(root/'inputs.json',dict(sourceSHA256=hashes,scope='legacy-parent-observation-diagnostic'if args.baseline else 'observed-parent-guards',configuration=args.configuration,maximumCaseBytes=96*MIB,
        maximumCaseEntries=2048,maximumSourceBytes=32*MIB,maximumEvidenceBytes=16*MIB,generatedOnly=True,personalArchives=0,network=0))
    previous={k:os.environ.get(k)for k in ['MAC_EXPLORER_ARCHIVE_DRAG_TEST_ROOT','MAC_EXPLORER_ARCHIVE_DRAG_BASELINE']}
    os.environ.update(MAC_EXPLORER_ARCHIVE_DRAG_TEST_ROOT=str(root/'source'),MAC_EXPLORER_ARCHIVE_DRAG_BASELINE='1'if args.baseline else '0')
    failure=None;log=None
    try:
        log=dev.test('archiveMemberLegacyParentDiagnostic'if args.baseline else 'ArchiveDropDestinationTests',args.configuration,serial=True)
        reports=re.findall(r'Test run with (\d+) tests? in [^\n]* passed',log.read_text())
        if sum(map(int,reports))!=(1 if args.baseline else 6)or 'skipped'in log.read_text():raise RuntimeError('Exact finite scope must execute')
        if args.baseline:
            report=json.loads((root/'evidence/legacy-parent-diagnostic.json').read_bytes())
            if report.get('legacyPreparedReplacedParent')is not True or report.get('outputsCreated')!=0:raise RuntimeError('Legacy diagnostic differs')
    except BaseException as error:failure=type(error).__name__+': '+str(error)
    finally:
        for key,value in previous.items():
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value
    usage=measure(root)
    characterized=failure is None and usage['bytes']<=96*MIB and usage['entries']<=2048 and measure(root/'source')['bytes']<=32*MIB \
        and measure(root/'evidence')['bytes']<=16*MIB and hashes=={n:hashlib.sha256((REPO/n).read_bytes()).hexdigest()for n in sources}
    put(root/'result.json',dict(characterized=characterized,featureGatePassed=characterized and not args.baseline,failure=failure,
        testLog=str(log.relative_to(REPO))if log else None,usage=usage,packet=audit()))
    print(json.dumps(dict(case=root.name,characterized=characterized,featureGatePassed=characterized and not args.baseline,failure=failure)),flush=True)
    if not characterized:raise SystemExit(1)


if __name__=='__main__':main()
