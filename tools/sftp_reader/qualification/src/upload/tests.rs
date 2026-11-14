use super::*;
use tokio::io::DuplexStream;
use std::{io,pin::Pin,task::{Context,Poll}};
#[derive(Default)]struct Observed{temporary:Option<Vec<u8>>,final_file:Option<Vec<u8>>,operations:Vec<u8>,shutdown_seen:bool}
fn word(bytes:&mut Vec<u8>,value:u32){bytes.extend(value.to_be_bytes())}
fn head(kind:u8,id:u32)->Vec<u8>{let mut out=vec![kind];word(&mut out,id);out}
fn status(id:u32,code:u32)->Vec<u8>{let mut out=head(101,id);word(&mut out,code);field(&mut out,b"");field(&mut out,b"");out}
fn attrs(id:u32,bytes:usize,mode:u32)->Vec<u8>{let mut out=head(105,id);word(&mut out,5);out.extend((bytes as u64).to_be_bytes());word(&mut out,mode);out}
fn u32_at(bytes:&[u8],at:&mut usize)->u32{let value=u32::from_be_bytes(bytes[*at..*at+4].try_into().unwrap());*at+=4;value}
fn u64_at(bytes:&[u8],at:&mut usize)->u64{let value=u64::from_be_bytes(bytes[*at..*at+8].try_into().unwrap());*at+=8;value}
fn target()->Target{Target::new("/generated","Draft-Notes.bin",[7;16]).unwrap()}
async fn peer(mut stream:DuplexStream,scenario:&'static str,stop:Arc<AtomicBool>,exclusive:bool)->Observed{
    let target=target();let mut value=Observed::default();let mut mode=0o100600;let mut final_stats=0;let mut reading_final=false;
    if scenario=="occupied"{value.final_file=Some(b"Keep existing".to_vec())}
    if scenario=="temp-conflict"{value.temporary=Some(b"Keep temporary collision".to_vec())}
    loop{
        let length=match stream.read_u32().await{Ok(v)=>v as usize,Err(_)=>{value.shutdown_seen=true;return value}};
        assert!((1..=MAX_CHUNK+17000).contains(&length));let mut bytes=vec![0;length];stream.read_exact(&mut bytes).await.unwrap();
        let kind=bytes[0];value.operations.push(kind);assert!(![13,14,15,20].contains(&kind));
        let id=if kind==1{0}else{u32::from_be_bytes(bytes[1..5].try_into().unwrap())};let mut at=5;
        let response=match kind{
            1=>{assert_eq!(bytes,[1,0,0,0,3]);let mut response=vec![2,0,0,0,3];
                if scenario!="no-sync"{field(&mut response,b"fsync@openssh.com");field(&mut response,b"1");}
                if scenario=="duplicate-sync"{field(&mut response,b"fsync@openssh.com");field(&mut response,b"1");}response},
            7=>{let name=string(&bytes,&mut at,8192).unwrap();assert_eq!(at,bytes.len());
                if name==target.final_path.as_bytes(){final_stats+=1;if scenario=="name-race"&&final_stats==2{value.final_file=Some(b"Keep raced target".to_vec())}
                    value.final_file.as_ref().map_or_else(||status(id,2),|v|attrs(id,v.len(),0o100644))}
                else{assert_eq!(name,target.temporary_path.as_bytes());attrs(id,value.temporary.as_ref().unwrap().len(),mode)}},
            3=>{let name=string(&bytes,&mut at,8192).unwrap();let flags=u32_at(&bytes,&mut at);let attr=u32_at(&bytes,&mut at);
                if name==target.temporary_path.as_bytes(){assert_eq!(flags,0x2b);assert_eq!(attr,4);assert_eq!(u32_at(&bytes,&mut at),0o600);assert_eq!(at,bytes.len());
                    if value.temporary.is_some(){status(id,4)}else{value.temporary=Some(Vec::new());if scenario=="lost-create"{return value}let mut out=head(102,id);field(&mut out,b"opaque\0\xff");out}}
                else if exclusive&&flags==0x2b{
                    assert_eq!(name,target.final_path.as_bytes());assert_eq!(attr,4);assert_eq!(u32_at(&bytes,&mut at),0o600);assert_eq!(at,bytes.len());
                    if scenario=="denied-open"{status(id,3)}
                    else if scenario=="denied-open-wrong-id"{status(id+1,3)}
                    else if scenario=="denied-open-trailing"{let mut out=status(id,3);out.push(0);out}
                    else if scenario=="ambiguous-open"{status(id,4)}
                    else{
                    if scenario=="open-race"{value.final_file=Some(b"Keep raced target".to_vec())}
                    if value.final_file.is_some(){status(id,4)}else{value.final_file=Some(Vec::new());if scenario=="lost-create"{return value}let mut out=head(102,id);field(&mut out,b"opaque\0\xff");out}
                    }
                }else{assert_eq!(name,target.final_path.as_bytes());assert_eq!((flags,attr),(1,0));assert_eq!(at,bytes.len());reading_final=true;let mut out=head(102,id);field(&mut out,b"final\0");out}},
            6=>{assert_eq!(string(&bytes,&mut at,256).unwrap(),b"opaque\0\xff");let offset=u64_at(&bytes,&mut at)as usize;let data=string(&bytes,&mut at,MAX_CHUNK).unwrap();assert_eq!(at,bytes.len());
                if scenario=="stop-write"{stop.store(true,Ordering::Release);let mut end=[0];let _=stream.read(&mut end).await;value.shutdown_seen=true;return value}
                if scenario=="oversize-frame"{stream.write_u32((wire::MAX_PACKET+1)as u32).await.unwrap();let mut end=[0];let _=stream.read(&mut end).await;value.shutdown_seen=true;return value}
                if scenario=="denied-write"{status(id,3)}else{
                    let file=if exclusive{value.final_file.as_mut().unwrap()}else{value.temporary.as_mut().unwrap()};assert_eq!(offset,file.len());file.extend(data);
                    let mut out=status(if scenario=="wrong-write-id"{id+1}else{id},0);if scenario=="trailing-status"{out.push(0)}out}},
            8=>{let handle=string(&bytes,&mut at,256).unwrap();assert_eq!(at,bytes.len());
                if handle==b"opaque\0\xff"{attrs(id,if exclusive{value.final_file.as_ref().unwrap().len()}else{value.temporary.as_ref().unwrap().len()},mode)}else{assert_eq!(handle,b"final\0");attrs(id,value.final_file.as_ref().unwrap().len(),0o100644)}},
            5=>{let handle=string(&bytes,&mut at,256).unwrap();assert_eq!(handle,if reading_final{b"final\0".as_slice()}else{b"opaque\0\xff".as_slice()});
                let offset=u64_at(&bytes,&mut at)as usize;let count=u32_at(&bytes,&mut at)as usize;assert_eq!(at,bytes.len());assert!((1..=MAX_CHUNK).contains(&count));
                let file=if reading_final||exclusive{value.final_file.as_ref().unwrap()}else{value.temporary.as_ref().unwrap()};
                if offset>=file.len()||scenario=="early-eof"{status(id,1)}else{let mut data=file[offset..(offset+count).min(file.len())].to_vec();
                    if scenario=="corrupt-readback"&&!reading_final||scenario=="corrupt-final"&&reading_final{data[0]^=1}
                    if scenario=="overlong-data"{data.push(0)}
                    let mut out=head(103,id);field(&mut out,&data);out}},
            10=>{assert_eq!(string(&bytes,&mut at,256).unwrap(),b"opaque\0\xff");assert_eq!(u32_at(&bytes,&mut at),4);let proposed=0o100000|u32_at(&bytes,&mut at);assert_eq!(proposed,0o100644);if scenario!="mode-ignored"{mode=proposed}assert_eq!(at,bytes.len());status(id,0)},
            200=>{assert_eq!(string(&bytes,&mut at,8192).unwrap(),b"fsync@openssh.com");assert_eq!(string(&bytes,&mut at,256).unwrap(),b"opaque\0\xff");assert_eq!(at,bytes.len());status(id,if scenario=="sync-failure"{4}else{0})},
            4=>{assert_eq!(string(&bytes,&mut at,256).unwrap(),if reading_final{b"final\0".as_slice()}else{b"opaque\0\xff".as_slice()});assert_eq!(at,bytes.len());if scenario=="lost-close"{return value}status(id,if scenario=="close-failure"{4}else{0})},
            18=>{assert_eq!(string(&bytes,&mut at,8192).unwrap(),target.temporary_path.as_bytes());assert_eq!(string(&bytes,&mut at,8192).unwrap(),target.final_path.as_bytes());assert_eq!(at,bytes.len());assert!(value.final_file.is_none());
                value.final_file=value.temporary.take();if scenario=="lost-rename"{return value}
                if scenario=="stop-rename"{stop.store(true,Ordering::Release);let mut end=[0];let _=stream.read(&mut end).await;value.shutdown_seen=true;return value}status(id,0)},
            _=>panic!("Prohibited generated upload opcode")
        };
        if stream.write_u32(response.len()as u32).await.is_err()||stream.write_all(&response).await.is_err(){return value}
    }
}
async fn run(scenario:&'static str,source:&[u8])->(Result<Receipt,Interrupted>,Observed){
    let(a,b)=tokio::io::duplex(1024);let stop=Arc::new(AtomicBool::new(false));let remote=tokio::spawn(peer(b,scenario,stop.clone(),false));
    let result=send_generated(a,&target(),source,Limits{request_deadline:Duration::from_millis(300),total_deadline:Duration::from_secs(3)},Some(stop)).await;
    let observed=tokio::time::timeout(Duration::from_secs(1),remote).await.unwrap().unwrap();(result,observed)
}
#[test]fn target_validation_redacts_and_preserves_byte_exact_paths(){
    let value=Target::new("/generated","Cafe\u{301}.bin",[1;16]).unwrap();assert!(value.final_path.ends_with("Cafe\u{301}.bin"));assert_eq!(format!("{value:?}"),"<SFTP fresh upload target>");
    for directory in ["", "relative", "/a/../b", "/a//b", "/a/", "/a\0b"]{assert!(Target::new(directory,"name",[1;16]).is_err())}
    for name in ["", ".", "..", "a/b", "a\0b"]{assert!(Target::new("/",name,[1;16]).is_err())}
    assert!(Target::new("/","name",[0;16]).is_err());assert!(Target::new("/",&"x".repeat(256),[1;16]).is_err());
    assert!(Target::new("/","name",[1;16]).unwrap().final_path.starts_with("/name"));
}
#[tokio::test(flavor="current_thread")]async fn exact_acknowledged_upload_and_empty_readback(){
    for data in [Vec::new(),(0..65553).map(|i|(i%251)as u8).collect::<Vec<_>>()]{
        let(result,seen)=run("normal",&data).await;let receipt=result.unwrap();assert_eq!(receipt.bytes,data.len()as u64);assert_eq!(receipt.digest,<[u8;32]>::from(Sha256::digest(&data)));
        assert!(receipt.sync_acknowledged&&receipt.rename_acknowledged&&receipt.final_close_acknowledged&&receipt.stream_shutdown);
        assert!(seen.temporary.is_none());assert_eq!(seen.final_file.unwrap(),data);assert!(seen.shutdown_seen);assert_eq!(seen.operations.iter().filter(|&&v|v==18).count(),1);
    }
}
#[tokio::test(flavor="current_thread")]async fn existing_names_and_concurrent_name_race_never_overwrite(){
    for scenario in ["occupied","temp-conflict","name-race"]{
        let(result,seen)=run(scenario,b"New generated bytes").await;let error=result.unwrap_err();assert!(!error.publication_may_have_happened);assert!(!seen.operations.contains(&18));
        if scenario=="occupied"{assert_eq!(seen.final_file.unwrap(),b"Keep existing");assert!(!seen.operations.contains(&3));assert!(!error.temporary_may_exist)}
        else if scenario=="name-race"{assert_eq!(seen.final_file.unwrap(),b"Keep raced target");assert!(error.temporary_may_exist)}
        else{assert_eq!(seen.temporary.unwrap(),b"Keep temporary collision")}
    }
}
#[tokio::test(flavor="current_thread")]async fn unsupported_or_ambiguous_sync_refuses_before_remote_mutation(){
    for scenario in ["no-sync","duplicate-sync"]{let(result,seen)=run(scenario,b"Generated").await;let error=result.unwrap_err();assert!(!error.temporary_may_exist&&!error.publication_may_have_happened);assert_eq!(seen.operations,[1]);}
}
#[tokio::test(flavor="current_thread")]async fn ack_readback_sync_and_close_failures_keep_temporary_not_final(){
    for scenario in ["denied-write","wrong-write-id","trailing-status","oversize-frame","corrupt-readback","overlong-data","early-eof","mode-ignored","sync-failure","close-failure"]{
        let(result,seen)=run(scenario,b"Immutable generated source").await;let error=result.unwrap_err();assert!(error.temporary_may_exist&&!error.publication_may_have_happened);assert!(seen.temporary.is_some());assert!(seen.final_file.is_none());assert!(!seen.operations.contains(&18));
    }
}
#[tokio::test(flavor="current_thread")]async fn lost_create_and_lost_rename_report_different_uncertainty(){
    let(error,seen)=run("lost-create",b"Source retained").await;let error=error.unwrap_err();assert_eq!(error.phase,Phase::OpeningTemporary);assert!(error.temporary_may_exist&&!error.publication_may_have_happened);assert!(seen.temporary.is_some());assert!(seen.final_file.is_none());
    let(error,seen)=run("lost-rename",b"Source retained").await;let error=error.unwrap_err();assert_eq!(error.phase,Phase::Publishing);assert!(error.publication_may_have_happened);assert_eq!(seen.final_file.unwrap(),b"Source retained");
}
#[tokio::test(flavor="current_thread")]async fn stopped_write_and_publish_drain_generated_peer_without_remove(){
    for scenario in ["stop-write","stop-rename"]{let(result,seen)=run(scenario,b"Source retained").await;let error=result.unwrap_err();assert_eq!(error.cause,Failure::Stopped);assert!(seen.shutdown_seen);assert!(!seen.operations.contains(&13));assert_eq!(error.publication_may_have_happened,scenario=="stop-rename");}
}
#[tokio::test(flavor="current_thread")]async fn corrupted_final_is_not_success_and_original_input_remains_unchanged(){
    let source=b"Original input retained";let before=source.to_vec();let(result,seen)=run("corrupt-final",source).await;let error=result.unwrap_err();assert_eq!(error.phase,Phase::FinalReadback);assert!(error.publication_may_have_happened);assert_eq!(source,&before[..]);assert!(seen.final_file.is_some());
}
#[tokio::test(flavor="current_thread")]async fn oversize_generated_source_refuses_without_sending_a_frame(){
    let(a,mut b)=tokio::io::duplex(32);let bytes=vec![0;MAX_GENERATED_BYTES+1];let result=send_generated(a,&target(),&bytes,Limits::default(),None).await.unwrap_err();
    assert_eq!(result.cause,Failure::Input);assert!(!result.temporary_may_exist&&!result.publication_may_have_happened);let mut end=[0];assert_eq!(b.read(&mut end).await.unwrap(),0);
}

struct ControlledSource{mode:&'static str,stop:Arc<AtomicBool>}
impl Source for ControlledSource{
    fn size(&self)->u64{if self.mode=="oversize"{(1<<30)+1}else{5}}
    async fn next(&mut self,_offset:u64,count:usize)->Result<Vec<u8>>{
        assert_ne!(self.mode,"oversize");Ok(vec![6;if self.mode=="short"{count-1}else{count}])
    }
    async fn permit_publication(&mut self,digest:[u8;32])->Result<()>{
        assert_eq!(digest,<[u8;32]>::from(Sha256::digest([6;5])));
        if self.mode=="stop"||self.mode=="closed-on-stop"{self.stop.store(true,Ordering::Release)}
        if self.mode=="closed-on-stop"{return Err(Failure::Protocol)}
        if self.mode=="wait"||self.mode=="stop"{std::future::pending::<()>().await}
        Err(Failure::SourceChanged)
    }
}
#[tokio::test(flavor="current_thread")]async fn upload_streamed_source_requires_exact_bytes_and_bounded_publication_permission(){
    for mode in["short","reject","wait","stop","closed-on-stop","oversize"]{
        let(a,b)=tokio::io::duplex(1024);let stop=Arc::new(AtomicBool::new(false));let remote=tokio::spawn(peer(b,"normal",stop.clone(),false));
        let source=ControlledSource{mode,stop:stop.clone()};
        let error=send_source(a,&target(),source,Limits{request_deadline:Duration::from_millis(100),total_deadline:Duration::from_secs(1)},Some(stop)).await.unwrap_err();
        let observed=tokio::time::timeout(Duration::from_secs(1),remote).await.unwrap().unwrap();
        assert!(!error.publication_may_have_happened);assert!(!observed.operations.contains(&18));assert!(observed.final_file.is_none());
        if mode=="oversize"{assert_eq!(error.cause,Failure::Input);assert!(observed.operations.is_empty());assert!(!error.temporary_may_exist)}
        else{
            assert!(error.temporary_may_exist);assert!(observed.temporary.is_some());
            assert_eq!(error.phase,if mode=="short"{Phase::Writing}else{Phase::Authorization});
            assert_eq!(error.cause,if mode=="wait"{Failure::Timeout}else if mode=="stop"||mode=="closed-on-stop"{Failure::Stopped}else{Failure::SourceChanged});
        }
    }
}
async fn exclusive(scenario:&'static str,source:&[u8])->(Result<Receipt,Interrupted>,Observed){
    let(a,b)=tokio::io::duplex(1024);let stop=Arc::new(AtomicBool::new(false));let remote=tokio::spawn(peer(b,scenario,stop.clone(),true));
    let result=send_source_exclusive(a,&target(),Generated(source),Limits{request_deadline:Duration::from_millis(300),total_deadline:Duration::from_secs(3)},Some(stop)).await;
    let observed=tokio::time::timeout(Duration::from_secs(1),remote).await.unwrap().unwrap();
    assert!(observed.temporary.is_none());assert!(!observed.operations.iter().any(|k|[13,14,15,18,20].contains(k)));
    (result,observed)
}
#[tokio::test(flavor="current_thread")]async fn exclusive_empty_and_streamed_readback_have_no_staging_alias_or_rename(){
    for bytes in[vec![],(0..65553).map(|i|(i%251)as u8).collect()]{
        let(receipt,observed)=exclusive("normal",&bytes).await;let receipt=receipt.unwrap();
        assert!(receipt.exclusive_create_acknowledged&&!receipt.rename_acknowledged&&receipt.sync_acknowledged&&receipt.final_close_acknowledged&&receipt.stream_shutdown);
        assert_eq!(receipt.digest,<[u8;32]>::from(Sha256::digest(&bytes)));assert_eq!(observed.final_file.unwrap(),bytes);assert!(observed.shutdown_seen);
    }
}
#[tokio::test(flavor="current_thread")]async fn exclusive_initial_and_atomic_open_conflicts_preserve_competing_file(){
    for scenario in["occupied","open-race"]{
        let(result,seen)=exclusive(scenario,b"Must not replace").await;let error=result.unwrap_err();
        assert_eq!(seen.final_file.unwrap(),if scenario=="occupied"{b"Keep existing".to_vec()}else{b"Keep raced target".to_vec()});
        assert!(!seen.operations.contains(&6));assert_eq!(error.publication_may_have_happened,scenario=="open-race");
    }
}
#[tokio::test(flavor="current_thread")]async fn exclusive_missing_sync_refuses_before_creation(){
    for scenario in["no-sync","duplicate-sync"]{let(result,seen)=exclusive(scenario,b"Keep source").await;assert!(!result.unwrap_err().publication_may_have_happened);assert!(seen.final_file.is_none());assert_eq!(seen.operations,[1]);}
}
#[tokio::test(flavor="current_thread")]async fn exclusive_complete_denied_first_open_is_the_only_recoverable_status(){
    let(result,seen)=exclusive("denied-open",b"Source remains local").await;
    let refused=result.unwrap_err();assert!(refused.refused_first_open());
    assert_eq!(seen.operations,[1,7,3]);assert!(seen.final_file.is_none()&&seen.shutdown_seen);
    let(result,seen)=exclusive("ambiguous-open",b"Source remains local").await;
    let ambiguous=result.unwrap_err();assert!(!ambiguous.refused_first_open());
    assert_eq!((ambiguous.cause,ambiguous.phase),(Failure::Status(4),Phase::OpeningFinal));
    assert!(ambiguous.publication_may_have_happened&&seen.final_file.is_none());
    for scenario in["denied-open-wrong-id","denied-open-trailing","lost-create"]{
        let(result,seen)=exclusive(scenario,b"Source remains local").await;
        let invalid=result.unwrap_err();assert!(!invalid.refused_first_open());
        assert!(invalid.publication_may_have_happened);
        assert_eq!(invalid.phase,Phase::OpeningFinal);
        assert!(!seen.operations.contains(&6));
    }
}
struct FailedShutdown(DuplexStream);
impl AsyncRead for FailedShutdown{
    fn poll_read(mut self:Pin<&mut Self>,cx:&mut Context<'_>,buf:&mut tokio::io::ReadBuf<'_>)->Poll<io::Result<()>>{
        Pin::new(&mut self.0).poll_read(cx,buf)
    }
}
impl AsyncWrite for FailedShutdown{
    fn poll_write(mut self:Pin<&mut Self>,cx:&mut Context<'_>,buf:&[u8])->Poll<io::Result<usize>>{Pin::new(&mut self.0).poll_write(cx,buf)}
    fn poll_flush(mut self:Pin<&mut Self>,cx:&mut Context<'_>)->Poll<io::Result<()>>{Pin::new(&mut self.0).poll_flush(cx)}
    fn poll_shutdown(self:Pin<&mut Self>,_:&mut Context<'_>)->Poll<io::Result<()>>{Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))}
}
#[tokio::test(flavor="current_thread")]async fn denied_first_open_with_failed_channel_shutdown_still_drains(){
    let(a,b)=tokio::io::duplex(1024);let stop=Arc::new(AtomicBool::new(false));
    let remote=tokio::spawn(peer(b,"denied-open",stop.clone(),true));
    let error=send_source_exclusive(FailedShutdown(a),&target(),Generated(b"Source remains local"),
        Limits{request_deadline:Duration::from_millis(300),total_deadline:Duration::from_secs(3)},Some(stop)).await.unwrap_err();
    let seen=tokio::time::timeout(Duration::from_secs(1),remote).await.unwrap().unwrap();
    assert!(!error.refused_first_open());assert_eq!((error.cause,error.phase),(Failure::Io,Phase::OpeningFinal));
    assert!(error.publication_may_have_happened&&seen.final_file.is_none());
}
#[tokio::test(flavor="current_thread")]async fn exclusive_lost_create_close_and_bad_ack_are_conservative_without_cleanup(){
    for scenario in["lost-create","lost-close","denied-write","wrong-write-id","trailing-status","oversize-frame","corrupt-readback","overlong-data","early-eof","mode-ignored","sync-failure","close-failure","corrupt-final"]{
        let(result,seen)=exclusive(scenario,b"Source remains unchanged").await;let error=result.unwrap_err();
        assert!(!error.temporary_may_exist&&error.publication_may_have_happened);assert!(seen.final_file.is_some());
        if scenario=="lost-create"{assert_eq!(error.phase,Phase::OpeningFinal);assert!(!seen.operations.contains(&6));}
    }
}
#[tokio::test(flavor="current_thread")]async fn exclusive_stop_during_actual_write_drops_stream_and_keeps_partial_name(){
    let(result,seen)=exclusive("stop-write",b"Source retained").await;let error=result.unwrap_err();
    assert_eq!((error.cause,error.phase),(Failure::Stopped,Phase::Writing));assert!(error.publication_may_have_happened&&!error.temporary_may_exist);assert!(seen.shutdown_seen&&seen.final_file.is_some());
}
#[tokio::test(flavor="current_thread")]async fn exclusive_source_failure_after_creation_remains_reviewable(){
    for mode in["short","reject","wait","stop","closed-on-stop"]{
        let(a,b)=tokio::io::duplex(1024);let stop=Arc::new(AtomicBool::new(false));let remote=tokio::spawn(peer(b,"normal",stop.clone(),true));
        let error=send_source_exclusive(a,&target(),ControlledSource{mode,stop:stop.clone()},Limits{request_deadline:Duration::from_millis(100),total_deadline:Duration::from_secs(1)},Some(stop)).await.unwrap_err();
        let seen=tokio::time::timeout(Duration::from_secs(1),remote).await.unwrap().unwrap();
        assert!(error.publication_may_have_happened&&!error.temporary_may_exist);assert!(seen.final_file.is_some()&&seen.temporary.is_none());assert!(!seen.operations.contains(&18));
    }
}
