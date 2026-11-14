//! Actual encrypted russh duplex controls. The peer holds its own Close after
//! receiving real EOF; it never calls or substitutes the client's registry.
//! No TCP, independent server, signed helper or universal SFTP-server claim.
use super::*;
use crate::upload::{self,inplace_v1::{ReadSink,Observed,OpenFailure,EditRejection}};
use russh::{server,ChannelId};
use std::sync::Mutex;
use tokio::{io::{AsyncReadExt,AsyncWriteExt},sync::Semaphore};
#[derive(Default)]struct Counts{
    opened:std::sync::atomic::AtomicUsize,body:std::sync::atomic::AtomicUsize,
    eof_received:AtomicBool,eof_sent:AtomicBool,client_close_received:AtomicBool,
    close_before_release:AtomicBool,peer_close_allowed:AtomicBool,peer_close_queued:AtomicBool,
}
struct Fixture{release:Arc<Semaphore>,counts:Arc<Counts>,eof_first:bool,malformed:bool,
    tasks:Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>>}
impl server::Handler for Fixture{
    type Error=russh::Error;
    async fn auth_password(&mut self,user:&str,password:&str)->std::result::Result<server::Auth,russh::Error>{
        Ok(if user=="generated"&&password=="ephemeral"{server::Auth::Accept}else{server::Auth::reject()})
    }
    async fn channel_open_session(&mut self,channel:Channel<server::Msg>,reply:server::ChannelOpenHandle,
        session:&mut server::Session)->std::result::Result<(),russh::Error>{
        reply.accept().await;self.counts.opened.fetch_add(1,Ordering::SeqCst);
        let release=self.release.clone();let counts=self.counts.clone();let eof=self.eof_first;let malformed=self.malformed;
        let id=channel.id();let handle=session.handle();
        self.tasks.lock().unwrap().push(tokio::spawn(async move{
            let mut stream=channel.into_stream();let mut init=[0u8;9];
            if stream.read_exact(&mut init).await.is_ok(){
                assert_eq!(init,[0,0,0,5,1,0,0,0,3]);
                let mut version=vec![2,0,0,0,3];
                if malformed{
                    // Unsupported first, then a duplicate supported extension.
                    for value in [b"2",b"1"]{
                        version.extend(17u32.to_be_bytes());version.extend(b"fsync@openssh.com");
                        version.extend(1u32.to_be_bytes());version.extend(value);
                    }
                }
                let _=stream.write_all(&(version.len()as u32).to_be_bytes()).await;
                let _=stream.write_all(&version).await;
                if eof&&stream.shutdown().await.is_ok(){counts.eof_sent.store(true,Ordering::SeqCst);}
            }
            if !malformed{
                // The client must retain its stream and send EOF. Its actual
                // channel_eof event is independently recorded below. This peer
                // deliberately sends NO Close until Root's test releases it.
                if let Ok(permit)=release.acquire().await{permit.forget();}
            }
            counts.peer_close_allowed.store(true,Ordering::SeqCst);
            if !counts.client_close_received.load(Ordering::SeqCst)&&handle.close(id).await.is_ok(){
                counts.peer_close_queued.store(true,Ordering::SeqCst);
            }
            // Keep the peer's own stream until after its explicit Close action.
            drop(stream);
        }));Ok(())
    }
    async fn subsystem_request(&mut self,id:ChannelId,name:&str,session:&mut server::Session)->std::result::Result<(),russh::Error>{
        if name=="sftp"{session.channel_success(id)?;}else{session.channel_failure(id)?;}Ok(())
    }
    async fn channel_eof(&mut self,_id:ChannelId,_session:&mut server::Session)->std::result::Result<(),russh::Error>{
        self.counts.eof_received.store(true,Ordering::SeqCst);Ok(())
    }
    async fn channel_close(&mut self,_id:ChannelId,_session:&mut server::Session)->std::result::Result<(),russh::Error>{
        self.counts.client_close_received.store(true,Ordering::SeqCst);
        if !self.counts.peer_close_allowed.load(Ordering::SeqCst){self.counts.close_before_release.store(true,Ordering::SeqCst);}
        // Let the genuine library Close ACK flush. Old Drop-before-wait code
        // still cannot observe it: that client already erased its channel ID.
        Ok(())
    }
}
struct NoBody(Arc<Counts>);
impl ReadSink for NoBody{
    async fn begin(&mut self,_:Observed)->std::result::Result<(),upload::Failure>{self.0.body.fetch_add(1,Ordering::SeqCst);Err(upload::Failure::Protocol)}
    async fn chunk(&mut self,_:u64,_:Vec<u8>)->std::result::Result<(),upload::Failure>{self.0.body.fetch_add(1,Ordering::SeqCst);Err(upload::Failure::Protocol)}
}
async fn actual_close_case(mode:u8){
    let release=Arc::new(Semaphore::new(0));let counts=Arc::new(Counts::default());
    let tasks=Arc::new(Mutex::new(Vec::new()));let(a,b)=tokio::io::duplex(131072);
    let key=russh::keys::PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
    let config=Arc::new(server::Config{keys:vec![key],auth_rejection_time:Duration::ZERO,
        auth_rejection_time_initial:Some(Duration::ZERO),inactivity_timeout:Some(Duration::from_secs(5)),
        channel_buffer_size:8,..Default::default()});
    let fixture=Fixture{release:release.clone(),counts:counts.clone(),eof_first:mode==1,malformed:mode==4,tasks:tasks.clone()};
    let mut server=tokio::spawn(async move{let handle=server::run_stream(config,b,fixture).await?;handle.await});
    let registry=Arc::new(CloseRegistry::default());let accepted=Arc::new(AtomicBool::new(false));let(tx,mut rx)=mpsc::channel::<TrustRequest>(1);
    let review=tokio::spawn(async move{if let Some(request)=rx.recv().await{let _=request.reply.send(Decision{challenge:request.challenge,action:Action::ConnectOnce});}});
    let handler=Handler{peer:Peer::new("generated.example",22,[1;16]).unwrap(),previous:None,requests:tx,
        accepted:accepted.clone(),verified:None,deadline:Duration::from_secs(1),review_phase:None,profiles:true,inplace_closes:registry.clone()};
    let raw=client::connect_stream(Arc::new(client::Config{preferred:profile_preferences(),channel_buffer_size:8,..Default::default()}),a,handler).await.unwrap();
    let review_normal=review.await.is_ok();assert!(accepted.load(Ordering::SeqCst));
    let mut verified=Verified{handle:Some(raw),deadline:Duration::from_millis(if mode==2{500}else{1000}),authenticated:false,
        channel_opened:false,interactive_started:false,interactive_pending:None,inplace_closes:registry.clone()};
    verified.password("generated",Zeroizing::new("ephemeral".into())).await.unwrap();
    let stop=Arc::new(AtomicBool::new(false));let operation_stop=stop.clone();let body_counts=counts.clone();
    let mut operation=Box::pin(async move{
        let result=verified.open_inplace_v3("/generated/file.txt".into(),crate::wire::Metadata{
            size:Some(1),modified:Some(77),permissions:Some(0o100600)},NoBody(body_counts),
            upload::Limits{request_deadline:Duration::from_secs(1),total_deadline:Duration::from_secs(2)},Some(operation_stop)).await;
        (verified,result)
    });
    let until=tokio::time::Instant::now()+Duration::from_secs(2);let mut early_result=None;
    while !(if mode==4{counts.peer_close_queued.load(Ordering::SeqCst)}else{counts.eof_received.load(Ordering::SeqCst)})&&tokio::time::Instant::now()<until{
        tokio::select!{biased;
            value=&mut operation=>{early_result=Some(value);break},
            _=tokio::time::sleep(Duration::from_millis(1))=>{},
        }
    }
    // Poll while peer Close remains held. A kernel/outer early Drop, or treating
    // either direction's EOF as Close, must become a semantic failure here.
    if mode<4&&early_result.is_none(){tokio::select!{biased;
        value=&mut operation=>{early_result=Some(value)},
        _=tokio::time::sleep(Duration::from_millis(20))=>{},
    }}
    let eof_seen=counts.eof_received.load(Ordering::SeqCst);
    let peer_eof_seen=counts.eof_sent.load(Ordering::SeqCst);
    let premature_close=counts.close_before_release.load(Ordering::SeqCst);
    let prematurely_finished=early_result.is_some();let mut timed_result=None;
    if early_result.is_none()&&mode==2{timed_result=Some(tokio::time::timeout(Duration::from_secs(2),&mut operation).await);}
    if early_result.is_none()&&mode==3{stop.store(true,Ordering::Release);timed_result=Some(tokio::time::timeout(Duration::from_secs(2),&mut operation).await);}
    // Fatal timeout/Stop may now drop the stream and terminate the transport.
    // That is intentionally different from an early Drop during healthy wait.
    counts.peer_close_allowed.store(true,Ordering::SeqCst);release.add_permits(4);
    let(verified,result)=if let Some(value)=early_result{value}else{
        match timed_result{Some(Ok(value))=>value,Some(Err(_))|None=>operation.await}
    };
    let kind=result.err();let drain=verified.close().await;
    let server_ended=tokio::time::timeout(Duration::from_secs(3),&mut server).await;
    let server_normal=matches!(&server_ended,Ok(Ok(Ok(()))));
    // Timeout and Stop intentionally discard the incomplete channel. russh's
    // server then ends with a real BrokenPipe, not an unjoined or aborted task.
    let server_terminal=(mode==2||mode==3)&&matches!(&server_ended,
        Ok(Ok(Err(russh::Error::IO(error)))) if error.kind()==std::io::ErrorKind::BrokenPipe);
    let server_abort_requested=server_ended.is_err();let mut server_abort_joined=false;
    if server_abort_requested{server.abort();let _=server.await;server_abort_joined=true;}
    let children=std::mem::take(&mut *tasks.lock().unwrap());
    let peer_total=children.len();let(mut peer_normal,mut peer_aborted,mut peer_abort_joined,mut peer_join_failed)=(0usize,0usize,0usize,0usize);
    for mut child in children{
        match tokio::time::timeout(Duration::from_secs(3),&mut child).await{
            Ok(Ok(()))=>peer_normal+=1,
            Ok(Err(_))=>peer_join_failed+=1,
            Err(_)=>{peer_aborted+=1;child.abort();let _=child.await;peer_abort_joined+=1;},
        }
    }
    let(disconnect_queued,ssh_task_ended,ssh_ended_normally)=match &drain{
        Ok(value)=>(value.disconnect_queued,value.ssh_task_ended,value.ended_normally),_ =>(false,false,false),
    };
    let ssh_close_timed_out=matches!(&drain,Err(Failure::Timeout));
    // Closed numeric/stage diagnostics only; no credentials, body or paths.
    eprintln!("startup3_owned_close_drain mode={mode} review_normal={review_normal} disconnect_queued={disconnect_queued} ssh_task_ended={ssh_task_ended} ssh_ended_normally={ssh_ended_normally} ssh_close_timed_out={ssh_close_timed_out} server_normal={server_normal} server_abort_requested={server_abort_requested} server_abort_joined={server_abort_joined} peer_total={peer_total} peer_normal={peer_normal} peer_aborted={peer_aborted} peer_abort_joined={peer_abort_joined} peer_join_failed={peer_join_failed}");
    // All semantic assertions follow actual cleanup/join. Containment is RED.
    if mode<4{
        assert!(eof_seen&&!premature_close&&!prematurely_finished,"rejected stream dropped or returned before peer Close");
        if mode==1{assert!(peer_eof_seen,"peer's real EOF was not exercised");}
    }
    assert_eq!(kind,Some(if mode==2{OpenFailure::Fatal(upload::Failure::Timeout)}else if mode==3{
        OpenFailure::Fatal(upload::Failure::Stopped)}else if mode==4{OpenFailure::Fatal(upload::Failure::Protocol)}else{
        OpenFailure::Rejected(EditRejection::SyncUnavailable)}));
    assert!(review_normal,"actual trust-review task failed to join normally");
    assert!(disconnect_queued&&ssh_task_ended&&ssh_ended_normally&&!ssh_close_timed_out,
        "actual client SSH task did not close normally; timeout is failure/uncertainty");
    assert!((server_normal||server_terminal)&&!server_abort_requested&&!server_abort_joined,
        "actual server task did not terminate in its expected mode; abort is failure");
    assert_eq!(peer_normal,peer_total,"actual subsystem task failed normal join");
    assert_eq!((peer_aborted,peer_abort_joined,peer_join_failed),(0,0,0),"subsystem containment/join failure cannot qualify");
    assert_eq!(counts.opened.load(Ordering::SeqCst),1);assert_eq!(counts.body.load(Ordering::SeqCst),0);
    assert!(registry.begin().is_ok());
}
#[tokio::test(flavor="current_thread")]async fn actual_held_peer_close_after_eof_blocks_healthy_rejection(){actual_close_case(0).await;}
#[tokio::test(flavor="current_thread")]async fn actual_eof_in_both_directions_is_not_a_close_ack(){actual_close_case(1).await;}
#[tokio::test(flavor="current_thread")]async fn actual_missing_peer_close_is_terminal_timeout(){actual_close_case(2).await;}
#[tokio::test(flavor="current_thread")]async fn actual_stop_while_peer_close_held_is_terminal(){actual_close_case(3).await;}
#[tokio::test(flavor="current_thread")]async fn actual_peer_first_close_cannot_make_malformed_version_healthy(){actual_close_case(4).await;}
