//! Generated, in-memory protocol peer. It is not a server/credential fixture.
//! Every tested request is emitted by the actual Channel/kernel above.
use super::*;
use std::{collections::HashMap,sync::Mutex};
use tokio::io::{AsyncReadExt,AsyncWriteExt,DuplexStream};
#[derive(Clone)]struct Node{bytes:Vec<u8>,mode:u32,uid:u32,gid:u32,modified:u32}
#[derive(Clone,Copy,PartialEq,Eq)]enum Fault{None,LostPreserve,CompetingPublish,ReplacePreserve,OpenFdAfterCheck,HostileNamespace,LostPublish,NoHardlink,WrongUid}
struct Namespace{names:HashMap<String,Arc<Mutex<Node>>>,handles:HashMap<Vec<u8>,Arc<Mutex<Node>>>,next:u32,
    fault:Fault,mutations:Vec<u8>,final_original_reads:u32}
fn field_bytes(bytes:&mut Vec<u8>,v:&[u8]){field(bytes,v)}
fn read_field<'a>(b:&'a[u8],p:&mut usize)->&'a[u8]{let n=u32::from_be_bytes(b[*p..*p+4].try_into().unwrap())as usize;*p+=4;let out=&b[*p..*p+n];*p+=n;out}
fn text(b:&[u8],p:&mut usize)->String{String::from_utf8(read_field(b,p).to_vec()).unwrap()}
fn status(id:&[u8],code:u32)->Vec<u8>{let mut b=vec![101];b.extend(id);b.extend(code.to_be_bytes());field(&mut b,b"");field(&mut b,b"");b}
fn attrs_reply(id:&[u8],n:&Node)->Vec<u8>{let mut b=vec![105];b.extend(id);b.extend(15u32.to_be_bytes());b.extend((n.bytes.len()as u64).to_be_bytes());b.extend(n.uid.to_be_bytes());b.extend(n.gid.to_be_bytes());b.extend(n.mode.to_be_bytes());b.extend(n.modified.to_be_bytes());b.extend(n.modified.to_be_bytes());b}
impl Namespace{
    fn new(fault:Fault)->Self{let old=Node{bytes:b"original\n".to_vec(),mode:0o100640,uid:501,gid:20,modified:77};
        Self{names:HashMap::from([("/generated/file.txt".into(),Arc::new(Mutex::new(old)))]),handles:HashMap::new(),next:1,fault,mutations:Vec::new(),final_original_reads:0}}
    fn content(&self,path:&str)->Vec<u8>{self.names.get(path).unwrap().lock().unwrap().bytes.clone()}
    fn response(&mut self,b:&[u8])->Option<Vec<u8>>{
        if b[0]==1{let mut v=vec![2,0,0,0,3];for name in [b"posix-rename@openssh.com".as_slice(),b"hardlink@openssh.com",b"fsync@openssh.com"]{
            if self.fault==Fault::NoHardlink&&name==b"hardlink@openssh.com"{continue}field(&mut v,name);field(&mut v,b"1")};return Some(v)}
        let id=&b[1..5];let mut p=5;
        Some(match b[0]{
            7=>{let path=text(b,&mut p);match self.names.get(&path){None=>status(id,2),Some(n)=>attrs_reply(id,&n.lock().unwrap())}},
            8=>{let handle=read_field(b,&mut p);attrs_reply(id,&self.handles.get(handle).unwrap().lock().unwrap())},
            3=>{let path=text(b,&mut p);let flags=u32::from_be_bytes(b[p..p+4].try_into().unwrap());p+=4;
                if flags&0x20!=0&&self.names.contains_key(&path){return Some(status(id,4))}
                if flags&0x08!=0{self.mutations.push(2);let mode=u32::from_be_bytes(b[p+4..p+8].try_into().unwrap());
                    self.names.insert(path.clone(),Arc::new(Mutex::new(Node{bytes:Vec::new(),mode:0o100000|mode,uid:if self.fault==Fault::WrongUid{502}else{501},gid:20,modified:78})));}
                let Some(n)=self.names.get(&path)else{return Some(status(id,2))};let handle=self.next.to_be_bytes().to_vec();self.next+=1;self.handles.insert(handle.clone(),n.clone());
                if path=="/generated/file.txt"{self.final_original_reads+=1}
                let mut v=vec![102];v.extend(id);field(&mut v,&handle);v},
            4=>{let handle=read_field(b,&mut p);self.handles.remove(handle);status(id,0)},
            5=>{let handle=read_field(b,&mut p);let offset=u64::from_be_bytes(b[p..p+8].try_into().unwrap())as usize;p+=8;
                let count=u32::from_be_bytes(b[p..p+4].try_into().unwrap())as usize;let n=self.handles.get(handle).unwrap().lock().unwrap();
                if offset>=n.bytes.len(){status(id,1)}else{let mut v=vec![103];v.extend(id);field(&mut v,&n.bytes[offset..n.bytes.len().min(offset+count)]);v}},
            6=>{let handle=read_field(b,&mut p);let offset=u64::from_be_bytes(b[p..p+8].try_into().unwrap())as usize;p+=8;let bytes=read_field(b,&mut p);
                let mut n=self.handles.get(handle).unwrap().lock().unwrap();assert_eq!(offset,n.bytes.len());n.bytes.extend(bytes);status(id,0)},
            10=>{let handle=read_field(b,&mut p);let mode=u32::from_be_bytes(b[p+4..p+8].try_into().unwrap());self.handles.get(handle).unwrap().lock().unwrap().mode=0o100000|mode;status(id,0)},
            14=>{self.mutations.push(1);let path=text(b,&mut p);if self.names.contains_key(&path){return Some(status(id,4))}
                self.names.insert(path,Arc::new(Mutex::new(Node{bytes:Vec::new(),mode:0o040700,uid:501,gid:20,modified:78})));status(id,0)},
            200=>{let extension=read_field(b,&mut p);
                if extension==b"fsync@openssh.com"{status(id,0)}else{
                    let from=text(b,&mut p);let to=text(b,&mut p);
                    if extension==b"posix-rename@openssh.com"{
                        self.mutations.push(4);
                        if self.fault==Fault::ReplacePreserve{self.names.insert(from.clone(),Arc::new(Mutex::new(Node{bytes:b"other writer\n".to_vec(),mode:0o100640,uid:501,gid:20,modified:77})));}
                        let node=self.names.remove(&from).unwrap();self.names.insert(to,node);
                        if self.fault==Fault::LostPreserve{return None}
                        if self.fault==Fault::HostileNamespace{let directory=self.names.keys().find(|p|p.ends_with("/previous")).unwrap().rsplit_once('/').unwrap().0.to_owned();self.names.retain(|name,_|!name.starts_with(&directory));}
                        if self.fault==Fault::CompetingPublish{self.names.insert(from,Arc::new(Mutex::new(Node{bytes:b"competing name\n".to_vec(),mode:0o100640,uid:501,gid:20,modified:79})));}
                        status(id,0)
                    }else{assert_eq!(extension,b"hardlink@openssh.com");self.mutations.push(if to.ends_with("link-check"){3}else{5});
                        if self.names.contains_key(&to){status(id,4)}else{let node=self.names.get(&from).unwrap().clone();let publication=to=="/generated/file.txt";self.names.insert(to,node);if publication&&self.fault==Fault::LostPublish{return None}status(id,0)}}
                }},
            _=>panic!("unexpected kernel opcode"),
        })
    }
}
async fn peer(mut stream:DuplexStream,state:Arc<Mutex<Namespace>>){loop{let mut prefix=[0;4];if stream.read_exact(&mut prefix).await.is_err(){break}
    let mut bytes=vec![0;u32::from_be_bytes(prefix)as usize];if stream.read_exact(&mut bytes).await.is_err(){break}
    let reply={state.lock().unwrap().response(&bytes)};let Some(reply)=reply else{break};
    if stream.write_all(&(reply.len()as u32).to_be_bytes()).await.is_err()||stream.write_all(&reply).await.is_err(){break}
}
    let mut state=state.lock().unwrap();state.handles.clear();
    // Exact counterexample: an already-open writer can modify the preserved
    // inode after the last observation. This remains UNSUPPORTED, not CAS.
    if state.fault==Fault::OpenFdAfterCheck{for(path,node)in &state.names{if path.ends_with("/previous"){node.lock().unwrap().bytes=b"late open-fd writer\n".to_vec()}}}
}
#[derive(Clone)]struct Input{bytes:Vec<u8>,events:Arc<Mutex<Vec<(u8,Facts)>>>,deny:Option<Edge>}
impl Source for Input{
    fn size(&self)->u64{self.bytes.len()as u64}
    async fn next(&mut self,offset:u64,count:usize)->std::result::Result<Vec<u8>,Failure>{Ok(self.bytes[offset as usize..offset as usize+count].to_vec())}
    async fn permit_publication(&mut self,digest:[u8;32])->std::result::Result<(),Failure>{assert_eq!(digest,self.expected_digest());Ok(())}
}
impl Control for Input{
    fn expected_digest(&self)->[u8;32]{Sha256::digest(&self.bytes).into()}
    async fn permit_edge(&mut self,e:Edge,f:Facts,_:[u8;32])->std::result::Result<(),Failure>{self.events.lock().unwrap().push((e as u8,f));if self.deny==Some(e){Err(Failure::Io)}else{Ok(())}}
    async fn edge_observed(&mut self,e:Edge,f:Facts)->std::result::Result<(),Failure>{self.events.lock().unwrap().push((0x80|e as u8,f));Ok(())}
}
async fn scenario(fault:Fault,deny:Option<Edge>)->(std::result::Result<Receipt,Interrupted>,Arc<Mutex<Namespace>>,Target){
    let state=Arc::new(Mutex::new(Namespace::new(fault)));let baseline=Baseline::new([1;16],1,"/generated/file.txt".into(),Observed{size:9,modified:77,mode:0o100640,uid:501,gid:20},Sha256::digest(b"original\n").into()).unwrap();
    let target=Target::new(&baseline,[2;16]).unwrap();let(a,b)=tokio::io::duplex(131072);let task=tokio::spawn(peer(b,state.clone()));
    let source=Input{bytes:b"edited\n".to_vec(),events:Arc::new(Mutex::new(Vec::new())),deny};
    let result=send(a,&baseline,&target,source,Limits{request_deadline:Duration::from_secs(1),total_deadline:Duration::from_secs(5)},None).await;
    task.await.unwrap();assert!(state.lock().unwrap().handles.is_empty());(result,state,target)
}
#[tokio::test(flavor="current_thread")]async fn preserves_actual_previous_and_exclusive_aliases(){
    let(result,state,target)=scenario(Fault::None,None).await;let receipt=result.unwrap();assert_eq!(receipt.facts,Facts{requested:31,acknowledged:31});
    let state=state.lock().unwrap();assert_eq!(state.content(&target.previous),b"original\n");assert_eq!(state.content(&target.original),b"edited\n");
    assert!(Arc::ptr_eq(&state.names[&target.original],&state.names[&target.candidate]));assert!(Arc::ptr_eq(&state.names[&target.probe],&state.names[&target.candidate]));
    assert_eq!(state.mutations,[1,2,3,4,5]);assert!(receipt.stream_shutdown&&receipt.previous_entry_retained&&receipt.aliases_retained);
}
#[tokio::test(flavor="current_thread")]async fn each_local_barrier_precedes_its_wire_mutation(){
    for edge in [Edge::Container,Edge::Stage,Edge::LinkCheck,Edge::Preserve,Edge::Publish]{let(result,state,_)=scenario(Fault::None,Some(edge)).await;
        assert_eq!(result.unwrap_err().cause,Cause::LocalBarrier);assert!(!state.lock().unwrap().mutations.contains(&(edge as u8)));}
}
#[tokio::test(flavor="current_thread")]async fn lost_preserve_ack_keeps_requested_unknown_and_actual_entry(){
    let(result,state,target)=scenario(Fault::LostPreserve,None).await;let e=result.unwrap_err();assert_eq!(e.facts,Facts{requested:15,acknowledged:7});
    let state=state.lock().unwrap();assert!(!state.names.contains_key(&target.original));assert_eq!(state.content(&target.previous),b"original\n");assert!(!state.mutations.contains(&5));
}
#[tokio::test(flavor="current_thread")]async fn competing_original_name_is_never_overwritten(){
    let(result,state,target)=scenario(Fault::CompetingPublish,None).await;assert!(result.is_err());let state=state.lock().unwrap();
    assert_eq!(state.content(&target.original),b"competing name\n");assert_eq!(state.content(&target.previous),b"original\n");assert_eq!(state.content(&target.candidate),b"edited\n");
}
#[tokio::test(flavor="current_thread")]async fn replacement_preserves_actual_moved_entry_and_stops_conflict(){
    let(result,state,target)=scenario(Fault::ReplacePreserve,None).await;assert_eq!(result.unwrap_err().cause,Cause::Conflict);let state=state.lock().unwrap();
    assert_eq!(state.content(&target.previous),b"other writer\n");assert!(!state.names.contains_key(&target.original));assert!(!state.mutations.contains(&5));
}
#[tokio::test(flavor="current_thread")]async fn explicit_extensions_and_uid_are_required(){
    let(result,state,_)=scenario(Fault::NoHardlink,None).await;assert_eq!(result.unwrap_err().facts,Facts::default());assert!(state.lock().unwrap().mutations.is_empty());
    let(result,state,_)=scenario(Fault::WrongUid,None).await;assert_eq!(result.unwrap_err().cause,Cause::UnsupportedMetadata);assert!(!state.lock().unwrap().mutations.contains(&4));
}
#[tokio::test(flavor="current_thread")]async fn unsupported_open_fd_writer_is_a_counterexample_not_a_guarantee(){
    let(result,state,target)=scenario(Fault::OpenFdAfterCheck,None).await;assert!(result.is_ok());assert_ne!(state.lock().unwrap().content(&target.previous),b"original\n");
    println!("{{\"capability\":\"arbitrary-writer-preservation\",\"passed\":false,\"expectedUnsupportedObserved\":true}}");
}
#[test]fn edit_attrs_and_target_are_strict(){
    assert!(Baseline::new([0;16],1,"/generated/file.txt".into(),Observed{size:9,modified:77,mode:0o100640,uid:501,gid:20},[0;32]).is_err());
    let mut b=attrs_reply(&1u32.to_be_bytes(),&Node{bytes:vec![],mode:0o100600,uid:501,gid:20,modified:77});assert!(Observed::parse(&b).is_ok());b.push(0);assert!(Observed::parse(&b).is_err());
}
#[test]fn k_l_are_explicit_and_do_not_widen_old_fresh_upload_modes(){
    use crate::ipc::{self,Mode,Decoder,Command};
    fn start(mode:Mode)->Vec<u8>{
        let mut value=if mode.jump(){
            let mut b=ipc::header_for(mode,[1;16],0,16);ipc::field(&mut b,b"generated.invalid").unwrap();b.extend(22u16.to_be_bytes());
            ipc::field(&mut b,b"jump.invalid").unwrap();ipc::field(&mut b,b"127.0.0.1").unwrap();b.extend(22u16.to_be_bytes());b.extend(0u32.to_be_bytes());b.extend([2;16]);
            ipc::field(&mut b,b"").unwrap();ipc::field(&mut b,b"").unwrap();b
        }else{let mut b=ipc::start([1;16],"generated.invalid","127.0.0.1",22,0,None).unwrap();b[..8].copy_from_slice(mode.magic());b};
        ipc::field(&mut value,b"/generated/catalog.sqlite").unwrap();value.extend((8u64<<20).to_be_bytes());
        if mode.original(){value.push(0x33)}value
    }
    for mode in [Mode::OriginalEditCatalog,Mode::RoutedOriginalEditCatalog]{
        assert!(mode.original());assert!(!mode.uploads());assert!(!mode.folder_uploads());assert!(!mode.folders());assert!(!mode.transfers());
        let good=start(mode);let mut d=Decoder::new(mode);assert!(matches!(d.consume(&good),Ok(Command::Start(_))));
        let mut command=ipc::header_for(mode,[1;16],1,40);command.extend([3;16]);command.extend([4;16]);command.extend(1u64.to_be_bytes());command.extend(1u64.to_be_bytes());
        assert!(matches!(d.consume(&command),Ok(Command::BeginEdit{..})));
        let mut release=ipc::header_for(mode,[1;16],2,48);release.extend([5;16]);release.extend([6;16]);release.extend(1u64.to_be_bytes());
        assert!(matches!(d.consume(&release),Ok(Command::ReleaseBaselineV1{..})));
        for kind in [47u8,48]{let mut bad=ipc::header_for(mode,[1;16],1,kind);bad.extend([5;16]);
            if kind==48{bad.extend([6;16]);bad.extend(0u64.to_be_bytes())}
            let mut decoder=Decoder::new(mode);decoder.consume(&good).unwrap();assert!(decoder.consume(&bad).is_err());}
        for length in 0..release.len(){let mut decoder=Decoder::new(mode);decoder.consume(&good).unwrap();
            let mut frame=release[..length].to_vec();if frame.len()>=32{frame[24..32].copy_from_slice(&1u64.to_be_bytes())}assert!(decoder.consume(&frame).is_err());}
        for cap in [0,1,3,4,7,15,16,19,31,255]{let mut bad=good.clone();*bad.last_mut().unwrap()=cap;assert!(Decoder::new(mode).consume(&bad).is_err())}
    }
    for mode in [Mode::ExclusiveUploadCatalog,Mode::FreshFolderUploadCatalog,Mode::RoutedExclusiveUploadCatalog,Mode::RoutedFreshFolderUploadCatalog]{
        let mut d=Decoder::new(mode);d.consume(&start(mode)).unwrap();let mut command=ipc::header_for(mode,[1;16],1,40);
        command.extend([3;16]);command.extend([4;16]);command.extend(1u64.to_be_bytes());command.extend(1u64.to_be_bytes());assert!(d.consume(&command).is_err());assert!(!mode.original());
        let mut decoder=Decoder::new(mode);decoder.consume(&start(mode)).unwrap();let mut release=ipc::header_for(mode,[1;16],1,48);
        release.extend([5;16]);release.extend([6;16]);release.extend(1u64.to_be_bytes());assert!(decoder.consume(&release).is_err());
    }
}

#[tokio::test(flavor="current_thread")]async fn lost_publication_ack_remains_unknown_despite_visible_bytes(){
    let(result,state,target)=scenario(Fault::LostPublish,None).await;let error=result.unwrap_err();assert_eq!(error.facts,Facts{requested:31,acknowledged:15});
    let state=state.lock().unwrap();assert_eq!(state.content(&target.original),b"edited\n");assert_eq!(state.content(&target.previous),b"original\n");
}
#[tokio::test(flavor="current_thread")]async fn unsupported_hostile_namespace_cannot_be_called_preservation(){
    let(result,state,target)=scenario(Fault::HostileNamespace,None).await;assert!(result.is_err());assert!(!state.lock().unwrap().names.contains_key(&target.previous));
    println!("{{\"capability\":\"hostile-owned-namespace\",\"passed\":false,\"expectedUnsupportedObserved\":true}}");
}

struct Received(Arc<Mutex<Vec<u8>>>);
impl ReadSink for Received{
    async fn begin(&mut self,observed:Observed)->std::result::Result<(),Failure>{assert_eq!(observed.size,9);assert_eq!(observed.uid,501);Ok(())}
    async fn chunk(&mut self,offset:u64,bytes:Vec<u8>)->std::result::Result<(),Failure>{let mut stored=self.0.lock().unwrap();assert_eq!(offset,stored.len()as u64);stored.extend(bytes);Ok(())}
}
#[tokio::test(flavor="current_thread")]async fn explicit_baseline_reads_actual_channel_and_closes_without_mutations(){
    let state=Arc::new(Mutex::new(Namespace::new(Fault::None)));let(a,b)=tokio::io::duplex(131072);let task=tokio::spawn(peer(b,state.clone()));
    let bytes=Arc::new(Mutex::new(Vec::new()));let(expected,digest)=read(a,"/generated/file.txt",crate::wire::Metadata{size:Some(9),modified:Some(77),permissions:Some(0o100640)},
        Received(bytes.clone()),Limits{request_deadline:Duration::from_secs(1),total_deadline:Duration::from_secs(5)},None).await.unwrap();
    task.await.unwrap();assert_eq!(expected.size,9);assert_eq!(digest,<[u8;32]>::from(Sha256::digest(b"original\n")));assert_eq!(*bytes.lock().unwrap(),b"original\n");
    let state=state.lock().unwrap();assert!(state.mutations.is_empty());assert!(state.handles.is_empty());
}
