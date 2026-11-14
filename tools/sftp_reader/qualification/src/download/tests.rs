use super::*;
use std::{io,pin::Pin,sync::{Arc,Mutex,atomic::{AtomicUsize,Ordering}},task::{Context,Poll}};
use tokio::io::{DuplexStream,ReadBuf};

struct Tracked{stream:DuplexStream,live:Arc<AtomicUsize>,fail_shutdown:bool}
impl Drop for Tracked{fn drop(&mut self){self.live.fetch_sub(1,Ordering::SeqCst);}}
impl AsyncRead for Tracked{
    fn poll_read(mut self:Pin<&mut Self>,cx:&mut Context<'_>,b:&mut ReadBuf<'_>)->Poll<io::Result<()>>{Pin::new(&mut self.stream).poll_read(cx,b)}
}
impl AsyncWrite for Tracked{
    fn poll_write(mut self:Pin<&mut Self>,cx:&mut Context<'_>,b:&[u8])->Poll<io::Result<usize>>{Pin::new(&mut self.stream).poll_write(cx,b)}
    fn poll_flush(mut self:Pin<&mut Self>,cx:&mut Context<'_>)->Poll<io::Result<()>>{Pin::new(&mut self.stream).poll_flush(cx)}
    fn poll_shutdown(mut self:Pin<&mut Self>,cx:&mut Context<'_>)->Poll<io::Result<()>>{
        if self.fail_shutdown{Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))}else{Pin::new(&mut self.stream).poll_shutdown(cx)}
    }
}
fn pair()->(Tracked,DuplexStream,Arc<AtomicUsize>){
    let(a,b)=tokio::io::duplex(4096);let live=Arc::new(AtomicUsize::new(1));(Tracked{stream:a,live:live.clone(),fail_shutdown:false},b,live)
}
fn observed(size:u64)->Metadata{Metadata{size:Some(size),permissions:Some(0o100644),modified:Some(19)}}
fn limits()->Limits{Limits{request_deadline:Duration::from_millis(80),total_deadline:Duration::from_secs(2),..Limits::default()}}
fn word(b:&mut Vec<u8>,n:u32){b.extend(n.to_be_bytes());}
fn head(kind:u8,id:u32)->Vec<u8>{let mut b=vec![kind];word(&mut b,id);b}
fn status(id:u32,code:u32)->Vec<u8>{let mut b=head(101,id);word(&mut b,code);field(&mut b,b"");field(&mut b,b"");b}
fn attrs(id:u32,metadata:Metadata)->Vec<u8>{
    let mut b=head(105,id);word(&mut b,13);b.extend(metadata.size.unwrap().to_be_bytes());
    word(&mut b,metadata.permissions.unwrap());word(&mut b,3);word(&mut b,metadata.modified.unwrap());b
}
fn number(b:&[u8])->u32{u32::from_be_bytes(b[..4].try_into().unwrap())}
fn string(b:&[u8])->(&[u8],&[u8]){let count=number(b)as usize;(&b[4..4+count],&b[4+count..])}
struct ProgressSink{checkpoints:Arc<AtomicUsize>,bytes:usize}
impl Sink for ProgressSink{
    async fn consume(&mut self,offset:u64,bytes:Vec<u8>)->std::result::Result<(),()>{assert_eq!(offset,self.bytes as u64);self.bytes+=bytes.len();Ok(())}
    async fn checkpoint(&mut self)->std::result::Result<(),()>{self.checkpoints.fetch_add(1,Ordering::SeqCst);Ok(())}
}
#[tokio::test(flavor="current_thread")]
async fn every_non_body_request_offers_progress_between_slow_network_round_trips(){
    let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7],b"/generated".to_vec(),Scenario::Good));
    let count=Arc::new(AtomicUsize::new(0));let sink=ProgressSink{checkpoints:count.clone(),bytes:0};
    let receipt=receive(stream,"/generated",observed(1),limits(),sink).await.unwrap();
    assert_eq!(receipt.bytes,1);assert!(count.load(Ordering::SeqCst)>=8,"Metadata/EOF/CLOSE can otherwise accumulate beyond the parent's event wait");
    peer.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
}
async fn send(s:&mut DuplexStream,b:&[u8])->bool{
    if s.write_u32(b.len()as u32).await.is_err(){return false}s.write_all(b).await.is_ok()
}
async fn request(s:&mut DuplexStream)->Option<Vec<u8>>{
    let len=s.read_u32().await.ok()?as usize;assert!(len>0&&len<=8192+32);let mut b=vec![0;len];s.read_exact(&mut b).await.ok()?;Some(b)
}
#[derive(Clone,Copy)]enum Scenario{Good,BeforeChanged,HandleChanged,AfterChanged,PathChanged,EarlyEnd,Grew,Short,Empty,TooMuch,WrongID,Trailing,Denied,LostClose,WrongEnd,Partial,LargePrefix}
#[derive(Default,Debug)]struct Counts{opens:usize,reads:usize,closes:usize,received:usize}
async fn fixture(mut server:DuplexStream,data:Vec<u8>,path:Vec<u8>,scenario:Scenario)->Counts{
    let mut counts=Counts::default();let mut lstat=0;let mut fstat=0;let handle=[0,255,128,3];
    while let Some(request)=request(&mut server).await{
        if request[0]==1{assert_eq!(request,[1,0,0,0,3]);if !send(&mut server,&[2,0,0,0,3]).await{break}continue}
        assert!(request.len()>=5);let kind=request[0];let id=number(&request[1..]);let(payload,rest)=string(&request[5..]);
        let reply=match kind{
            7|8=>{
                assert!(rest.is_empty());if kind==7{assert_eq!(payload,path);lstat+=1}else{assert_eq!(payload,handle);fstat+=1}
                let mut found=observed(data.len()as u64);
                if matches!(scenario,Scenario::BeforeChanged)&&kind==7&&lstat==1
                    ||matches!(scenario,Scenario::HandleChanged)&&kind==8&&fstat==1
                    ||matches!(scenario,Scenario::AfterChanged)&&kind==8&&fstat==2
                    ||matches!(scenario,Scenario::PathChanged)&&kind==7&&lstat==2{found.modified=Some(20)}
                attrs(id,found)
            },
            3=>{
                counts.opens+=1;assert_eq!(payload,path);assert_eq!(rest,[0,0,0,1,0,0,0,0]);
                if matches!(scenario,Scenario::Denied){status(id,3)}else{let mut b=head(102,id);field(&mut b,&handle);b}
            },
            5=>{
                counts.reads+=1;assert_eq!(payload,handle);assert_eq!(rest.len(),12);
                let offset=u64::from_be_bytes(rest[..8].try_into().unwrap())as usize;let wanted=number(&rest[8..])as usize;
                assert_eq!(offset,counts.received);assert!((1..=MAX_CHUNK).contains(&wanted));
                if matches!(scenario,Scenario::LargePrefix){server.write_u32(u32::MAX).await.unwrap();continue}
                if matches!(scenario,Scenario::Partial){server.write_all(&[0,0,0,30,103]).await.unwrap();continue}
                if matches!(scenario,Scenario::EarlyEnd){status(id,1)}
                else if offset==data.len(){
                    if matches!(scenario,Scenario::Grew){let mut b=head(103,id);field(&mut b,b"x");b}
                    else{status(id,if matches!(scenario,Scenario::WrongEnd){0}else{1})}
                }else{
                    let amount=if matches!(scenario,Scenario::Short){wanted.min(17)}else{wanted};
                    let end=(offset+amount).min(data.len());let mut b=head(103,if matches!(scenario,Scenario::WrongID){id+1}else{id});
                    let bytes=if matches!(scenario,Scenario::TooMuch){vec![0;wanted+1]}
                        else if matches!(scenario,Scenario::Empty){vec![]}else{data[offset..end].to_vec()};
                    counts.received+=bytes.len();field(&mut b,&bytes);if matches!(scenario,Scenario::Trailing){b.push(0)}b
                }
            },
            4=>{counts.closes+=1;assert_eq!(payload,handle);assert!(rest.is_empty());if matches!(scenario,Scenario::LostClose){continue}status(id,0)},
            _=>panic!("Unexpected operation {kind}; no mutations admitted"),
        };
        if !send(&mut server,&reply).await{break}
    }
    counts
}

#[tokio::test(flavor="current_thread")]
async fn exact_short_reads_empty_file_and_unicode_path_end_with_close_and_stream_drain(){
    for(size,scenario)in[(0,Scenario::Good),(70_001,Scenario::Good),(173,Scenario::Short)]{
        let(stream,server,live)=pair();let data:Vec<u8>=(0..size).map(|n|(n%251)as u8).collect();let expected=data.clone();
        let path="/generated/Cafe\u{301} report_α.bin";
        let peer=tokio::spawn(fixture(server,data,path.as_bytes().to_vec(),scenario));
        let output=Arc::new(Mutex::new(Vec::new()));let target=output.clone();
        let receipt=receive(stream,path,observed(size as u64),limits(),move|offset:u64,bytes:Vec<u8>|{
            assert!(bytes.len()<=MAX_CHUNK);let mut out=target.lock().unwrap();assert_eq!(out.len()as u64,offset);out.extend(bytes);std::future::ready(Ok(()))
        }).await.unwrap();
        assert_eq!(*output.lock().unwrap(),expected);assert_eq!(receipt.bytes,size as u64);assert!(receipt.close_acknowledged&&receipt.stream_shutdown);
        let counts=peer.await.unwrap();assert_eq!(counts.opens,1);assert_eq!(counts.closes,1);assert_eq!(counts.received,size);assert_eq!(live.load(Ordering::SeqCst),0);
    }
}
#[tokio::test(flavor="current_thread")]
async fn every_observable_change_or_early_end_refuses_completion(){
    for scenario in [Scenario::BeforeChanged,Scenario::HandleChanged,Scenario::AfterChanged,Scenario::PathChanged,Scenario::EarlyEnd,Scenario::Grew]{
        let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),scenario));
        assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::ready(Ok(()))).await,Err(Failure::Changed));
        let counts=peer.await.unwrap();assert_eq!(counts.closes,0);assert_eq!(live.load(Ordering::SeqCst),0);
        if matches!(scenario,Scenario::BeforeChanged|Scenario::HandleChanged){assert_eq!(counts.reads,0)}
    }
}
#[tokio::test(flavor="current_thread")]
async fn malformed_data_ids_lengths_and_eof_cannot_be_success(){
    for scenario in [Scenario::Empty,Scenario::TooMuch,Scenario::WrongID,Scenario::Trailing,Scenario::WrongEnd,Scenario::LargePrefix]{
        let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),scenario));
        assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::ready(Ok(()))).await,Err(Failure::Protocol));
        peer.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
    }
}
#[tokio::test(flavor="current_thread")]
async fn permission_failure_is_distinct_and_no_body_was_read(){
    let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),Scenario::Denied));
    assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::ready(Ok(()))).await,Err(Failure::Status(3)));
    assert_eq!(peer.await.unwrap().reads,0);assert_eq!(live.load(Ordering::SeqCst),0);
}
#[tokio::test(flavor="current_thread")]
async fn lost_close_and_partial_frame_expire_and_release_the_transport(){
    for scenario in [Scenario::LostClose,Scenario::Partial]{
        let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),scenario));
        assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::ready(Ok(()))).await,Err(Failure::Timeout));
        peer.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
    }
}
#[tokio::test(flavor="current_thread")]
async fn sink_failure_or_blocked_sink_never_reaches_close_or_public_success(){
    let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),Scenario::Good));
    assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::ready(Err(()))).await,Err(Failure::Sink));
    assert_eq!(peer.await.unwrap().closes,0);assert_eq!(live.load(Ordering::SeqCst),0);
    let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),Scenario::Good));
    assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::pending()).await,Err(Failure::Timeout));
    assert_eq!(peer.await.unwrap().closes,0);assert_eq!(live.load(Ordering::SeqCst),0);
}
#[tokio::test(flavor="current_thread")]
async fn cancelled_call_and_total_deadline_drop_the_owned_stream_without_detached_reader_tasks(){
    for total in [false,true]{
        let(stream,mut server,live)=pair();let baseline=tokio::runtime::Handle::current().metrics().num_alive_tasks();
        let peer=tokio::spawn(async move{request(&mut server).await.unwrap();let mut b=[0];assert_eq!(server.read(&mut b).await.unwrap(),0);});
        let mut bounds=limits();bounds.request_deadline=Duration::from_secs(1);bounds.total_deadline=Duration::from_millis(25);
        let result=tokio::time::timeout(if total{Duration::from_secs(1)}else{Duration::from_millis(10)},
            receive(stream,"/generated",observed(200),bounds,|_,_|std::future::ready(Ok(())))).await;
        if total{assert_eq!(result.unwrap(),Err(Failure::Timeout))}else{assert!(result.is_err())}
        peer.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);assert_eq!(tokio::runtime::Handle::current().metrics().num_alive_tasks(),baseline);
    }
}
#[tokio::test(flavor="current_thread")]
async fn unsafe_unknown_or_over_limit_selection_sends_no_packet(){
    let mut cases=vec![];
    for path in ["relative","/","/a//b","/a/../b","/a/./b","/a\0b"]{cases.push((path.to_owned(),observed(1),limits()))}
    cases.push(("/a".into(),observed(MAX_OBJECT+1),limits()));
    for metadata in [Metadata{size:None,..observed(1)},Metadata{modified:None,..observed(1)},Metadata{permissions:None,..observed(1)},
        Metadata{permissions:Some(0o120777),..observed(1)},Metadata{permissions:Some(0o040755),..observed(1)}]{cases.push(("/a".into(),metadata,limits()))}
    cases.push(("/a".into(),observed(1),Limits{request_deadline:Duration::ZERO,..limits()}));
    cases.push(("/a".into(),observed(1),Limits{maximum_bytes:0,..limits()}));
    cases.push(("/a".into(),observed(1),Limits{total_deadline:Duration::from_secs(1801),..limits()}));
    for(path,metadata,bounds)in cases{
        let(stream,mut peer,live)=pair();assert_eq!(receive(stream,&path,metadata,bounds,|_,_|std::future::ready(Ok(()))).await,Err(Failure::Input));
        let mut b=[0];assert_eq!(peer.read(&mut b).await.unwrap(),0);assert_eq!(live.load(Ordering::SeqCst),0);
    }
}
#[tokio::test(flavor="current_thread")]
async fn stream_shutdown_failure_is_not_a_completed_transfer(){
    let(mut stream,server,live)=pair();stream.fail_shutdown=true;
    let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),Scenario::Good));
    assert_eq!(receive(stream,"/generated",observed(200),limits(),|_,_|std::future::ready(Ok(()))).await,Err(Failure::Io));
    assert_eq!(peer.await.unwrap().closes,1);assert_eq!(live.load(Ordering::SeqCst),0);
}
#[tokio::test(flavor="current_thread")]
async fn explicit_stop_interrupts_network_wait_or_prevents_the_first_packet(){
    for initially_stopped in[false,true]{
        let(stream,mut server,live)=pair();let stop=Arc::new(AtomicBool::new(initially_stopped));let signal=stop.clone();
        let peer=tokio::spawn(async move{
            if !initially_stopped{request(&mut server).await.unwrap();signal.store(true,Ordering::Release)}
            let mut byte=[0];assert_eq!(server.read(&mut byte).await.unwrap(),0);
        });
        assert_eq!(receive_controlled(stream,"/generated",observed(200),limits(),Some(stop),|_,_|std::future::ready(Ok(()))).await,Err(Failure::Stopped));
        peer.await.unwrap();assert_eq!(live.load(Ordering::SeqCst),0);
    }
}
#[tokio::test(flavor="current_thread")]
async fn explicit_stop_drains_the_current_sink_frame_before_dropping_the_reader(){
    let(stream,server,live)=pair();let peer=tokio::spawn(fixture(server,vec![7;200],b"/generated".to_vec(),Scenario::Good));
    let stop=Arc::new(AtomicBool::new(false));let signal=stop.clone();let completed=Arc::new(AtomicBool::new(false));let ended=completed.clone();
    let result=receive_controlled(stream,"/generated",observed(200),limits(),Some(stop),move|_,_|{
        let signal=signal.clone();let ended=ended.clone();async move{
            signal.store(true,Ordering::Release);tokio::time::sleep(Duration::from_millis(25)).await;ended.store(true,Ordering::Release);Ok(())
        }
    }).await;
    assert_eq!(result,Err(Failure::Stopped));assert!(completed.load(Ordering::Acquire));assert_eq!(peer.await.unwrap().closes,0);assert_eq!(live.load(Ordering::SeqCst),0);
}
