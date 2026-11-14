//! Generated binary SFTP peer; every request comes from the actual retained
//! Channel/kernel. This is NOT SSH/authentication/signed-helper/server proof.
use super::*;
use std::{collections::HashMap,sync::{Mutex,atomic::{AtomicBool,Ordering}}};
use tokio::io::{AsyncReadExt,AsyncWriteExt,DuplexStream};
/// Test-owned Drop observation of the actual stream handed to the kernel.
struct ObservedStream { inner:DuplexStream, dropped:Arc<AtomicBool> }
impl AsyncRead for ObservedStream {
    fn poll_read(self:std::pin::Pin<&mut Self>,cx:&mut std::task::Context<'_>,out:&mut tokio::io::ReadBuf<'_>)->std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().inner).poll_read(cx,out)
    }
}
impl AsyncWrite for ObservedStream {
    fn poll_write(self:std::pin::Pin<&mut Self>,cx:&mut std::task::Context<'_>,bytes:&[u8])->std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.get_mut().inner).poll_write(cx,bytes)
    }
    fn poll_flush(self:std::pin::Pin<&mut Self>,cx:&mut std::task::Context<'_>)->std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }
    fn poll_shutdown(self:std::pin::Pin<&mut Self>,cx:&mut std::task::Context<'_>)->std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}
impl Drop for ObservedStream { fn drop(&mut self){self.dropped.store(true,Ordering::Release);} }

#[derive(Clone)]struct Node{bytes:Vec<u8>,mode:u32,uid:u32,gid:u32,modified:u32,inode:u64,acl:Vec<u8>,xattr:Vec<u8>}
#[derive(Clone,Copy,PartialEq,Eq)]enum Fault{None,PrivilegedAfterWrite,ModeAfterWrite,NoSync,MalformedSyncThenDuplicate,ReadOnly,DeniedStat,LostWrite,LostTruncate,LostSync,ReplaceAtWrite,ExternalBeforeWrite,Hold(u8),BadID}
struct State{current:Arc<Mutex<Node>>,original:Arc<Mutex<Node>>,handles:HashMap<Vec<u8>,Arc<Mutex<Node>>>,next:u32,
    fault:Fault,opcodes:Vec<u8>,opens:Vec<u32>,writes:usize,hold:Arc<AtomicBool>}
fn field_at<'a>(bytes:&'a[u8],at:&mut usize)->&'a[u8]{let n=u32::from_be_bytes(bytes[*at..*at+4].try_into().unwrap())as usize;*at+=4;let out=&bytes[*at..*at+n];*at+=n;out}
fn status(id:&[u8],code:u32)->Vec<u8>{let mut b=vec![101];b.extend(id);b.extend(code.to_be_bytes());field(&mut b,b"");field(&mut b,b"");b}
fn attributes(id:&[u8],v:&Node)->Vec<u8>{let mut b=vec![105];b.extend(id);b.extend(15u32.to_be_bytes());b.extend((v.bytes.len()as u64).to_be_bytes());b.extend(v.uid.to_be_bytes());b.extend(v.gid.to_be_bytes());b.extend(v.mode.to_be_bytes());b.extend(v.modified.to_be_bytes());b.extend(v.modified.to_be_bytes());b}
impl State{
    fn new(fault:Fault,old:&[u8])->Self{let node=Arc::new(Mutex::new(Node{bytes:old.to_vec(),mode:0o100640,uid:501,gid:20,modified:77,inode:444,acl:b"named-user-deny".to_vec(),xattr:b"security-attachment".to_vec()}));
        Self{current:node.clone(),original:node,handles:HashMap::new(),next:1,fault,opcodes:vec![],opens:vec![],writes:0,hold:Arc::new(AtomicBool::new(false))}}
    fn response(&mut self,b:&[u8])->Option<Vec<u8>>{
        self.opcodes.push(b[0]);if b[0]==1{let mut v=vec![2,0,0,0,3];
            if self.fault==Fault::MalformedSyncThenDuplicate{field(&mut v,b"fsync@openssh.com");field(&mut v,b"2");field(&mut v,b"fsync@openssh.com");field(&mut v,b"1");}
            else if self.fault!=Fault::NoSync{field(&mut v,b"fsync@openssh.com");field(&mut v,b"1")};return Some(v)}
        let id=&b[1..5];let mut at=5;
        let reply=match b[0]{
            7=>{assert_eq!(field_at(b,&mut at),b"/generated/file.txt");if self.fault==Fault::DeniedStat{return Some(status(id,3))}attributes(id,&self.current.lock().unwrap())},
            8=>{let h=field_at(b,&mut at);attributes(id,&self.handles[h].lock().unwrap())},
            3=>{assert_eq!(field_at(b,&mut at),b"/generated/file.txt");let flags=u32::from_be_bytes(b[at..at+4].try_into().unwrap());self.opens.push(flags);
                assert!(flags==1||flags==3,"unexpected CREATE/TRUNC/APPEND");if flags==3&&self.fault==Fault::ReadOnly{return Some(status(id,3))}
                let h=self.next.to_be_bytes().to_vec();self.next+=1;self.handles.insert(h.clone(),self.current.clone());let mut v=vec![102];v.extend(id);field(&mut v,&h);v},
            4=>{let h=field_at(b,&mut at);assert!(self.handles.remove(h).is_some());status(id,0)},
            5=>{let h=field_at(b,&mut at);let offset=u64::from_be_bytes(b[at..at+8].try_into().unwrap())as usize;at+=8;let count=u32::from_be_bytes(b[at..at+4].try_into().unwrap())as usize;
                let n=self.handles[h].lock().unwrap();if offset>=n.bytes.len(){status(id,1)}else{let mut v=vec![103];v.extend(id);field(&mut v,&n.bytes[offset..(offset+count).min(n.bytes.len())]);v}},
            6=>{let h=field_at(b,&mut at);let offset=u64::from_be_bytes(b[at..at+8].try_into().unwrap())as usize;at+=8;let bytes=field_at(b,&mut at);
                if self.fault==Fault::ReplaceAtWrite&&self.writes==0{self.current=Arc::new(Mutex::new(Node{bytes:b"foreign recreated destination\n".to_vec(),mode:0o100640,uid:501,gid:20,modified:88,inode:445,acl:b"other-acl".to_vec(),xattr:b"other-attachment".to_vec()}));}
                let mut n=self.handles[h].lock().unwrap();let length=n.bytes.len().max(offset+bytes.len());n.bytes.resize(length,0);n.bytes[offset..offset+bytes.len()].copy_from_slice(bytes);n.modified=78;if self.fault==Fault::PrivilegedAfterWrite{n.mode|=0o4000;}if self.fault==Fault::ModeAfterWrite{n.mode=0o100660;}self.writes+=1;
                if self.fault==Fault::LostWrite{return None}status(id,0)},
            10=>{let h=field_at(b,&mut at);assert_eq!(u32::from_be_bytes(b[at..at+4].try_into().unwrap()),1,"only size FSETSTAT allowed");at+=4;
                let size=u64::from_be_bytes(b[at..at+8].try_into().unwrap())as usize;let mut n=self.handles[h].lock().unwrap();n.bytes.resize(size,0);n.modified=78;
                if self.fault==Fault::LostTruncate{return None}status(id,0)},
            200=>{assert_eq!(field_at(b,&mut at),b"fsync@openssh.com");let h=field_at(b,&mut at);assert!(self.handles.contains_key(h));if self.fault==Fault::LostSync{return None}status(id,0)},
            _=>panic!("unexpected namespace/metadata mutation opcode"),
        };
        if matches!(self.fault,Fault::Hold(op)if op==b[0]&&(op!=5||self.writes>0)){
            self.hold.store(true,Ordering::Release);return None
        }
        if self.fault==Fault::BadID&&b[0]==6{let mut bad=reply;bad[1..5].copy_from_slice(&0u32.to_be_bytes());return Some(bad)}Some(reply)
    }
}
async fn peer(mut stream:DuplexStream,state:Arc<Mutex<State>>){
    loop{let mut p=[0;4];if stream.read_exact(&mut p).await.is_err(){break}let mut body=vec![0;u32::from_be_bytes(p)as usize];if stream.read_exact(&mut body).await.is_err(){break}
        let response={state.lock().unwrap().response(&body)};
        let Some(response)=response else{
            // A held ACK keeps the actual request outstanding until the client
            // closes; lost ACK faults close immediately after possible mutation.
            if matches!(state.lock().unwrap().fault,Fault::Hold(_)){let mut byte=[0;1];let _=stream.read(&mut byte).await;}break
        };
        if stream.write_all(&(response.len()as u32).to_be_bytes()).await.is_err()||stream.write_all(&response).await.is_err(){break}
    }
    state.lock().unwrap().handles.clear();
}
struct Sink{bytes:Arc<Mutex<Vec<u8>>>}
impl ReadSink for Sink{
    async fn begin(&mut self,v:Observed)->Result<(),Failure>{assert!(v.regular());Ok(())}
    async fn chunk(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),Failure>{let mut out=self.bytes.lock().unwrap();assert_eq!(offset,out.len()as u64);out.extend(bytes);Ok(())}
}
#[derive(Clone)]struct Input{bytes:Vec<u8>,deny:Option<u8>,facts:Arc<Mutex<(Vec<Step>,Vec<Step>)>>,state:Arc<Mutex<State>>}
impl Source for Input{
    fn size(&self)->u64{self.bytes.len()as u64}
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>,Failure>{Ok(self.bytes[offset as usize..offset as usize+count].to_vec())}
    async fn permit_publication(&mut self,_:[u8;32])->Result<(),Failure>{panic!("Source6 publication callback reused")}
}
impl Control for Input{
    fn expected_digest(&self)->[u8;32]{Sha256::digest(&self.bytes).into()}
    async fn permit(&mut self,step:Step,digest:[u8;32])->Result<(),Failure>{assert_eq!(digest,self.expected_digest());self.facts.lock().unwrap().0.push(step);
        if self.state.lock().unwrap().fault==Fault::ExternalBeforeWrite&&step.kind==Kind::Source{let state=self.state.lock().unwrap();let mut n=state.original.lock().unwrap();n.bytes=b"foreign pre-save body\n".to_vec();n.modified=79;}
        if self.deny==Some(step.sequence){Err(Failure::Io)}else{Ok(())}}
    async fn observed(&mut self,step:Step)->Result<(),Failure>{self.facts.lock().unwrap().1.push(step);Ok(())}
}
fn limits()->Limits{Limits{request_deadline:Duration::from_millis(500),total_deadline:Duration::from_secs(5)}}
async fn open(fault:Fault,old:&[u8],stop:Option<Arc<AtomicBool>>)->(Result<Session<DuplexStream>,Failure>,Arc<Mutex<State>>,tokio::task::JoinHandle<()>){
    let state=Arc::new(Mutex::new(State::new(fault,old)));let (a,b)=tokio::io::duplex(131072);let task=tokio::spawn(peer(b,state.clone()));
    let received=Arc::new(Mutex::new(Vec::new()));
    let result=Session::open(a,"/generated/file.txt".into(),Metadata{size:Some(old.len()as u64),modified:Some(77),permissions:Some(0o100640)},Sink{bytes:received.clone()},limits(),stop).await;
    if result.is_ok(){assert_eq!(*received.lock().unwrap(),old)}(result,state,task)
}
fn input(bytes:&[u8],deny:Option<u8>,state:Arc<Mutex<State>>)->Input{Input{bytes:bytes.to_vec(),deny,facts:Arc::new(Mutex::new((vec![],vec![]))),state}}
#[tokio::test(flavor="current_thread")]async fn shorter_longer_empty_unicode_multichunk_preserve_exact_object_and_security_attachment(){
    for bytes in [b"x\n".to_vec(),b"longer edited body\n".to_vec(),vec![],"हैलो 🐚\n".as_bytes().to_vec(),vec![b'x';100000]]{
        let (session,state,task)=open(Fault::None,b"original\n",None).await;let mut session=session.unwrap();let source=input(&bytes,None,state.clone());let facts=source.facts.clone();
        let receipt=session.save(source,limits()).await.unwrap();let expected:[u8;32]=Sha256::digest(&bytes).into();assert_eq!(receipt.digest,expected);assert_eq!(receipt.facts.requested,receipt.facts.acknowledged);
        {let state=state.lock().unwrap();assert!(Arc::ptr_eq(&state.current,&state.original));let node=state.original.lock().unwrap();assert_eq!(node.bytes,bytes);assert_eq!((node.inode,node.uid,node.gid,node.mode),(444,501,20,0o100640));assert_eq!(node.acl,b"named-user-deny");assert_eq!(node.xattr,b"security-attachment");assert_eq!(state.opens.iter().filter(|&&v|v==3).count(),1);assert_eq!(state.opcodes.iter().filter(|&&v|v==200).count(),1);let observed=facts.lock().unwrap();assert_eq!(observed.0,observed.1);}
        session.release(limits()).await.unwrap();task.await.unwrap();assert!(state.lock().unwrap().handles.is_empty());
    }
}
#[tokio::test(flavor="current_thread")]async fn every_denied_exact_step_prevents_its_request_and_retains_prior_facts(){
    for denied in plan(9,2).unwrap(){let (session,state,task)=open(Fault::None,b"original\n",None).await;let mut session=session.unwrap();let source=input(b"x\n",Some(denied.sequence),state.clone());
        let error=session.save(source,limits()).await.unwrap_err();assert_eq!(error.facts.requested,denied.sequence-1);assert_eq!(error.facts.requested,error.facts.acknowledged);
        if denied.sequence<=2{assert_eq!(state.lock().unwrap().original.lock().unwrap().bytes,b"original\n")}
        drop(session);task.await.unwrap();}
}
#[tokio::test(flavor="current_thread")]async fn lost_write_truncate_and_sync_ack_are_never_saved(){
    for fault in [Fault::LostWrite,Fault::LostTruncate,Fault::LostSync,Fault::BadID]{let (session,state,task)=open(fault,b"original\n",None).await;let mut session=session.unwrap();
        let error=session.save(input(b"x\n",None,state.clone()),limits()).await.unwrap_err();assert_eq!(error.facts.requested,error.facts.acknowledged+1);assert!(error.facts.requested>=2);let expected=match fault{Fault::LostTruncate=>(Phase::Truncating,3),Fault::LostSync=>(Phase::Syncing,4),_=>(Phase::Writing,2)};
        assert_eq!(error.phase,expected.0);assert_eq!(error.facts.requested,expected.1);
        assert_ne!(state.lock().unwrap().original.lock().unwrap().bytes,b"original\n");drop(session);task.await.unwrap();}
}
#[tokio::test(flavor="current_thread")]async fn recreated_name_is_not_opened_for_writing_or_overwritten(){
    let (session,state,task)=open(Fault::ReplaceAtWrite,b"original\n",None).await;let mut session=session.unwrap();let error=session.save(input(b"x\n",None,state.clone()),limits()).await.unwrap_err();
    assert_eq!(error.phase,Phase::LocationReadback);assert_eq!(state.lock().unwrap().current.lock().unwrap().bytes,b"foreign recreated destination\n");assert_eq!(state.lock().unwrap().original.lock().unwrap().bytes,b"x\n");drop(session);task.await.unwrap();
}
#[tokio::test(flavor="current_thread")]async fn observed_pre_save_conflict_causes_zero_remote_mutations(){
    let (session,state,task)=open(Fault::ExternalBeforeWrite,b"original\n",None).await;let mut session=session.unwrap();let error=session.save(input(b"x\n",None,state.clone()),limits()).await.unwrap_err();
    assert_eq!(error.cause,Failure::Conflict);assert_eq!(state.lock().unwrap().writes,0);drop(session);task.await.unwrap();
}
#[tokio::test(flavor="current_thread")]async fn explicit_readonly_denial_and_missing_sync_refuse_before_mutation(){
    for fault in [Fault::ReadOnly,Fault::NoSync]{let (session,state,task)=open(fault,b"original\n",None).await;assert!(session.is_err());task.await.unwrap();assert_eq!(state.lock().unwrap().writes,0);}
}
#[tokio::test(flavor="current_thread")]async fn idle_document_renews_operation_deadline_without_reopening_rw_handle(){
    let (session,state,task)=open(Fault::None,b"original\n",None).await;let mut session=session.unwrap();session.c.end=Instant::now()-Duration::from_millis(1);
    session.save(input(b"edited\n",None,state.clone()),limits()).await.unwrap();session.release(limits()).await.unwrap();task.await.unwrap();assert_eq!(state.lock().unwrap().opens.iter().filter(|&&v|v==3).count(),1);
}
#[tokio::test(flavor="current_thread")]async fn stop_joins_held_write_truncate_sync_and_readback_without_a_saved_receipt(){
    for opcode in [6,10,200,5]{let stop=Arc::new(AtomicBool::new(false));let (session,state,task)=open(Fault::Hold(opcode),b"original\n",Some(stop.clone())).await;let mut session=session.unwrap();
        let observed=state.lock().unwrap().hold.clone();let stopping=tokio::spawn(async move{tokio::time::timeout(Duration::from_secs(2),async{while !observed.load(Ordering::Acquire){tokio::task::yield_now().await}}).await.unwrap();stop.store(true,Ordering::Release);});
        let error=session.save(input(b"x\n",None,state.clone()),limits()).await.unwrap_err();assert_eq!(error.cause,Failure::Stopped);stopping.await.unwrap();drop(session);task.await.unwrap();assert!(state.lock().unwrap().handles.is_empty());}
}
#[test]fn m_n_require_combined_v3_independent_capabilities_and480_mib_and_old_modes_refuse_every_command(){
    use crate::ipc::{self,Mode,Decoder,Command};
    fn start(mode:Mode,quota:u64,version:u8,cap:u8,transfers:u8)->Vec<u8>{
        let mut v=if mode.jump(){let mut b=ipc::header_for(mode,[1;16],0,16);ipc::field(&mut b,b"generated.example").unwrap();b.extend(22u16.to_be_bytes());ipc::field(&mut b,b"jump.example").unwrap();ipc::field(&mut b,b"127.0.0.1").unwrap();b.extend(22u16.to_be_bytes());b.extend(0u32.to_be_bytes());b.extend([2;16]);ipc::field(&mut b,b"").unwrap();ipc::field(&mut b,b"").unwrap();b}
        else{let mut b=ipc::start([1;16],"generated.example","127.0.0.1",22,0,None).unwrap();b[..8].copy_from_slice(mode.magic());b};
        ipc::field(&mut v,b"/generated/catalog.sqlite").unwrap();v.extend(quota.to_be_bytes());v.extend([version,cap,1,transfers]);v
    }
    for mode in [Mode::InPlaceEditCatalog,Mode::RoutedInPlaceEditCatalog]{assert!(mode.inplace());assert!(!mode.original()&&!mode.transfers()&&!mode.uploads());
        for (quota,version,cap,good) in [(480<<20,3,7,true),(512<<20,3,7,false),(480<<20,2,7,false),(480<<20,1,7,false),(480<<20,3,3,false)]{
            assert_eq!(matches!(Decoder::new(mode).consume(&start(mode,quota,version,cap,0)),Ok(Command::Start(_))),good);}
        for mask in 0u8..=255{let start=start(mode,480<<20,3,7,mask);let mut d=Decoder::new(mode);
            let good=[0u8,1,3,7,15].contains(&mask);assert_eq!(d.consume(&start).is_ok(),good);
            if good{assert_eq!(d.transfer_capabilities(),mask);
                let mut request=ipc::header_for(mode,[1;16],1,8);request.extend([3;16]);request.extend([4;16]);request.extend(1u64.to_be_bytes());
                assert_eq!(d.consume(&request).is_ok(),mask&1!=0);
                let mut d=Decoder::new(mode);d.consume(&start).unwrap();let mut upload=ipc::header_for(mode,[1;16],1,9);upload.extend([3;16]);upload.extend([4;16]);upload.extend(1u64.to_be_bytes());ipc::field(&mut upload,b"new.txt").unwrap();upload.extend(1u64.to_be_bytes());
                assert_eq!(d.consume(&upload).is_ok(),mask&4!=0);
            }
        }
        let mut d=Decoder::new(mode);d.consume(&start(mode,480<<20,3,7,0)).unwrap();let mut begin=ipc::header_for(mode,[1;16],1,50);begin.extend([3;16]);begin.extend([4;16]);begin.extend(1u64.to_be_bytes());begin.extend(1u64.to_be_bytes());assert!(matches!(d.consume(&begin),Ok(Command::BeginInPlace{..})));
        for n in 0..begin.len(){let mut d=Decoder::new(mode);d.consume(&start(mode,480<<20,3,7,0)).unwrap();assert!(d.consume(&begin[..n]).is_err());}
    }
    for tag in [50,51,52,53,54,58]{let mut d=Decoder::new(Mode::Catalog);let mut s=ipc::start([1;16],"generated.example","127.0.0.1",22,0,None).unwrap();s[..8].copy_from_slice(Mode::Catalog.magic());ipc::field(&mut s,b"/generated/catalog.sqlite").unwrap();s.extend((480u64<<20).to_be_bytes());d.consume(&s).unwrap();assert!(d.consume(&ipc::header_for(Mode::Catalog,[1;16],1,tag)).is_err());}
}

#[tokio::test(flavor="current_thread")]async fn changed_privileged_or_portable_mode_after_write_is_never_saved(){
    for fault in [Fault::PrivilegedAfterWrite,Fault::ModeAfterWrite]{
        let (session,state,task)=open(fault,b"original\n",None).await;let mut session=session.unwrap();
        let error=session.save(input(b"a much longer edited body\n",None,state.clone()),limits()).await.unwrap_err();
        assert_eq!(error.phase,Phase::HandleReadback);assert_eq!(error.cause,Failure::Verification);
        assert_ne!(state.lock().unwrap().original.lock().unwrap().mode,0o100640);
        drop(session);task.await.unwrap();
    }
}

#[tokio::test(flavor="current_thread")]
async fn startup3_prebody_reasons_are_specific_and_header_free(){
    for(fault,expected)in[(Fault::NoSync,OpenFailure::Rejected(EditRejection::SyncUnavailable)),
        (Fault::ReadOnly,OpenFailure::Rejected(EditRejection::ReadWriteDenied)),
        (Fault::DeniedStat,OpenFailure::Fatal(Failure::Status(3))),
        (Fault::MalformedSyncThenDuplicate,OpenFailure::Fatal(Failure::Protocol))]{
        let state=Arc::new(Mutex::new(State::new(fault,b"unchanged\n")));
        let(a,b)=tokio::io::duplex(131072);let task=tokio::spawn(peer(b,state.clone()));
        struct NoHeader;impl ReadSink for NoHeader{
            async fn begin(&mut self,_:Observed)->Result<(),Failure>{panic!("prebody refusal emitted header")}
            async fn chunk(&mut self,_:u64,_:Vec<u8>)->Result<(),Failure>{panic!("prebody refusal emitted body")}
        }
        let dropped=Arc::new(AtomicBool::new(false));
        let stream=ObservedStream{inner:a,dropped:dropped.clone()};
        let result=Session::open_preflight(stream,"/generated/file.txt".into(),Metadata{size:Some(10),modified:Some(77),permissions:Some(0o100640)},NoHeader,limits(),None).await;
        let(actual,owned)=match result {
            Err(PreflightOpenFailure::Rejected{reason,stream})=>{
                let held=!dropped.load(Ordering::Acquire)&&!task.is_finished();
                drop(stream);(OpenFailure::Rejected(reason),held)
            },
            Err(PreflightOpenFailure::Fatal(cause))=>(OpenFailure::Fatal(cause),false),
            Ok(session)=>{drop(session);(OpenFailure::Fatal(Failure::Protocol),false)},
        };
        task.await.unwrap();
        if matches!(&expected,OpenFailure::Rejected(_)){assert!(owned,"prebody rejection dropped its actual stream inside kernel");}
        assert!(dropped.load(Ordering::Acquire));assert_eq!(actual,expected);
        let state=state.lock().unwrap();assert_eq!(state.writes,0);assert_eq!(state.original.lock().unwrap().bytes,b"unchanged\n");
        assert!(state.handles.is_empty());
        if fault==Fault::NoSync||fault==Fault::MalformedSyncThenDuplicate{assert!(state.opens.is_empty());}
        if fault==Fault::ReadOnly{assert_eq!(state.opens,vec![3]);}
    }
}

// Source-compatible with the frozen8AF kernel API: Root can append this exact
// function to its old test module to establish the separate P2 logical RED.
#[test]fn entire_version_list_validates_before_unsupported_sync_classification(){
    fn version_pairs(pairs:&[(&[u8],&[u8])])->Vec<u8>{
        let mut v=vec![2,0,0,0,3];for(name,value)in pairs{field(&mut v,name);field(&mut v,value);}v
    }
    for pairs in [
        vec![(b"fsync@openssh.com".as_slice(),b"2".as_slice()),(b"fsync@openssh.com".as_slice(),b"1".as_slice())],
        vec![(b"fsync@openssh.com".as_slice(),b"2".as_slice()),(b"fsync@openssh.com".as_slice(),b"2".as_slice())],
        vec![(b"fsync@openssh.com".as_slice(),b"2".as_slice()),(b"other".as_slice(),b"1".as_slice()),(b"other".as_slice(),b"2".as_slice())],
        vec![(b"fsync@openssh.com".as_slice(),b"1".as_slice()),(b"fsync@openssh.com".as_slice(),b"2".as_slice())],
    ]{assert_eq!(version(&version_pairs(&pairs)),Err(Failure::Protocol),"malformed complete VERSION became healthy unsupported rejection");}
    assert_eq!(version(&version_pairs(&[(b"fsync@openssh.com",b"2"),(b"other",b"1")])),Err(Failure::UnsupportedSync));
    assert_eq!(version(&version_pairs(&[(b"other",b"1")])),Err(Failure::UnsupportedSync));
    assert_eq!(version(&version_pairs(&[(b"fsync@openssh.com",b"1"),(b"other",b"2")])),Ok(()));
    let mut malformed=version_pairs(&[(b"fsync@openssh.com",b"2")]);malformed.extend(5u32.to_be_bytes());malformed.push(1);
    assert_eq!(version(&malformed),Err(Failure::Protocol));
}
