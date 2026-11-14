//! Copied-worker integration controls. Mock SMB frames + private Unix IPC only.
//! These are not authentication, encryption, TCP or ordinary activation evidence.
use super::{catalog::{Row,SelectedRow,State},channel::{Output,Stop},download_network::{self,End,Event},download_wire::{Command,Selection},wire};
use smb2::{client::{Connection,selected_download::SelectedDownloadPolicy},transport::MockTransport,types::{SessionId,TreeId}};
use std::{sync::Arc,time::Duration};
use tokio::{io::{AsyncReadExt,AsyncWriteExt},net::UnixStream,sync::oneshot};
const A:&str="77777777-7777-4777-8777-777777777777";
const B:&str="88888888-8888-4888-8888-888888888888";
fn selection()->Selection{Selection{token:A.into(),ordinal:1,number:1,generation:B.into(),revision:3,observation:1}}
fn selected(size:usize)->SelectedRow{SelectedRow{directory:"Folder".encode_utf16().collect(),item:Row{observation:1,wire:"Generated.txt".encode_utf16().collect(),attributes:32,size:size as u64,modified:300}}}
fn header(command:u16,body:Vec<u8>)->Vec<u8>{
    let mut raw=vec![0;64];raw[..4].copy_from_slice(b"\xfeSMB");raw[4]=64;raw[12..14].copy_from_slice(&command.to_le_bytes());
    raw[14]=32;raw[16]=1;raw[36]=7;raw[40..48].copy_from_slice(&0x1234u64.to_le_bytes());raw.extend(body);raw
}
fn negotiation()->Vec<u8>{
    let mut bytes=header(0,vec![0;64]);bytes[36..48].fill(0);bytes[64]=65;bytes[66]=3;bytes[68..70].copy_from_slice(&0x0311u16.to_le_bytes());bytes[70]=2;
    for offset in [92,96,100]{bytes[offset..offset+4].copy_from_slice(&65536u32.to_le_bytes());}bytes[124]=128;
    bytes.extend([1,0,6,0,0,0,0,0,1,0,0,0,1,0,0,0]);bytes.extend([2,0,4,0,0,0,0,0,1,0,2,0]);bytes
}
fn create(size:u64)->Vec<u8>{
    let mut body=vec![0;88];body[0]=89;body[4]=1;
    for(at,value)in [(8,100u64),(24,300),(32,400),(40,size.next_multiple_of(4096)),(48,size),(64,5),(72,6)]{body[at..at+8].copy_from_slice(&value.to_le_bytes());}
    body[56]=32;header(5,body)
}
fn metadata(size:u64)->Vec<Vec<u8>>{
    let mut basic=vec![0;40];for(at,value)in [(0,100u64),(8,200),(16,300),(24,400)]{basic[at..at+8].copy_from_slice(&value.to_le_bytes());}basic[32]=32;
    let mut standard=vec![0;24];standard[..8].copy_from_slice(&size.next_multiple_of(4096).to_le_bytes());standard[8..16].copy_from_slice(&size.to_le_bytes());standard[16]=1;
    let mut volume=vec![0;18];volume[..8].copy_from_slice(&500u64.to_le_bytes());volume[8]=13;volume[16]=1;
    [basic,standard,42u64.to_le_bytes().to_vec(),volume].into_iter().map(|bytes|{
        let mut body=vec![0;8];body[0]=9;body[2]=72;body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend(bytes);header(16,body)
    }).collect()
}
fn data(bytes:&[u8])->Vec<u8>{let mut body=vec![0;16];body[0]=17;body[2]=80;body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend(bytes);header(8,body)}
fn eof()->Vec<u8>{let mut body=vec![0;9];body[0]=9;let mut bytes=header(8,body);bytes[8..12].copy_from_slice(&0xc0000011u32.to_le_bytes());bytes}
fn close()->Vec<u8>{let mut body=vec![0;60];body[0]=60;header(6,body)}
async fn connection()->(Connection,Arc<MockTransport>){
    let mock=Arc::new(MockTransport::new());mock.enable_auto_rewrite_msg_id();mock.queue_response(negotiation());
    let mut conn=Connection::from_transport(Box::new(mock.clone()),Box::new(mock.clone()),"generated.invalid");
    conn.set_selected_download_policy(SelectedDownloadPolicy::new()).unwrap();conn.set_reviver(None);conn.set_keepalive(None);
    conn.set_response_timeout(Some(Duration::from_secs(1)));conn.b10_negotiate(false).await.unwrap();conn.set_session_id(SessionId(0x1234));(conn,mock)
}
fn queue(mock:&MockTransport,bytes:&[u8],release:bool){
    let mut replies=vec![create(bytes.len()as u64)];replies.extend(metadata(bytes.len()as u64));
    if !release{for part in bytes.chunks(32768){replies.push(data(part));}replies.push(eof());replies.extend(metadata(bytes.len()as u64));}
    replies.push(close());mock.queue_responses(replies);
}
fn read_count(mock:&MockTransport)->usize{mock.sent_messages().iter().filter(|m|m[12]==8).count()}
async fn drain(conn:Connection,mock:Arc<MockTransport>){conn.mark_dead();mock.close();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);assert!(conn.outstanding_requests().is_empty());}
async fn next(rx:&mut tokio::sync::mpsc::Receiver<Event>)->Event{tokio::time::timeout(Duration::from_secs(2),rx.recv()).await.unwrap().unwrap()}
#[test]fn b12_download_old_mode_refuses_new_commands_and_cross_magic(){
    let command=format!("PREPARE_DOWNLOAD {A} 1 1 {B} 3 1");assert!(wire::command_mode(&command,false).is_err());assert!(wire::command_mode(&command,true).is_ok());
    let hello=format!("MEXSMBB2 START {A} signed 127.0.0.1 445 0 67656e6572617465642e696e76616c6964 005300680061007200650064 2f612f636174616c6f672e73716c697465 1048576");
    assert!(wire::hello_mode(&hello,false).is_ok());assert!(wire::hello_mode(&hello,true).is_err());
    let new=hello.replacen("MEXSMBB2","MEXSMBD1",1);assert!(wire::hello_mode(&new,true).is_ok());assert!(wire::hello_mode(&new,false).is_err());
    for mode in [false,true]{assert!(wire::command_mode(&format!("READ 1 {B} -"),mode).is_ok());assert!(wire::command_mode("DELETE anything",mode).is_err());}
}
#[tokio::test(flavor="current_thread")]async fn b12_download_output_preserves_old_lines_and_new_frames(){
    for mode in [false,true]{
        let(left,mut peer)=UnixStream::pair().unwrap();let(_,write)=left.into_split();let mut out=Output::qualification(write,A.into(),mode);
        out.event("connected signed").await.unwrap();
        if mode{let n=peer.read_u32().await.unwrap();let mut raw=vec![0;n as usize];peer.read_exact(&mut raw).await.unwrap();assert_eq!(raw,format!("MEXSMBD1 {A} 0 connected signed").as_bytes());
            out.download_event(Event::Bytes{selection:selection(),sequence:0,offset:0,bytes:vec![0,255,10,13]}).await.unwrap();
            let n=peer.read_u32().await.unwrap();assert_eq!(n,101);let mut raw=vec![0;n as usize];peer.read_exact(&mut raw).await.unwrap();assert_eq!(&raw[..9],b"\0MEXSMBD1");assert_eq!(&raw[45..53],&1u64.to_be_bytes());assert_eq!(&raw[97..],&[0,255,10,13]);
        }else{let mut raw=vec![0;format!("MEXSMBB2 {A} 0 connected signed\n").len()];peer.read_exact(&mut raw).await.unwrap();assert_eq!(raw,format!("MEXSMBB2 {A} 0 connected signed\n").as_bytes());assert!(out.download_event(Event::Bytes{selection:selection(),sequence:0,offset:0,bytes:vec![1]}).await.is_err());}
    }
}
#[tokio::test(flavor="current_thread")]async fn b12_download_output_failure_cannot_be_followed_by_trusted_terminal(){
    let(left,peer)=UnixStream::pair().unwrap();drop(peer);let(_,write)=left.into_split();let mut out=Output::qualification(write,A.into(),true);
    assert!(out.event("connected signed").await.is_err());assert!(out.event("closed stopped 1 0").await.is_err());
}
#[tokio::test(flavor="current_thread")]async fn b12_download_begin_and_each_ack_precede_real_reads(){
    let(conn,mock)=connection().await;let source=(0..32769).map(|n|(n%251)as u8).collect::<Vec<_>>();queue(&mock,&source,false);
    let mut job=download_network::start(selection(),selected(source.len()),conn.clone(),TreeId(7),Stop::new());
    assert!(matches!(next(&mut job.events).await,Event::Prepared{..}));assert_eq!(read_count(&mock),0);
    job.commands.send(Command::Begin{token:A.into(),ordinal:1}).await.unwrap();
    let mut got=vec![];
    for expected in 0..2{match next(&mut job.events).await{Event::Bytes{selection:actual,sequence,offset,bytes}=>{
        assert_eq!(actual,selection());assert_eq!(sequence,expected);assert_eq!(offset,got.len()as u64);got.extend(bytes);
        for _ in 0..4{tokio::task::yield_now().await;}assert_eq!(read_count(&mock),expected as usize+1);
        job.commands.send(Command::Ack{token:A.into(),ordinal:1,sequence,offset:got.len()as u64}).await.unwrap();
    },_=>panic!("Expected exact body frame")}}
    assert_eq!(got,source);assert!(matches!(job.task.await.unwrap().unwrap(),End::Complete{bytes:32769,..}));assert_eq!(read_count(&mock),3);
    drain(conn,mock).await;
}
#[tokio::test(flavor="current_thread")]async fn b12_download_prepared_release_closes_without_body(){
    let(conn,mock)=connection().await;queue(&mock,&[1,2,3],true);let mut job=download_network::start(selection(),selected(3),conn.clone(),TreeId(7),Stop::new());
    assert!(matches!(next(&mut job.events).await,Event::Prepared{..}));job.commands.send(Command::Release{token:A.into(),ordinal:1}).await.unwrap();
    assert!(matches!(job.task.await.unwrap().unwrap(),End::Released(_)));assert_eq!(read_count(&mock),0);assert_eq!(mock.sent_messages().iter().filter(|m|m[12]==6).count(),1);drain(conn,mock).await;
}
#[tokio::test(flavor="current_thread")]async fn b12_download_empty_file_still_checks_eof_and_close(){
    let(conn,mock)=connection().await;queue(&mock,&[],false);let mut job=download_network::start(selection(),selected(0),conn.clone(),TreeId(7),Stop::new());
    assert!(matches!(next(&mut job.events).await,Event::Prepared{..}));job.commands.send(Command::Begin{token:A.into(),ordinal:1}).await.unwrap();
    assert!(matches!(job.task.await.unwrap().unwrap(),End::Complete{bytes:0,..}));assert_eq!(read_count(&mock),1);assert!(job.events.recv().await.is_none());drain(conn,mock).await;
}
#[tokio::test(flavor="current_thread")]async fn b12_download_wrong_ack_never_reads_the_next_chunk(){
    let(conn,mock)=connection().await;queue(&mock,&vec![7;32769],false);let mut job=download_network::start(selection(),selected(32769),conn.clone(),TreeId(7),Stop::new());
    next(&mut job.events).await;job.commands.send(Command::Begin{token:A.into(),ordinal:1}).await.unwrap();next(&mut job.events).await;
    job.commands.send(Command::Ack{token:A.into(),ordinal:1,sequence:0,offset:32767}).await.unwrap();assert!(matches!(job.task.await.unwrap(),Err(wire::Issue::Invalid)));assert_eq!(read_count(&mock),1);drain(conn,mock).await;
}
#[tokio::test(flavor="current_thread")]async fn b12_download_stop_while_prepared_and_while_ack_pending_joins(){
    for begun in [false,true]{let(conn,mock)=connection().await;queue(&mock,&vec![7;32769],false);let stop=Stop::new();let mut job=download_network::start(selection(),selected(32769),conn.clone(),TreeId(7),stop.clone());
        next(&mut job.events).await;if begun{job.commands.send(Command::Begin{token:A.into(),ordinal:1}).await.unwrap();next(&mut job.events).await;}
        stop.set();assert!(matches!(tokio::time::timeout(Duration::from_secs(1),job.task).await.unwrap().unwrap(),Err(wire::Issue::Stop)));assert_eq!(read_count(&mock),usize::from(begun));drain(conn,mock).await;
    }
}
#[tokio::test(flavor="current_thread")]async fn b12_download_closed_event_consumer_never_completes(){
    let(conn,mock)=connection().await;queue(&mock,&[1],false);let job=download_network::start(selection(),selected(1),conn.clone(),TreeId(7),Stop::new());drop(job.events);
    assert!(matches!(job.task.await.unwrap(),Err(wire::Issue::IPC)));assert_eq!(read_count(&mock),0);drain(conn,mock).await;
}
#[tokio::test(flavor="current_thread")]async fn b12_download_missing_ack_hits_real_deadline_without_read_ahead(){
    let(conn,mock)=connection().await;queue(&mock,&vec![7;32769],false);let mut job=download_network::start(selection(),selected(32769),conn.clone(),TreeId(7),Stop::new());
    next(&mut job.events).await;job.commands.send(Command::Begin{token:A.into(),ordinal:1}).await.unwrap();next(&mut job.events).await;
    assert!(matches!(tokio::time::timeout(Duration::from_secs(7),job.task).await.unwrap().unwrap(),Err(wire::Issue::Deadline)));assert_eq!(read_count(&mock),1);drain(conn,mock).await;
}
fn fixture()->(String,[std::fs::File;3]){
    use std::{fs::{File,OpenOptions},os::unix::fs::{DirBuilderExt,OpenOptionsExt},os::fd::AsRawFd,path::PathBuf};
    let root=PathBuf::from(std::env::var_os("MEX_SMB_DOWNLOAD_FIXTURES").unwrap()).canonicalize().unwrap();
    let case=root.parent().unwrap().parent().unwrap();assert_eq!(root.file_name().unwrap(),"fixtures");
    assert!(std::fs::read_to_string(case.join("reservation.json")).unwrap().contains("smb-selected-download-integration-controls"));
    let path=root.join("actual-catalog");std::fs::DirBuilder::new().mode(0o700).create(&path).unwrap();let dir=File::open(&path).unwrap();
    let db=OpenOptions::new().read(true).write(true).create_new(true).mode(0o600).open(path.join("catalog.sqlite")).unwrap();
    let lease=OpenOptions::new().read(true).write(true).create_new(true).mode(0o600).open(path.join("owner.lock")).unwrap();
    unsafe extern "C"{fn flock(fd:i32,operation:i32)->i32;}assert_eq!(unsafe{flock(lease.as_raw_fd(),2|4)},0);
    (path.join("catalog.sqlite").to_str().unwrap().into(),[dir,db,lease])
}
async fn ack(owner:&mut super::store::Owner,command:super::store::Command,reply:oneshot::Receiver<Result<(),wire::Issue>>)->Option<super::catalog::Snapshot>{
    owner.commands.send(command).await.unwrap();reply.await.unwrap().unwrap();let mut snapshot=None;
    while let Ok(event)=owner.events.try_recv(){if let super::store::Event::Snapshot{value,..}=event{snapshot=Some(value);}}snapshot
}
#[tokio::test(flavor="current_thread")]async fn b12_download_catalog_owner_resolves_only_current_complete_observation(){
    use super::store::{Command as C,Metadata};let(path,files)=fixture();let stop=Stop::new();let mut owner=super::store::Owner::start(path,files,2<<20,stop.flag.clone());
    assert!(matches!(owner.events.recv().await,Some(super::store::Event::Ready)));
    let(tx,rx)=oneshot::channel();ack(&mut owner,C::Start{number:1,generation:B.into(),path:"Folder".encode_utf16().collect(),reply:tx},rx).await;
    let(tx,rx)=oneshot::channel();ack(&mut owner,C::Batch{number:1,rows:vec![Metadata{wire:"Generated.txt".encode_utf16().collect(),attributes:32,size:3,modified:300,object:0}],reply:tx},rx).await;
    assert!(download_network::resolve(&selection(),&owner,&stop).await.is_err());
    let(tx,rx)=oneshot::channel();let snapshot=ack(&mut owner,C::Finish{number:1,state:State::Complete,reply:tx},rx).await.unwrap();
    let mut value=selection();value.revision=snapshot.revision;
    assert_eq!(download_network::resolve(&value,&owner,&stop).await.unwrap(),selected(3));
    for kind in 0..4{let mut bad=value.clone();match kind{0=>bad.number+=1,1=>bad.revision+=1,2=>bad.observation+=1,_=>bad.generation=A.into()};assert!(download_network::resolve(&bad,&owner,&stop).await.is_err());}
    stop.set();assert!(owner.drain().await);
}
