//! One admitted generated encrypted upload, never an input endpoint/file.
#[allow(dead_code)]mod ssh_fixture;
use macexplorer_sftp_reader_qualification::{upload::{self,Target,Limits,Phase},ssh::{self,Peer,Verified,Decision,Action}};
use ssh_fixture::{Counts,fixture};
use std::{sync::{Arc,mpsc,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
use tokio::sync::mpsc as async_mpsc;
fn main(){
    let scenario=std::env::args().nth(1).unwrap_or_default();
    assert!(["upload-good","upload-empty","upload-conflict","upload-name-race","upload-sync-failure","upload-stop-write","upload-stop-rename","upload-lost-create","upload-lost-rename"].contains(&scenario.as_str()));
    let source:Vec<u8>=if scenario=="upload-empty"{Vec::new()}else{(0..1024*1024-7).map(|i|((i*31+7)%251)as u8).collect()};
    let counts=Arc::new(Counts::default());let observed=counts.clone();let(tx,rx)=mpsc::sync_channel(1);let server_scenario=scenario.clone();
    let server=std::thread::spawn(move||fixture(server_scenario,observed,tx));
    let(address,key)=rx.recv_timeout(Duration::from_secs(3)).unwrap();let runtime=ssh_fixture::runtime();let metrics=runtime.handle().clone();let began=Instant::now();
    let(verified,temporary_possible,publication_possible,close_seconds)=runtime.block_on(async{
        let(tx,mut rx)=async_mpsc::channel(1);let peer=Peer::new("generated.example",address.port(),[1;16]).unwrap();
        let mut connecting=Box::pin(Verified::connect(peer,address,None,tx,Duration::from_secs(2)));
        let request=tokio::select!{r=rx.recv()=>r.unwrap(),r=&mut connecting=>panic!("Connected before review: {}",r.is_ok())};
        assert_eq!(request.challenge.current,key);assert_eq!(counts.auth.load(Ordering::SeqCst),0);
        assert!(request.reply.send(Decision{challenge:request.challenge,action:Action::ConnectOnce}).is_ok());
        let mut ssh=connecting.await.unwrap();ssh.password("generated",zeroize::Zeroizing::new("ephemeral qualification password".into())).await.unwrap();
        let stop=Arc::new(AtomicBool::new(false));
        let stopping=if scenario.starts_with("upload-stop-"){
            let signal=stop.clone();let observed=counts.clone();Some(tokio::spawn(async move{
                tokio::time::timeout(Duration::from_secs(3),async{while observed.upload_waiting.load(Ordering::Acquire)==0{tokio::time::sleep(Duration::from_millis(2)).await}}).await.unwrap();
                signal.store(true,Ordering::Release);
            }))
        }else{None};
        let result=ssh.send_generated(&Target::new("/generated","Draft-Notes.bin",[7;16]).unwrap(),&source,
            Limits{request_deadline:Duration::from_millis(700),total_deadline:Duration::from_secs(5)},Some(stop)).await;
        if let Some(task)=stopping{task.await.unwrap()}
        let outcome=match scenario.as_str(){
            "upload-good"|"upload-empty"=>{let receipt=result.unwrap();assert_eq!(receipt.bytes,source.len()as u64);assert!(receipt.sync_acknowledged&&receipt.rename_acknowledged&&receipt.final_close_acknowledged&&receipt.stream_shutdown);(true,false,true)},
            _=>{
                let error=match result.unwrap_err(){ssh::SendFailure::Body(error)=>error,_=>panic!("Unexpected connection failure")};
                assert_eq!(error.publication_may_have_happened,scenario=="upload-stop-rename"||scenario=="upload-lost-rename");
                assert_eq!(error.temporary_may_exist,scenario!="upload-conflict");
                if scenario.starts_with("upload-stop-"){assert_eq!(error.cause,upload::Failure::Stopped)}
                if scenario=="upload-conflict"||scenario=="upload-name-race"{assert_eq!(error.cause,upload::Failure::Conflict)}
                if scenario=="upload-sync-failure"{assert_eq!(error.phase,Phase::Syncing);assert_eq!(error.cause,upload::Failure::Status(4))}
                if scenario=="upload-lost-create"{assert_eq!(error.phase,Phase::OpeningTemporary)}
                if scenario=="upload-lost-rename"{assert_eq!(error.phase,Phase::Publishing)}
                (false,error.temporary_may_exist,error.publication_may_have_happened)
            }
        };
        let closing=Instant::now();let drain=ssh.close().await.unwrap();assert!(drain.ssh_task_ended);(outcome.0,outcome.1,outcome.2,closing.elapsed().as_secs_f64())
    });
    drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);server.join().unwrap();
    assert_eq!(counts.auth.load(Ordering::SeqCst),1);assert_eq!(counts.unexpected_auth.load(Ordering::SeqCst),0);
    assert_eq!(counts.socket_ended.load(Ordering::SeqCst),1);assert_eq!(counts.tasks_aborted.load(Ordering::SeqCst),0);assert_eq!(counts.tasks_joined.load(Ordering::SeqCst),1);
    let seen=counts.upload.lock().unwrap();
    match scenario.as_str(){
        "upload-good"|"upload-empty"=>{assert_eq!(seen.final_file.as_deref(),Some(source.as_slice()));assert!(seen.temporary.is_none()&&seen.shutdown_seen)},
        "upload-conflict"=>{assert_eq!(seen.final_file.as_deref(),Some(b"Keep existing generated bytes".as_slice()));assert!(seen.temporary.is_none()&&!seen.operations.contains(&3))},
        "upload-name-race"=>{assert_eq!(seen.final_file.as_deref(),Some(b"Keep raced generated bytes".as_slice()));assert_eq!(seen.temporary.as_deref(),Some(source.as_slice()))},
        "upload-stop-rename"|"upload-lost-rename"=>assert_eq!(seen.final_file.as_deref(),Some(source.as_slice())),
        _=>{assert!(seen.temporary.is_some());assert!(seen.final_file.is_none())},
    }
    assert!(!seen.operations.contains(&13));
    println!("{{\"passed\":true,\"scenario\":\"{scenario}\",\"verified\":{verified},\"generatedSourceBytes\":{},\"temporaryMayExist\":{temporary_possible},\"publicationMayHaveHappened\":{publication_possible},\"elapsedSeconds\":{},\"closeSeconds\":{close_seconds},\"clientTasksAfterRuntimeDrop\":0,\"fixtureTasksAborted\":0,\"fixtureTasksJoined\":1,\"serverSocketEnded\":true,\"personalEndpoints\":0}}",source.len(),began.elapsed().as_secs_f64());
}
