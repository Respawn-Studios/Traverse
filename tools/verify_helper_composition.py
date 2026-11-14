#!/usr/bin/env python3
"""Prove a helper-only incremental bundle without inventing compiler samples."""
import argparse,json,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
import development as d
sys.path.insert(0,str(Path(__file__).parent/'smb_reader'))
from download_process import ordinary_image

def main():
    p=argparse.ArgumentParser();p.add_argument('--base-case',required=True);p.add_argument('--refresh-case',required=True);p.add_argument('--owner-case',required=True);a=p.parse_args()
    base=d.ROOT/a.base_case;refresh=d.ROOT/a.refresh_case;owner=d.ROOT/a.owner_case
    old=json.loads((base/'evidence/source.json').read_bytes());accepted=json.loads((base/'evidence/build.json').read_bytes());start=json.loads((refresh/'evidence/source-start.json').read_bytes());stopped=json.loads((refresh/'evidence/build-stop.json').read_bytes());memory=json.loads((refresh/'evidence/compiler-memory.json').read_bytes())
    current=d.native_sources();differences={name for name in current if current.get(name)!=old.get('sourceSHA256',{}).get(name)}
    if not accepted.get('passed')or old.get('configuration')!='Debug'or old.get('optimizedQualification')is not True or set(current)!=set(old['sourceSHA256'])or differences!={'Vendor/smb2/PROVENANCE.json'}:raise RuntimeError('Only the exact qualified helper provenance may differ from compiled native sources')
    log=(refresh/'evidence/build.log').read_text()
    if not stopped.get('sourceUnchanged')or not stopped.get('ownerProjectUnchanged')or stopped.get('actualExit')!=0 or stopped.get('buildAcceptance')is not False or start.get('sourceSHA256')!=current or '** BUILD SUCCEEDED **'not in log:raise RuntimeError('Exact successful but unmeasured incremental refresh required')
    if any(line.startswith(('SwiftCompile ','SwiftEmitModule ','SwiftDriver Compilation '))for line in log.splitlines()):raise RuntimeError('A new native compilation needs its actual compiler gate')
    loaded=d.APP/old['loadedRelative']
    if not loaded.is_file()or d.digest(loaded)!=old['loadedSHA256']:raise RuntimeError('Previously compiled native image changed')
    proof=json.loads((owner/'evidence/result.json').read_bytes());inputs=json.loads((owner/'inputs.json').read_bytes())
    if not proof.get('passed')or proof.get('nativeCase')!=a.base_case or proof.get('controls',{}).get('checks')!=4009 or inputs.get('sourceSHA256')!=d.digest(d.REPO/'tools/smb_reader/SMBFolderOwnerControls.swift')or not proof.get('moduleSHA256')or any(d.digest(d.REPO/name)!=h for name,h in proof['moduleSHA256'].items()):raise RuntimeError('Exact identical native owner objects/modules required')
    browser=ordinary_image(d.REPO/'.build/b10-network-tooling/ordinary-helpers/smb-browser-worker')
    root=d.reserve('native-helper-composition');report=dict(passed=False,verificationKind='helper-only-composition',baseBuildCase=a.base_case,incrementalRefreshCase=a.refresh_case,ownerCase=a.owner_case,newNativeCompilerInvocations=0)
    d.put(root/'inputs.json',dict(**report,currentSources=current,allowedDifference=sorted(differences),loadedSHA256=old['loadedSHA256'],ownerModuleSHA256=proof['moduleSHA256'],ordinaryBrowserSHA256=d.digest(browser)))
    try:
        subprocess.run(['codesign','--verify','--strict','--deep',str(d.APP)],capture_output=True,check=True,timeout=30)
        helpers={v.name:d.digest(v)for v in sorted((d.APP/'Contents/Helpers').iterdir())if v.is_file()and not v.is_symlink()}
        if not helpers or helpers==old.get('helpersSHA256'):raise RuntimeError('New helper bundle was not composed')
        if current!=d.native_sources()or d.digest(loaded)!=old['loadedSHA256']or any(d.digest(d.REPO/name)!=h for name,h in proof['moduleSHA256'].items()):raise RuntimeError('Composition changed during verification')
        d.put(root/'evidence/source.json',dict(sourceSHA256=current,loadedSHA256=d.digest(loaded),loadedRelative=old['loadedRelative'],executableSHA256=d.digest(d.APP/'Contents/MacOS/Mac Explorer'),helpersSHA256=helpers,configuration='Debug',optimizedQualification=True,verificationKind='helper-only-composition',baseBuildCase=a.base_case))
        report.update(passed=True,configuration='Debug',optimizedQualification=True,sourceUnchanged=True,ownerProjectUnchanged=True,signatureVerified=True,compilerMeasurementClaimed=False,usage=d.audit())
        d.put(root/'evidence/build.json',report)
    except BaseException as error:report['failure']=type(error).__name__;raise
    finally:d.put(root/'evidence/result.json',report)
    print(json.dumps(dict(case=root.name,passed=True,verificationKind=report['verificationKind'],newNativeCompilerInvocations=0)),flush=True)
if __name__=='__main__':main()
