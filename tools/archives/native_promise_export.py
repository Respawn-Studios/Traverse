#!/usr/bin/env python3
"""Finite generated ordinary ZIP promise owner/engine controls; no OS grant."""
import argparse,json,os,sys,zipfile
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'ssh_profiles'))
from packet import prepare,d,run,audit
from native_transfer import native_proof,unlocked
import runtime_diagnostics
import dev

def ordinary_case_actions():
    actions=('native-archive-promise-export','native-archive-promise-gesture',
        'native-archive-promise-finder','archive-promise-internal-regression')
    return [action for path in d.ROOT.glob('*/reservation.json')
        if (action:=json.loads(path.read_bytes()).get('action'))in actions]

def source_snapshot(native_case=None,*,ordinary_build=False):
    """Use the existing build owner; never rebuild or substitute another app."""
    if ordinary_build:
        if native_case is not None:raise ValueError('Choose one native build source')
        receipt,proof=dev.compiled_debug_inputs(require_current_source=True)
        return dev.APP,proof,receipt
    if not native_case:raise ValueError('An exact native case or ordinary build is required')
    return d.APP,native_proof(native_case),None

def source_unchanged(proof,receipt):
    """Keep actual delivery evidence even when the final source fence refuses."""
    try:
        if proof['sourceSHA256']!=d.native_sources():return False
        if receipt is None:return True
        current,_=dev.compiled_debug_inputs(require_current_source=True)
        return current==receipt
    except (OSError,ValueError,RuntimeError):return False

def main():
    p=argparse.ArgumentParser()
    build=p.add_mutually_exclusive_group(required=True)
    build.add_argument('--native-case')
    build.add_argument('--ordinary-build',action='store_true',help='Reuse the current ordinary Debug build and its verified receipt')
    p.add_argument('--public-publication',action='store_true',help='Use the explicit generated v15/v16 promise publication candidate; no real receiver or sandbox grant')
    a=p.parse_args()
    prepare();unlocked()
    app,proof,receipt=source_snapshot(a.native_case,ordinary_build=a.ordinary_build)
    if len(ordinary_case_actions())>=16:raise RuntimeError('Sixteen-case ordinary promise scope exhausted')
    root=d.reserve('native-archive-promise-export');(root/'source/control.py').write_bytes(Path(__file__).read_bytes())
    bodies={'First.txt':b'Generated first root\n','Last.txt':b'Generated last root\n','Folder/Member.txt':b'Generated folder member\n','Folder/Empty/':b''}
    archive=root/'source/Generated.zip'
    with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_DEFLATED)as target:
        for name,body in bodies.items():target.writestr(name,body)
    original=d.digest(archive)
    d.put(root/'inputs.json',dict(nativeCase=a.native_case,nativeSources=proof['sourceSHA256'],expectedChecks=12,
        sourceSHA256=original,generatedBodyBytes=sum(map(len,bodies.values())),maximumCaseBytes=64<<20,
        maximumNativeRSSBytes=256<<20,networkRequests=0,keychainCalls=0,sandboxLaunches=0,
        ordinaryBuild=a.ordinary_build,publicPublication=a.public_publication,physicalInput=False,toolSHA256=d.digest(Path(__file__))))
    if receipt is not None:
        with (root/'evidence/compiled-inputs.json').open('xb')as output:
            os.fchmod(output.fileno(),0o600);output.write(receipt)
    process,_,_=run([str(app/'Contents/MacOS/Mac Explorer'),'--verify-ui','--check-archive-promise-export'],
        root,'native-archive-promise-export',timeout=150,native=True)
    output=root/'evidence/native-archive-promise-export.json';native=json.loads(output.read_bytes())if output.is_file()else{}
    diagnostics=runtime_diagnostics.inspect(root/'evidence/native-archive-promise-export.stderr')
    literal=False
    if native.get('passed'):
        state=root/'state'
        literal=(state/'Replay/One.txt').read_bytes()==bodies['First.txt']and not(state/'Replay/Replay.txt').exists()
        literal &= (state/'Partial/Good.txt').read_bytes()==bodies['First.txt']and(state/'Partial/Conflict.txt').read_bytes()==b'Existing stays'and not(state/'Partial/Untouched Folder').exists()
        literal &= (state/'ClosedSource/Folder/Member.txt').read_bytes()==bodies['Folder/Member.txt']and list((state/'ClosedSource/Folder/Empty').iterdir())==[]and not(state/'ClosedSource/Late.txt').exists()
        literal &= all(list((state/name).iterdir())==[]for name in ['Stopped','BoundParent','OtherParent','Busy','PostedCallback'])
        literal &= all(not(state/'SessionReuse'/name).exists() for name in ['Cancelled.txt','One.txt','Two.txt'])
    unchanged=source_unchanged(proof,receipt)and d.digest(archive)==original
    passed=bool(process['passed']and process['peakRSSBytes']<=256<<20 and native.get('passed')and native.get('drained')
        and native.get('publicPublication')==a.public_publication
        and len(native.get('checks',[]))==12 and literal and unchanged and diagnostics['passed']and d.measure(root)['bytes']<=64<<20)
    d.put(root/'evidence/result.json',dict(passed=passed,native=native,process=process,sourceUnchanged=unchanged,
        independentLiteralOutputs=literal,runtimeDiagnostics=diagnostics,physicalInput=False,sandboxGrant=False,usage=audit()))
    print(json.dumps(dict(case=root.name,passed=passed,checks=len(native.get('checks',[])),failure=native.get('failure'))),flush=True)
    if not passed:raise SystemExit(1)
if __name__=='__main__':main()
