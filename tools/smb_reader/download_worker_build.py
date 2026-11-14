#!/usr/bin/env python3
"""Source-bound copied worker build. No TCP endpoint or app activation."""
import argparse,json,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
from download_worker_packet import HERE,d,child,smb,reserve,audit,environment,observe
import checked_download_build as core
import prepare_download_worker as prepare
CORE='14939416-C467-49AD-BBE5-D9334DF7D7B9'
CONTROL='E0AD34CB-5941-4D19-8D58-B2DDEE43CE17'
BINARY='traverse-smb-download-worker-prototype'
def sources():
    paths=[*list((HERE/'smb2-browser').rglob('*.rs')),HERE/'smb2-browser/Cargo.toml',HERE/'smb2-browser/Cargo.lock',
        HERE/'common.rs',HERE/'auth_security.rs',HERE/'catalog/catalog.rs',HERE/'catalog/StoreAuthority.c',
        *[HERE/name for name in ['selected_catalog.rs','download_wire.rs','download_network.rs','prepare_download_worker.py','download_worker_build.py','download_worker_packet.py']]]
    if(HERE/'download_worker_controls.rs').exists():paths.append(HERE/'download_worker_controls.rs')
    return {str(p.relative_to(d.REPO)):d.digest(p)for p in paths}
def frozen():
    proof,_=core.current(d.ROOT/CORE)
    control=json.loads((d.ROOT/CONTROL/'evidence/result.json').read_bytes())
    if not control['passed']or control['sources']!=proof['sources']or control.get('controls',{}).get('checks')!=217:raise RuntimeError('Passed 217-control source-bound core required')
    graph=d.ROOT/CORE/'source/graph'
    if any(d.digest(graph/name)!=value for name,value in proof['copiedSources'].items()):raise RuntimeError('Frozen core graph changed')
    return graph/'vendor',proof
def current(root):
    value=json.loads((root/'evidence/result.json').read_bytes())
    if not value['passed']or value['sources']!=sources():raise RuntimeError('Current whole-worker build proof required')
    frozen()
    binary=root/'source'/('worker-tests'if value['testImage']else'worker-bin')
    if d.digest(binary)!=value['binarySHA256']:raise RuntimeError('Worker image changed')
    return value,binary
def main():
    p=argparse.ArgumentParser();p.add_argument('--tests',action='store_true');args=p.parse_args()
    core.verify();vendor,proof=frozen();before=sources();root=reserve('build')
    report=dict(passed=False,sources=before,coreCase=CORE,controlCase=CONTROL,functionalOnly=True,testImage=args.tests,networkSockets=0)
    try:
        if smb.TOOLING_LIMIT-smb.usage(smb.TOOLING,smb.TOOLING_LIMIT)['bytes']<32<<20:raise RuntimeError('Insufficient existing SMB compiler headroom')
        base=child.directory(root/'source');graph=base/'worker'
        shutil.copytree(HERE/'smb2-browser',graph,ignore=shutil.ignore_patterns('.DS_Store'))
        child.directory(base/'catalog')
        for name in ['catalog.rs','StoreAuthority.c']:shutil.copyfile(HERE/'catalog'/name,base/'catalog'/name)
        for name in ['common.rs','auth_security.rs']:shutil.copyfile(HERE/name,base/name)
        prepare.patch(graph)
        if(HERE/'download_worker_controls.rs').exists():
            shutil.copyfile(HERE/'download_worker_controls.rs',graph/'src/download_worker_controls.rs')
            path=graph/'src/main.rs';path.write_text(path.read_text()+'\n#[cfg(test)]mod download_worker_controls;\n')
        path=graph/'Cargo.toml';text=path.read_text()
        text=prepare.exact(text,'path = "../../../Vendor/smb2", default-features = false, features = ["tokio"]',
            'path = '+json.dumps(str(vendor))+', default-features = false, features = ["tokio","b12-qualification"]')
        text+='\n[[bin]]\nname = "'+BINARY+'"\npath = "src/main.rs"\n\n[profile.release.package.smb2]\nopt-level = 1\ncodegen-units = 16\n'
        path.write_text(text)
        graph_hashes={str(p.relative_to(base)):d.digest(p)for p in base.rglob('*')if p.is_file()}
        env=environment(root);prefix=['/usr/bin/env','-i',*[key+'='+value for key,value in sorted(env.items())]]
        command=prefix+[str(smb.TOOLCHAIN/'bin/cargo'),'test'if args.tests else'build','--manifest-path',str(path),'--locked','--offline','--release','--jobs','1','--bin',BINARY]
        if args.tests:command+=['--no-run','--message-format=json']
        inputs=json.loads((root/'admission.json').read_bytes());inputs.update(sources=before,copiedSources=graph_hashes,command=command,coreCase=CORE,controlCase=CONTROL,maximumRSSBytes=512<<20,functionalOnly=True)
        d.put(root/'inputs.json',inputs)
        value,out,_=child.run(command,root,'whole-worker-build',timeout=240,observer=observe);report['process']=value
        if not value['passed']or value['peakRSSBytes']>512<<20:raise RuntimeError('Whole-worker compile/resource gate')
        if args.tests:
            images=[json.loads(line)['executable']for line in out.read_text().splitlines()if line.startswith('{')and json.loads(line).get('reason')=='compiler-artifact'and json.loads(line).get('executable')and json.loads(line).get('profile',{}).get('test')]
            if len(images)!=1:raise RuntimeError('Exact one test image required')
            source=Path(images[0]);name='worker-tests'
        else:source=smb.TOOLING/'target/release'/BINARY;name='worker-bin'
        shutil.copyfile(source,base/name);(base/name).chmod(0o700)
        if any(d.digest(base/name)!=value for name,value in graph_hashes.items()):raise RuntimeError('Owned source graph changed during compile')
        if sources()!=before:raise RuntimeError('Current source fence changed')
        frozen();report.update(passed=True,binarySHA256=d.digest(base/name),copiedSources=graph_hashes)
    except BaseException as error:report['failure']=type(error).__name__;raise
    finally:
        report['usage']=audit();d.put(root/'evidence/result.json',report)
        if d.measure(root)['bytes']>128<<20:raise RuntimeError('Worker compiler case bound')
    print(json.dumps(dict(case=root.name,passed=True,testImage=args.tests)),flush=True)
if __name__=='__main__':main()
