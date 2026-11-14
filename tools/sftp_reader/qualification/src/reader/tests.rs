use super::*;
use bytes::Bytes;
use russh_sftp::protocol::Packet;
use std::{io, pin::Pin, sync::{Arc,atomic::{AtomicUsize,Ordering}},task::{Context,Poll}};
use tokio::io::{DuplexStream,ReadBuf};

struct Tracked { inner: DuplexStream, live: Arc<AtomicUsize> }
impl Tracked { fn new(inner: DuplexStream,live: Arc<AtomicUsize>)->Self { live.fetch_add(1,Ordering::SeqCst);Self{inner,live} } }
impl Drop for Tracked { fn drop(&mut self){self.live.fetch_sub(1,Ordering::SeqCst);} }
impl AsyncRead for Tracked {
    fn poll_read(mut self:Pin<&mut Self>,cx:&mut Context<'_>,buf:&mut ReadBuf<'_>)->Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx,buf)
    }
}
impl AsyncWrite for Tracked {
    fn poll_write(mut self:Pin<&mut Self>,cx:&mut Context<'_>,buf:&[u8])->Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx,buf)
    }
    fn poll_flush(mut self:Pin<&mut Self>,cx:&mut Context<'_>)->Poll<io::Result<()>>{Pin::new(&mut self.inner).poll_flush(cx)}
    fn poll_shutdown(mut self:Pin<&mut Self>,cx:&mut Context<'_>)->Poll<io::Result<()>>{Pin::new(&mut self.inner).poll_shutdown(cx)}
}
fn word(b:&mut Vec<u8>,v:u32){b.extend(v.to_be_bytes());}
fn text(b:&mut Vec<u8>,s:&[u8]){word(b,s.len()as u32);b.extend(s);}
fn head(kind:u8,id:u32)->Vec<u8>{let mut b=vec![kind];word(&mut b,id);b}
fn status(id:u32,code:u32)->Vec<u8>{let mut b=head(101,id);word(&mut b,code);text(&mut b,b"");text(&mut b,b"");b}
fn handle(id:u32,value:&[u8])->Vec<u8>{let mut b=head(102,id);text(&mut b,value);b}
fn names(id:u32,extended:bool)->Vec<u8>{
    let mut b=head(104,id);word(&mut b,2);
    for name in [b"first".as_slice(),b"second"] {
        text(&mut b,name);text(&mut b,b"");word(&mut b,if extended{0x8000_000d}else{13});
        b.extend(123u64.to_be_bytes());word(&mut b,0o100644);word(&mut b,7);word(&mut b,19);
        if extended{word(&mut b,1);text(&mut b,b"generated.attribute");text(&mut b,b"ignored metadata");}
    }b
}
async fn request(s:&mut DuplexStream,kind:u8)->u32 {
    let length=s.read_u32().await.unwrap()as usize;assert!(length<=wire::MAX_PACKET);
    let mut b=vec![0;length];s.read_exact(&mut b).await.unwrap();
    let r=wire::outgoing(&b).unwrap();assert_eq!(r.kind,kind);r.id.unwrap_or(0)
}
async fn send(s:&mut DuplexStream,body:&[u8]){
    s.write_u32(body.len()as u32).await.unwrap();s.write_all(body).await.unwrap();
}
fn pair(deadline:Duration)->(Reader<Tracked>,DuplexStream,Arc<AtomicUsize>){
    let(a,b)=tokio::io::duplex(32768);let live=Arc::new(AtomicUsize::new(0));
    (Reader::new(Tracked::new(a,live.clone()),deadline),b,live)
}
async fn init(s:&mut DuplexStream){request(s,1).await;send(s,&[2,0,0,0,3]).await;}
fn canonical(id:u32,path:&[u8])->Vec<u8>{
    let mut b=head(104,id);word(&mut b,1);text(&mut b,path);text(&mut b,b"");word(&mut b,0);b
}

#[cfg(feature="remote-action-qualification")]
async fn action_request(s:&mut DuplexStream,kind:u8)->(u32,Vec<u8>){
    let length=s.read_u32().await.unwrap()as usize;let mut body=vec![0;length];
    s.read_exact(&mut body).await.unwrap();assert_eq!(body[0],kind);
    (u32::from_be_bytes(body[1..5].try_into().unwrap()),body)
}
#[cfg(feature="remote-action-qualification")]
#[tokio::test(flavor="current_thread")]
async fn action_requests_use_only_standard_v3_opcodes_and_one_request_each(){
    let (mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{
        init(&mut server).await;
        let(id,body)=action_request(&mut server,14).await;
        let mut expected=head(14,id);text(&mut expected,b"/generated/New Folder");word(&mut expected,0);
        assert_eq!(body,expected);send(&mut server,&status(id,0)).await;
        let(id,body)=action_request(&mut server,18).await;
        let mut expected=head(18,id);text(&mut expected,b"/generated/old.txt");text(&mut expected,b"/generated/occupied.txt");
        assert_eq!(body,expected);send(&mut server,&status(id,4)).await;
        let(id,body)=action_request(&mut server,13).await;
        let mut expected=head(13,id);text(&mut expected,b"/generated/old.txt");
        assert_eq!(body,expected);send(&mut server,&status(id,0)).await;
        let(id,body)=action_request(&mut server,15).await;
        let mut expected=head(15,id);text(&mut expected,b"/generated/Empty Folder");
        assert_eq!(body,expected);send(&mut server,&status(id,0)).await;
    });
    reader.initialize().await.unwrap();
    reader.enable_actions();
    reader.create_directory("/generated/New Folder").await.unwrap();
    assert_eq!(reader.rename_standard("/generated/old.txt","/generated/occupied.txt").await,Err(Failure::Status(4)));
    reader.remove_file("/generated/old.txt").await.unwrap();
    reader.remove_empty_directory("/generated/Empty Folder").await.unwrap();
    reader.stop();task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
}

#[tokio::test(flavor="current_thread")]
async fn refused_directory_reply_preserves_framing_for_explicit_recovery(){
    for code in [2,3,4]{for realpath in [true,false]{
        let(mut reader,mut server,live)=pair(Duration::from_secs(1));
        let task=tokio::spawn(async move{
            init(&mut server).await;
            let id=request(&mut server,16).await;
            if realpath{send(&mut server,&status(id,code)).await;}
            else{send(&mut server,&canonical(id,b"/denied")).await;let id=request(&mut server,11).await;send(&mut server,&status(id,code)).await;}
            let id=request(&mut server,16).await;send(&mut server,&canonical(id,b"/allowed")).await;
            let id=request(&mut server,11).await;send(&mut server,&handle(id,b"allowed")).await;
            let id=request(&mut server,12).await;send(&mut server,&status(id,1)).await;
            let id=request(&mut server,4).await;send(&mut server,&status(id,0)).await;
        });
        reader.initialize().await.unwrap();let error=reader.open_location("/denied").await.unwrap_err();
        assert_eq!(error,Failure::Status(code));assert_eq!(reader.directory_rejection(error),Some(code as u8));assert!(reader.is_open());
        assert_eq!(reader.open_location(".").await.unwrap(),"/allowed");assert!(reader.next_batch().await.unwrap().is_none());
        let drain=reader.close().await;assert!(drain.directory_close_acknowledged&&drain.stream_released&&drain.shutdown_completed);
        task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
    }}
}

#[tokio::test(flavor="current_thread")]
async fn malformed_status_and_failed_close_cannot_be_reclassified_as_recoverable(){
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{
        init(&mut server).await;let id=request(&mut server,16).await;send(&mut server,&status(id+1,3)).await;
    });
    reader.initialize().await.unwrap();let error=reader.open_location(".").await.unwrap_err();
    assert!(reader.directory_rejection(error).is_none());assert!(!reader.is_open());task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{
        init(&mut server).await;let id=request(&mut server,11).await;send(&mut server,&handle(id,b"held")).await;
        let id=request(&mut server,4).await;send(&mut server,&status(id,3)).await;
    });
    reader.initialize().await.unwrap();reader.open_directory("/previous").await.unwrap();let error=reader.close_directory().await.unwrap_err();
    assert_eq!(error,Failure::Status(3));assert!(reader.directory_rejection(error).is_none());reader.stop();
    task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
}

#[test]
fn common_metadata_matches_published_reference(){
    let body=names(7,false);let ours=wire::decode_names(&body,false).unwrap();
    let Packet::Name(other)=Packet::try_from(&mut Bytes::from(body)).unwrap()else{panic!("NAME expected")};
    assert_eq!(ours.len(),other.files.len());
    for(a,b)in ours.iter().zip(other.files){
        assert_eq!(a.name,b.filename);assert_eq!(a.metadata.size,b.attrs.size);
        assert_eq!(a.metadata.permissions,b.attrs.permissions);assert_eq!(a.metadata.modified,b.attrs.mtime);
        assert_eq!(a.metadata.size,Some(123));assert_eq!(a.metadata.modified,Some(19));
    }
}
#[test]
fn extended_metadata_preserves_all_following_names(){
    let ours=wire::decode_names(&names(7,true),false).unwrap();
    assert_eq!(ours.iter().map(|e|e.name.as_str()).collect::<Vec<_>>(),["first","second"]);
    assert!(ours.iter().all(|e|e.metadata.size==Some(123)&&e.metadata.modified==Some(19)));
}
#[test]
fn opaque_binary_handles_stay_byte_exact(){
    let opaque=[0,255,128,3];assert_eq!(wire::decode_handle(&handle(3,&opaque)).unwrap(),opaque);
    let request=wire::encode_request(12,4,&opaque).unwrap();assert_eq!(&request[9..],opaque);
}
#[test]
fn unsafe_child_names_never_become_paths(){
    for value in [b"../escape".as_slice(),b"a/b",b"a\0b",b"",b"\xff"] {
        let mut b=head(104,3);word(&mut b,1);text(&mut b,value);text(&mut b,b"");word(&mut b,0);
        assert!(wire::decode_names(&b,false).is_err());
    }
    let mut b=head(104,3);word(&mut b,2);
    for value in [b".".as_slice(),b".."]{text(&mut b,value);text(&mut b,b"");word(&mut b,0);}
    assert!(wire::decode_names(&b,false).unwrap().is_empty());
}
#[test]
fn folder_size_name_policy_is_byte_exact_before_entry_allocation(){
    let mut b=head(104,3);word(&mut b,1);
    let name="Café".as_bytes();text(&mut b,name);text(&mut b,b"");word(&mut b,0);
    assert_eq!(wire::decode_names_limited(&b,false,255).unwrap()[0].name.as_bytes(),name);
    let mut b=head(104,3);word(&mut b,1);
    text(&mut b,&vec![b'x';256]);text(&mut b,b"");word(&mut b,0);
    assert_eq!(wire::decode_names_limited(&b,false,255),Err(wire::Failure::NameLimit));
    assert_eq!(wire::decode_names(&b,false).unwrap()[0].name.len(),256);
}
#[tokio::test(flavor="current_thread")]
async fn folder_size_name_limit_keeps_owned_close_and_next_directory_healthy(){
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{
        init(&mut server).await;
        let id=request(&mut server,11).await;send(&mut server,&handle(id,b"wide")).await;
        let id=request(&mut server,12).await;let mut response=head(104,id);word(&mut response,1);
        text(&mut response,&vec![b'x';256]);text(&mut response,b"");word(&mut response,0);
        send(&mut server,&response).await;
        let id=request(&mut server,4).await;send(&mut server,&status(id,0)).await;
        let id=request(&mut server,11).await;send(&mut server,&handle(id,b"healthy")).await;
        let id=request(&mut server,12).await;send(&mut server,&status(id,1)).await;
        let id=request(&mut server,4).await;send(&mut server,&status(id,0)).await;
    });
    reader.initialize().await.unwrap();reader.open_directory("/wide").await.unwrap();
    assert_eq!(reader.next_folder_size_batch().await,Err(Failure::NameLimit));
    assert!(reader.is_open());reader.close_directory().await.unwrap();
    reader.open_directory("/healthy").await.unwrap();
    assert!(reader.next_folder_size_batch().await.unwrap().is_none());
    let drain=reader.close().await;
    assert!(drain.directory_close_acknowledged&&drain.stream_released&&drain.shutdown_completed);
    task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
}
#[test]
fn request_encoding_cannot_enable_content_or_writes(){
    for kind in [3,5,6,9,10,13,14,15,18,19,20,200]{assert_eq!(wire::encode_request(kind,1,b"."),Err(wire::Failure::Kind));}
    assert_eq!(wire::encode_request(11,1,&vec![b'x';8193]),Err(wire::Failure::Length));
}

#[tokio::test(flavor="current_thread")]
async fn metadata_session_roundtrip_and_acknowledged_close(){
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let baseline=tokio::runtime::Handle::current().metrics().num_alive_tasks();
    let task=tokio::spawn(async move{
        init(&mut server).await;
        let id=request(&mut server,16).await;let mut canonical=head(104,id);word(&mut canonical,1);
        text(&mut canonical,b"/generated");text(&mut canonical,b"");word(&mut canonical,0);send(&mut server,&canonical).await;
        let id=request(&mut server,11).await;send(&mut server,&handle(id,&[0,255,3])).await;
        let id=request(&mut server,12).await;send(&mut server,&names(id,true)).await;
        let id=request(&mut server,12).await;send(&mut server,&status(id,1)).await;
        let id=request(&mut server,4).await;send(&mut server,&status(id,0)).await;
    });
    reader.initialize().await.unwrap();assert_eq!(reader.real_path(".").await.unwrap(),"/generated");
    reader.open_directory("/generated").await.unwrap();
    assert_eq!(reader.open_directory("/other").await,Err(Failure::Busy));
    let values=reader.next_batch().await.unwrap().unwrap();assert_eq!(values[1].name,"second");
    assert!(reader.next_batch().await.unwrap().is_none());
    let drain=reader.close().await;assert!(drain.directory_close_acknowledged&&drain.stream_released&&drain.shutdown_completed);
    task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
    assert_eq!(tokio::runtime::Handle::current().metrics().num_alive_tasks(),baseline);
}

#[tokio::test(flavor="current_thread")]
async fn fragmented_version_is_fully_consumed(){
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{
        request(&mut server,1).await;
        for value in [0u8,0,0,5,2,0,0,0,3]{server.write_all(&[value]).await.unwrap();tokio::task::yield_now().await;}
    });
    reader.initialize().await.unwrap();reader.stop();task.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
}

#[tokio::test(flavor="current_thread")]
async fn oversized_prefix_refuses_without_waiting_for_body(){
    for length in [0,u32::MAX,wire::MAX_PACKET as u32+1]{
        let(mut reader,mut server,live)=pair(Duration::from_secs(1));
        let task=tokio::spawn(async move{request(&mut server,1).await;server.write_u32(length).await.unwrap();std::future::pending::<()>().await;});
        let result=tokio::time::timeout(Duration::from_millis(200),reader.initialize()).await.unwrap();
        assert_eq!(result,Err(Failure::Protocol(wire::Failure::Length)));assert!(!reader.is_open());assert_eq!(live.load(Ordering::SeqCst),0);
        task.abort();assert!(task.await.unwrap_err().is_cancelled());
    }
}

#[tokio::test(flavor="current_thread")]
async fn hostile_count_and_wrong_identity_close_the_stream(){
    for wrong_id in [false,true]{
        let(mut reader,mut server,live)=pair(Duration::from_secs(1));
        let task=tokio::spawn(async move{
            init(&mut server).await;let id=request(&mut server,11).await;send(&mut server,&handle(id,b"h")).await;
            let id=request(&mut server,12).await;
            let body=if wrong_id{names(id+1,false)}else{let mut b=head(104,id);word(&mut b,u32::MAX);b};
            send(&mut server,&body).await;
        });
        reader.initialize().await.unwrap();reader.open_directory(".").await.unwrap();
        assert_eq!(reader.next_batch().await,Err(Failure::Protocol(if wrong_id{wire::Failure::Correlation}else{wire::Failure::Count})));
        assert!(!reader.is_open());assert_eq!(live.load(Ordering::SeqCst),0);task.await.unwrap();
    }
}

#[tokio::test(flavor="current_thread")]
async fn partial_prefix_and_body_are_never_reused(){
    for bytes in [vec![0u8,0],vec![0,0,0,5,2,0]]{
        let(mut reader,mut server,live)=pair(Duration::from_secs(1));
        let task=tokio::spawn(async move{request(&mut server,1).await;server.write_all(&bytes).await.unwrap();});
        assert_eq!(reader.initialize().await,Err(Failure::Truncated));
        assert_eq!(reader.initialize().await,Err(Failure::Closed));assert_eq!(live.load(Ordering::SeqCst),0);task.await.unwrap();
    }
}

#[tokio::test(flavor="current_thread")]
async fn timeout_drops_transport_and_leaves_no_reader_task(){
    let(mut reader,mut server,live)=pair(Duration::from_millis(25));
    let task=tokio::spawn(async move{request(&mut server,1).await;std::future::pending::<()>().await;});
    assert_eq!(reader.initialize().await,Err(Failure::Timeout));assert!(!reader.is_open());assert_eq!(live.load(Ordering::SeqCst),0);
    task.abort();assert!(task.await.unwrap_err().is_cancelled());
}

#[tokio::test(flavor="current_thread")]
async fn cancelling_the_call_drops_its_taken_stream(){
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{request(&mut server,1).await;std::future::pending::<()>().await;});
    assert!(tokio::time::timeout(Duration::from_millis(25),reader.initialize()).await.is_err());
    assert!(!reader.is_open());assert_eq!(live.load(Ordering::SeqCst),0);
    assert_eq!(reader.initialize().await,Err(Failure::Closed));
    task.abort();assert!(task.await.unwrap_err().is_cancelled());
}

#[tokio::test(flavor="current_thread")]
async fn lost_close_reply_cannot_claim_remote_acknowledgement(){
    let(mut reader,mut server,live)=pair(Duration::from_millis(25));
    let task=tokio::spawn(async move{
        init(&mut server).await;let id=request(&mut server,11).await;send(&mut server,&handle(id,b"h")).await;
        request(&mut server,4).await;std::future::pending::<()>().await;
    });
    reader.initialize().await.unwrap();reader.open_directory(".").await.unwrap();
    let drain=reader.close().await;assert!(!drain.directory_close_acknowledged&&drain.stream_released&&!drain.shutdown_completed);
    assert_eq!(live.load(Ordering::SeqCst),0);task.abort();assert!(task.await.unwrap_err().is_cancelled());
}

#[tokio::test(flavor="current_thread")]
async fn status_errors_are_numeric_and_create_no_fake_rows(){
    let(mut reader,mut server,live)=pair(Duration::from_secs(1));
    let task=tokio::spawn(async move{init(&mut server).await;let id=request(&mut server,7).await;send(&mut server,&status(id,3)).await;});
    reader.initialize().await.unwrap();assert_eq!(reader.metadata("/generated/denied").await,Err(Failure::Status(3)));
    assert!(reader.is_open());reader.stop();assert_eq!(live.load(Ordering::SeqCst),0);task.await.unwrap();
}
