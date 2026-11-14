#!/usr/bin/env python3
"""Copied SMB checked-reader qualification; ordinary vendor/helper unchanged."""
import argparse,importlib.util,json,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path[:0]=[str(HERE),str(HERE.parent)]
import packet as smb
from vendor_verified_source import verify,source_inventory
spec=importlib.util.spec_from_file_location('checked_smb_owned_process',HERE.parent/'ssh_profiles/packet.py')
process=importlib.util.module_from_spec(spec);spec.loader.exec_module(process)
d=process.d
ACTION='smb-checked-download-'
def exact(text,old,new):
    if text.count(old)!=1:raise RuntimeError('Copied current SMB seam changed: '+old[:90])
    return text.replace(old,new,1)
def sources():
    paths=[HERE/name for name in ['selected_download.rs','selected_download_controls.rs','checked_download_build.py']]
    return dict(probes={p.name:d.digest(p)for p in paths},vendor=source_inventory(d.REPO/'Vendor/smb2'),
        provenance=d.digest(d.REPO/'Vendor/smb2/PROVENANCE.json'),lock=d.digest(HERE/'smb2-browser/Cargo.lock'))
def patch(vendor):
    for name in ['selected_download.rs','selected_download_controls.rs']:shutil.copyfile(HERE/name,vendor/'src/client'/name)
    path=vendor/'src/client/mod.rs';path.write_text(exact(path.read_text(),'pub mod connection;','pub mod connection;\npub mod selected_download;'))
    path=vendor/'src/client/connection.rs';text=path.read_text()
    text=exact(text,'mod b10_metadata;','pub(crate) mod b10_metadata;')
    text=exact(text,'    b10_commands: [AtomicU64; 19],','    b10_commands: [AtomicU64; 19],\n    b12_download_policy: StdMutex<Option<Arc<super::selected_download::SelectedDownloadPolicy>>>,')
    text=exact(text,'            b10_commands: std::array::from_fn(|_| AtomicU64::new(0)),','            b10_commands: std::array::from_fn(|_| AtomicU64::new(0)),\n            b12_download_policy: StdMutex::new(None),')
    text=exact(text,'    async fn send_and_count(self: &Arc<Self>, bytes: &[u8], command: Command) -> Result<()> {','''    fn permitted_plaintext(&self, bytes:&[u8])->bool {
        let policy=self.b12_download_policy.lock().unwrap().clone();
        policy.map_or_else(||b10_metadata::permitted_frame(bytes),|p|p.permits_frame(bytes))
    }
    async fn send_and_count(self: &Arc<Self>, bytes: &[u8], command: Command) -> Result<()> {''')
    text=exact(text,'''        if code >= 19 || ![0, 1, 2, 3, 4, 5, 6, 12, 13, 14].contains(&code)
            || (!bytes.starts_with(b"\\xfdSMB") && !b10_metadata::permitted_frame(bytes)) {''','''        let policy=self.b12_download_policy.lock().unwrap().clone();
        let allowed=policy.map_or_else(||[0,1,2,3,4,5,6,12,13,14].contains(&code),|p|p.allows_command(code));
        if code >= 19 || !allowed
            || (!bytes.starts_with(b"\\xfdSMB") && !self.permitted_plaintext(bytes)) {''')
    text=exact(text,'        if !b10_metadata::permitted_frame(plaintext) || plaintext.len() > b10_security::FRAME_CAP - 52 {',
        '        if !self.inner.permitted_plaintext(plaintext) || plaintext.len() > b10_security::FRAME_CAP - 52 {')
    text=exact(text,'    pub fn params(&self) -> Option<NegotiatedParams> {','''    /// Attach one selected-file policy before negotiation; ordinary connections omit it.
    pub fn set_selected_download_policy(&mut self, policy:Arc<super::selected_download::SelectedDownloadPolicy>)->Result<()> {
        if self.params().is_some() || self.session_id().0!=0 {return Err(Error::invalid_data("Selected download policy must precede negotiation"));}
        let mut old=self.inner.b12_download_policy.lock().unwrap();
        if old.is_some(){return Err(Error::invalid_data("Selected download policy already installed"));}
        policy.claim()?;*old=Some(policy);Ok(())
    }
    pub(crate) fn selected_download_policy(&self)->Result<Arc<super::selected_download::SelectedDownloadPolicy>> {
        self.inner.b12_download_policy.lock().unwrap().clone().ok_or_else(||Error::invalid_data("Metadata connection has no download authority"))
    }
    /// Current negotiated parameters, unchanged by selected-download authority.
    pub fn params(&self) -> Option<NegotiatedParams> {''')
    for name in ['set_test_params','set_credits']:
        text=exact(text,'    #[cfg(test)]\n    pub(crate) fn '+name,'    #[cfg(any(test,feature="b12-qualification"))]\n    pub(crate) fn '+name)
    path.write_text(text)
    path=vendor/'src/client/credits.rs';path.write_text(exact(path.read_text(),
        '    #[cfg(test)]\n    pub(crate) fn set_available(',
        '    #[cfg(any(test,feature="b12-qualification"))]\n    pub(crate) fn set_available('))
    path=vendor/'Cargo.toml';path.write_text(exact(path.read_text(),'[features]','[features]\nb12-qualification = []'))
def current(root):
    record=json.loads((root/'evidence/result.json').read_bytes())
    if not record['passed']or record['sources']!=sources():raise RuntimeError('Current copied control proof required')
    binary=root/'source/controls'
    if d.digest(binary)!=record['binarySHA256']:raise RuntimeError('Copied control binary changed')
    return record,binary
def main():
    p=argparse.ArgumentParser();p.add_argument('phase',choices=['build','test']);p.add_argument('--build-case');p.add_argument('--low-memory',action='store_true');p.add_argument('--completion',action='store_true');a=p.parse_args();process.prepare();verify()
    if a.low_memory and a.phase!='build':raise RuntimeError('Low-memory profile applies to compilation only')
    if a.completion and a.phase=='build'and not a.low_memory:raise RuntimeError('Completion compiler keeps the low-memory functional profile')
    action=ACTION+a.phase+('-completion'if a.completion else'-low-memory'if a.low_memory else'')
    cases=[m.parent for m in d.ROOT.glob('*/reservation.json')if json.loads(m.read_bytes()).get('action','').startswith(ACTION)]
    count=sum(json.loads((r/'reservation.json').read_bytes())['action']==action for r in cases)
    if count>=((4 if a.phase=='build'else 3)if a.completion else 2 if a.low_memory or a.phase=='test'else 4):raise RuntimeError('Finite checked-reader compiler/test attempts consumed')
    if sum(d.measure(r)['bytes']for r in cases)>256<<20 or sum(d.measure(r)['entries']for r in cases)>4096:raise RuntimeError('Checked-reader subpacket ceiling')
    root=d.reserve(action);before=sources();report=dict(passed=False,sources=before,ordinaryChanged=False,networkSockets=0,functionalOnly=a.low_memory)
    env=smb.environment();env['SDKROOT']=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
    def observe(_):
        if smb.usage(smb.TOOLING,smb.TOOLING_LIMIT,building=True)['bytes']>smb.TOOLING_LIMIT:raise RuntimeError('Existing SMB tooling cap')
    try:
        if a.phase=='build':
            available=smb.TOOLING_LIMIT-smb.usage(smb.TOOLING,smb.TOOLING_LIMIT)['bytes']
            if available<64<<20:raise RuntimeError('Insufficient isolated compiler headroom')
            graph=process.directory(root/'source/graph');vendor=graph/'vendor';shutil.copytree(d.REPO/'Vendor/smb2',vendor,ignore=shutil.ignore_patterns('.DS_Store'))
            patch(vendor)
            manifest=(HERE/'smb2-browser/Cargo.toml').read_text().replace('build = "build.rs"\n','')
            manifest=exact(manifest,'[workspace]','[workspace]\nexclude = ["vendor"]')
            manifest=exact(manifest,'path = "../../../Vendor/smb2", default-features = false, features = ["tokio"]','path = "vendor", default-features = false, features = ["tokio","b12-qualification"]')
            manifest+='\n[[bin]]\nname = "traverse-smb-selected-download-controls"\npath = "src/main.rs"\n'
            manifest+='\n[profile.release.package.smb2]\ncodegen-units = '+('16\nopt-level = 1'if a.low_memory else'1')+'\n'
            (graph/'Cargo.toml').write_text(manifest);shutil.copyfile(HERE/'smb2-browser/Cargo.lock',graph/'Cargo.lock')
            process.directory(graph/'src');(graph/'src/main.rs').write_text('''#[tokio::main(flavor="current_thread")]
async fn main(){match smb2::client::selected_download::qualification_run().await{
    Ok(n)=>println!("{{\\\"passed\\\":true,\\\"checks\\\":{n},\\\"networkSockets\\\":0}}"),
    Err(_)=>{eprintln!("checked SMB control failed");std::process::exit(2);}}}
''')
            hashes={str(p.relative_to(graph)):d.digest(p)for p in graph.rglob('*')if p.is_file()}
            command=['/usr/bin/env','-i',*[key+'='+value for key,value in sorted(env.items())],str(smb.TOOLCHAIN/'bin/cargo'),'build',
                '--manifest-path',str(graph/'Cargo.toml'),'--locked','--offline','--release','--jobs','1','--bin','traverse-smb-selected-download-controls']
            d.put(root/'inputs.json',dict(phase=a.phase,sources=before,copiedSources=hashes,command=command,maximumRSSBytes=512<<20,maximumCaseBytes=128<<20,functionalOnly=a.low_memory))
            value,_,_=process.run(command,root,'checked-reader-build',timeout=240,observer=observe)
            report.update(process=value,copiedSources=hashes)
            if not value['passed']or value['peakRSSBytes']>512<<20:raise RuntimeError('Copied checked-reader compile/resource gate')
            original=smb.TOOLING/'target/release/traverse-smb-selected-download-controls';shutil.copyfile(original,root/'source/controls')
            (root/'source/controls').chmod(0o700);report.update(binarySHA256=d.digest(root/'source/controls'))
            if any(d.digest(graph/name)!=v for name,v in hashes.items()):raise RuntimeError('Copied compile graph changed')
        else:
            if not a.build_case:raise RuntimeError('Exact copied compiler proof required')
            proof,binary=current(d.ROOT/a.build_case)
            report['functionalOnly']=proof.get('functionalOnly',False)
            command=['/usr/bin/env','-i',*[key+'='+value for key,value in sorted(env.items())],str(binary)]
            d.put(root/'inputs.json',dict(phase=a.phase,buildCase=a.build_case,sources=before,maximumRSSBytes=256<<20,maximumCaseBytes=64<<20,networkSockets=0))
            value,out,_=process.run(command,root,'checked-reader-tests',timeout=60,observer=observe)
            report.update(process=value)
            if not value['passed']or value['peakRSSBytes']>256<<20:raise RuntimeError('Actual checked-reader controls failed')
            controls=json.loads(out.read_bytes());report['controls']=controls
            if controls.get('passed')is not True or controls.get('checks',0)<200 or controls.get('networkSockets')!=0:raise RuntimeError('Incomplete checked-reader controls')
            if d.digest(binary)!=proof['binarySHA256']:raise RuntimeError('Checked-reader image changed')
        if sources()!=before:raise RuntimeError('Ordinary source/probe fence changed')
        report['passed']=True
    except BaseException as error:report['failure']=type(error).__name__;raise
    finally:
        report.update(usage=process.audit(),smbTooling=smb.usage(smb.TOOLING,smb.TOOLING_LIMIT));d.put(root/'evidence/result.json',report)
        all_cases=cases+[root]
        if sum(d.measure(r)['bytes']for r in all_cases)>256<<20 or sum(d.measure(r)['entries']for r in all_cases)>4096:raise RuntimeError('Checked-reader subpacket bound')
    print(json.dumps(dict(case=root.name,passed=True,phase=a.phase,checks=report.get('controls',{}).get('checks'))),flush=True)
if __name__=='__main__':main()
