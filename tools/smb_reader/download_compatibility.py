#!/usr/bin/env python3
"""Red/green frozen-reader replay and bounded optimized compatibility image."""
import argparse,json,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
from download_worker_packet import HERE,d,child,smb,environment
from download_worker_build import frozen,prepare,sources as worker_sources
PREFIX='smb-selected-download-compatibility-'
def cases():return [p.parent for p in d.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action','').startswith(PREFIX)]
def audit(building=False):
    value=child.audit()
    if sum(d.measure(r)['bytes']for r in cases())>256<<20 or sum(d.measure(r)['entries']for r in cases())>4096:raise RuntimeError('Compatibility subpacket ceiling')
    value['smbTooling']=smb.usage(smb.TOOLING,smb.TOOLING_LIMIT,building=building,compiler_locks=building);return value
def reserve(kind):
    if kind not in ['build-red','build-green','build-production','test-red','test-green','test-production']:raise RuntimeError('Unreviewed compatibility action')
    child.prepare();audit()
    if any(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in cases()):raise RuntimeError('This compatibility admission is consumed')
    return d.reserve(PREFIX+kind)
def sources():return dict(wrapper=worker_sources(),compatibility=d.digest(Path(__file__)))
def current(root,kind=None):
    value=json.loads((root/'evidence/result.json').read_bytes());action=json.loads((root/'reservation.json').read_bytes())['action']
    if action not in [PREFIX+'build-red',PREFIX+'build-green',PREFIX+'build-production']or kind and action!=PREFIX+'build-'+kind \
        or not value.get('passed')or value.get('sources')!=sources():raise RuntimeError('Current compatibility image required')
    frozen();binary=root/'source/worker-bin'
    if d.digest(binary)!=value['binarySHA256']:raise RuntimeError('Compatibility image changed')
    return value,binary
CONTROL=r'''
async fn compatibility_case(kind:u8)->usize {
    let(conn,mock,policy)=setup(true);let mut replies=vec![create(0)];replies.extend(metadata(0));replies.push(eof().raw);
    let mut after=metadata(0);
    match kind {
        0=>after[0][72..80].copy_from_slice(&101u64.to_le_bytes()),
        1=>after[3][72..80].copy_from_slice(&501u64.to_le_bytes()),
        2=>{after[0][72..80].copy_from_slice(&101u64.to_le_bytes());after[3][72..80].copy_from_slice(&501u64.to_le_bytes());},
        3=>after[0][80..88].copy_from_slice(&900u64.to_le_bytes()),
        4=>after[1][80..88].copy_from_slice(&1u64.to_le_bytes()),
        5=>after[1][72..80].copy_from_slice(&4096u64.to_le_bytes()),
        6=>after[0][88..96].copy_from_slice(&301u64.to_le_bytes()),
        7=>after[0][96..104].copy_from_slice(&401u64.to_le_bytes()),
        8=>after[0][104..108].copy_from_slice(&0x21u32.to_le_bytes()),
        9=>after[1][88..92].copy_from_slice(&2u32.to_le_bytes()),
        10=>after[2][72..80].copy_from_slice(&43u64.to_le_bytes()),
        11=>after[3][80..84].copy_from_slice(&14u32.to_le_bytes()),_=>unreachable!(),
    }
    replies.extend(after);if kind<4{replies.push(close(0));}mock.queue_responses(replies);
    let name="Generated.txt".encode_utf16().collect::<Vec<_>>();
    let reader=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:0,modified:300}).await.unwrap();
    let result=reader.finish().await;assert_eq!(result.is_ok(),kind<4,"creation-time compatibility case {kind}");
    assert_eq!(matches!(*policy.state.lock().unwrap(),State::Idle),kind<4);
    drain(&conn,&mock).await;1
}
pub async fn compatibility_run()->Result<usize>{let mut n=0;for kind in 0..12{n+=compatibility_case(kind).await;}Ok(n)}
'''
KEY='''
impl FileSnapshot {
    /// Creation fields may be POSIX approximations affected by our own READ.
    /// The held handle plus these exact witnesses guard source consistency.
    fn same_source(&self,other:&Self)->bool {
        self.size==other.size&&self.allocated==other.allocated&&self.modified==other.modified
            &&self.changed==other.changed&&self.attributes==other.attributes&&self.links==other.links
            &&self.index==other.index&&self.volume_serial==other.volume_serial
    }
}
'''
def patch(vendor,green):
    reader=vendor/'src/client/selected_download.rs';text=reader.read_text()
    text=prepare.exact(text,'controls::run().await','let n=controls::run().await?;Ok(n+controls::compatibility_run().await?)')
    if green:
        text=prepare.exact(text,'if &after!=self.snapshot(){return Err(invalid());}','if !self.snapshot().same_source(&after){return Err(invalid());}')+KEY
    reader.write_text(text);controls=vendor/'src/client/selected_download_controls.rs';controls.write_text(controls.read_text()+CONTROL)
def build(kind,green_case):
    vendor,_=frozen();before=sources();root=reserve('build-'+kind);base=root/'source';graph=base/'graph';report=dict(passed=False,sources=before,kind=kind,networkSockets=0)
    try:
        if smb.TOOLING_LIMIT-smb.usage(smb.TOOLING,smb.TOOLING_LIMIT)['bytes']<48<<20:raise RuntimeError('Compatibility compiler headroom')
        if kind=='production':
            proof,_=current(d.ROOT/green_case,'green');control=json.loads((d.ROOT/proof['greenControlCase']/'evidence/result.json').read_bytes())if'greenControlCase'in proof else None
            # The immutable build receipt cannot be amended by its later test.
            tests=[r for r in cases()if json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+'test-green']
            if len(tests)!=1 or not json.loads((tests[0]/'evidence/result.json').read_bytes()).get('passed'):raise RuntimeError('Passed repaired229-control replay required')
            borrowed=d.ROOT/green_case/'source/graph/vendor'
            if any(d.digest(d.ROOT/green_case/'source'/name)!=value for name,value in proof['copiedSources'].items()):raise RuntimeError('Repaired frozen graph changed')
            shutil.copytree(borrowed,base/'vendor');target=base/'worker';shutil.copytree(HERE/'smb2-browser',target);child.directory(base/'catalog')
            for name in ['catalog.rs','StoreAuthority.c']:shutil.copyfile(HERE/'catalog'/name,base/'catalog'/name)
            for name in ['common.rs','auth_security.rs']:shutil.copyfile(HERE/name,base/name)
            prepare.patch(target);manifest=target/'Cargo.toml';text=prepare.exact(manifest.read_text(),'path = "../../../Vendor/smb2", default-features = false, features = ["tokio"]',
                'path = '+json.dumps(str(base/'vendor'))+', default-features = false, features = ["tokio"]')
            name='traverse-smb-download-compatible-production';text+='\n[[bin]]\nname = "'+name+'"\npath = "src/main.rs"\n\n[profile.release.package.smb2]\nopt-level = 3\ncodegen-units = 16\n'
            manifest.write_text(text);report['greenBuildCase']=green_case;report['greenControlCase']=tests[0].name
        else:
            previous=d.ROOT/'14939416-C467-49AD-BBE5-D9334DF7D7B9/source/graph';shutil.copytree(previous,graph);patch(graph/'vendor',kind=='green')
            manifest=graph/'Cargo.toml';name='traverse-smb-selected-download-controls'
        copied={str(p.relative_to(base)):d.digest(p)for p in base.rglob('*')if p.is_file()};env=environment(root)
        command=['/usr/bin/env','-i',*[k+'='+v for k,v in sorted(env.items())],str(smb.TOOLCHAIN/'bin/cargo'),'build','--manifest-path',str(manifest),'--locked','--offline','--release','--jobs','1','--bin',name]
        d.put(root/'inputs.json',dict(sources=before,copiedSources=copied,command=command,maximumRSSBytes=512<<20,maximumCaseBytes=128<<20,networkSockets=0))
        value,_,_=child.run(command,root,'compatibility-build',timeout=240,observer=lambda _:audit(building=True));report['process']=value
        if not value['passed']or value['peakRSSBytes']>512<<20:raise RuntimeError('Compatibility compiler/resource gate')
        shutil.copyfile(smb.TOOLING/'target/release'/name,base/'worker-bin');(base/'worker-bin').chmod(0o700)
        if before!=sources()or any(d.digest(base/p)!=value for p,value in copied.items()):raise RuntimeError('Compatibility source fence changed')
        report.update(passed=True,copiedSources=copied,binarySHA256=d.digest(base/'worker-bin'))
    except BaseException as error:report['failure']=type(error).__name__;raise
    finally:report['usage']=audit();d.put(root/'evidence/result.json',report)
    print(json.dumps(dict(case=root.name,passed=True,kind=kind)),flush=True)
def test(kind,build_case):
    proof,binary=current(d.ROOT/build_case,kind);root=reserve('test-'+kind);report=dict(passed=False,buildCase=build_case,networkSockets=0)
    d.put(root/'inputs.json',dict(buildCase=build_case,kind=kind,actualTestLaunches=1,maximumRSSBytes=256<<20,maximumCaseBytes=64<<20))
    try:
        value,out,err=child.run([str(binary)],root,'compatibility-controls',timeout=20,observer=lambda _:audit());report['process']=value
        if kind=='red':
            expected=value['actualExit']==101 and 'creation-time compatibility case 0'in err.read_text()and not value['contained']
            report.update(expectedRed=expected,accepted=expected)
            if not expected:raise RuntimeError('Exact old birthtime mismatch did not go red')
        else:
            controls=json.loads(out.read_bytes());report['controls']=controls
            if not value['passed']or value['peakRSSBytes']>256<<20 or controls!=dict(passed=True,checks=229,networkSockets=0):raise RuntimeError('229 repaired controls required')
            report['passed']=True
    except BaseException as error:report['failure']=type(error).__name__;raise
    finally:report['usage']=audit();d.put(root/'evidence/result.json',report)
    print(json.dumps(dict(case=root.name,passed=report['passed'],expectedRed=report.get('expectedRed',False))),flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('phase',choices=['build','test']);p.add_argument('--kind',choices=['red','green','production'],required=True);p.add_argument('--build-case');p.add_argument('--green-case');a=p.parse_args()
    if a.phase=='build':build(a.kind,a.green_case)
    elif a.kind!='production'and a.build_case:test(a.kind,a.build_case)
    else:raise RuntimeError('Production entry controls use their own exact process driver')
