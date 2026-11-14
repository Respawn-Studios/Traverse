#!/usr/bin/env python3
"""Copied production-profile image; no test-only dependency feature or TCP."""
import argparse,json,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
from download_worker_packet import HERE,d,child,smb,environment
from download_worker_build import frozen,sources as functional_sources
import prepare_download_worker as prepare
PREFIX='smb-selected-download-production-'
BINARY='traverse-smb-selected-download-production'
def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action','').startswith(PREFIX)]
def audit(building=False):
    value=child.audit();roots=cases()
    if sum(d.measure(r)['bytes']for r in roots)>256<<20 or sum(d.measure(r)['entries']for r in roots)>2048:raise RuntimeError('Production-profile subpacket ceiling')
    value['smbTooling']=smb.usage(smb.TOOLING,smb.TOOLING_LIMIT,building=building,compiler_locks=building)
    return value
def reserve(kind):
    if kind not in ['build','controls']:raise RuntimeError('Unreviewed production-profile action')
    child.prepare();audit();count=sum(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in cases())
    if count>=(2 if kind=='build'else 1):raise RuntimeError('Two production-profile builds/one process control consumed')
    return d.reserve(PREFIX+kind)
def sources():
    return dict(functional=functional_sources(),production={name:d.digest(HERE/name)for name in ['download_production_build.py','download_candidate.py']})
def current(root):
    value=json.loads((root/'evidence/result.json').read_bytes())
    if json.loads((root/'reservation.json').read_bytes())['action']!=PREFIX+'build'or not value.get('passed')or value.get('sources')!=sources()or value.get('testFeature')is not False:raise RuntimeError('Current production-profile worker proof required')
    frozen();binary=root/'source/worker-bin'
    if d.digest(binary)!=value['binarySHA256']:raise RuntimeError('Production-profile image changed')
    return value,binary
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--level',type=int,choices=[2,3],required=True);args=parser.parse_args()
    vendor,_=frozen();before=sources();root=reserve('build')
    report=dict(passed=False,sources=before,testFeature=False,optimizationLevel=args.level,functionalOnly=False,testImage=False,networkSockets=0)
    try:
        if smb.TOOLING_LIMIT-smb.usage(smb.TOOLING,smb.TOOLING_LIMIT)['bytes']<48<<20:raise RuntimeError('Production compiler headroom unavailable')
        base=root/'source';graph=base/'worker';shutil.copytree(HERE/'smb2-browser',graph,ignore=shutil.ignore_patterns('.DS_Store'))
        child.directory(base/'catalog')
        for name in ['catalog.rs','StoreAuthority.c']:shutil.copyfile(HERE/'catalog'/name,base/'catalog'/name)
        for name in ['common.rs','auth_security.rs']:shutil.copyfile(HERE/name,base/name)
        prepare.patch(graph)
        manifest=graph/'Cargo.toml';text=prepare.exact(manifest.read_text(),'path = "../../../Vendor/smb2", default-features = false, features = ["tokio"]',
            'path = '+json.dumps(str(vendor))+', default-features = false, features = ["tokio"]')
        text+='\n[[bin]]\nname = "'+BINARY+'"\npath = "src/main.rs"\n\n[profile.release.package.smb2]\nopt-level = '+str(args.level)+'\ncodegen-units = 16\n'
        manifest.write_text(text);copied={str(p.relative_to(base)):d.digest(p)for p in base.rglob('*')if p.is_file()}
        env=environment(root);command=['/usr/bin/env','-i',*[k+'='+v for k,v in sorted(env.items())],str(smb.TOOLCHAIN/'bin/cargo'),'build','--manifest-path',str(manifest),'--locked','--offline','--release','--jobs','1','--bin',BINARY]
        d.put(root/'inputs.json',dict(sources=before,copiedSources=copied,command=command,maximumRSSBytes=512<<20,maximumCaseBytes=128<<20,testFeature=False,networkSockets=0))
        value,_,_=child.run(command,root,'production-worker-build',timeout=240,observer=lambda _:audit(building=True));report['process']=value
        if not value['passed']or value['peakRSSBytes']>512<<20:raise RuntimeError('Production compiler/resource gate')
        shutil.copyfile(smb.TOOLING/'target/release'/BINARY,base/'worker-bin');(base/'worker-bin').chmod(0o700)
        if before!=sources()or any(d.digest(base/name)!=v for name,v in copied.items()):raise RuntimeError('Production worker source fence changed')
        frozen();report.update(passed=True,binarySHA256=d.digest(base/'worker-bin'),copiedSources=copied)
    except BaseException as error:report['failure']=type(error).__name__;raise
    finally:
        report['usage']=audit();d.put(root/'evidence/result.json',report)
        if d.measure(root)['bytes']>128<<20:raise RuntimeError('Production compiler case ceiling')
    print(json.dumps(dict(case=root.name,passed=True,optimizationLevel=args.level,testFeature=False)),flush=True)
if __name__=='__main__':main()
