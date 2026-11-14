//! One generated encrypted transfer. Never connects to an input endpoint.
#[allow(dead_code)]mod ssh_fixture;
use macexplorer_sftp_reader_qualification::{download::{self,Limits},ssh::{self,Peer,Verified,Decision,Action},wire::Metadata};
use ssh_fixture::{fixture,Counts};
use std::{sync::{Arc,mpsc,atomic::Ordering},time::{Duration,Instant}};
use tokio::sync::mpsc as async_mpsc;
fn generated(offset:u64)->u8{((offset*31+7)%251)as u8}
fn main(){
    let scenario=std::env::args().nth(1).unwrap_or_default();assert!(["download-good","download-empty","download-changed","download-denied","download-stop","download-lost-close","download-wrong-id"].contains(&scenario.as_str()));
    let counts=Arc::new(Counts::default());let observed=counts.clone();let(tx,rx)=mpsc::sync_channel(1);let server_scenario=scenario.clone();
    let server=std::thread::spawn(move||fixture(server_scenario,observed,tx));
    let(address,key)=rx.recv_timeout(Duration::from_secs(3)).unwrap();let runtime=ssh_fixture::runtime();let metrics=runtime.handle().clone();let began=Instant::now();
    let(received,stopped,close_seconds)=runtime.block_on(async{
        let(tx,mut rx)=async_mpsc::channel(1);let peer=Peer::new("generated.example",address.port(),[1;16]).unwrap();
        let mut connecting=Box::pin(Verified::connect(peer,address,None,tx,Duration::from_secs(2)));
        let request=tokio::select!{r=rx.recv()=>r.unwrap(),r=&mut connecting=>panic!("Connected before host review: {}",r.is_ok())};
        assert_eq!(request.challenge.current,key);assert!(request.reply.send(Decision{challenge:request.challenge,action:Action::ConnectOnce}).is_ok());
        let mut ssh=connecting.await.unwrap();assert_eq!(counts.auth.load(Ordering::SeqCst),0);
        ssh.password("generated",zeroize::Zeroizing::new("ephemeral qualification password".into())).await.unwrap();
        let expected=Metadata{size:Some(if scenario=="download-empty"{0}else{1024*1024+17}),modified:Some(19),permissions:Some(0o100644)};
        let bounds=Limits{request_deadline:Duration::from_millis(500),total_deadline:Duration::from_secs(5),..Limits::default()};
        let mut received=0;
        let operation=ssh.receive_file("/generated/Requested.bin",expected,bounds,|offset:u64,bytes:Vec<u8>|{
            assert_eq!(offset,received);for(index,byte)in bytes.iter().enumerate(){assert_eq!(*byte,generated(offset+index as u64))}received+=bytes.len()as u64;
            std::future::ready(Ok(()))
        });
        let result=tokio::time::timeout(if scenario=="download-stop"{Duration::from_millis(40)}else{Duration::from_secs(7)},operation).await;
        let stopped=if scenario=="download-stop"{assert!(result.is_err());true}else{
            match scenario.as_str(){
                "download-good"|"download-empty"=>{let receipt=result.unwrap().unwrap();assert_eq!(receipt.bytes,expected.size.unwrap());assert!(receipt.close_acknowledged&&receipt.stream_shutdown)},
                "download-changed"=>assert_eq!(result.unwrap(),Err(ssh::ReceiveFailure::Body(download::Failure::Changed))),
                "download-denied"=>assert_eq!(result.unwrap(),Err(ssh::ReceiveFailure::Body(download::Failure::Status(3)))),
                "download-wrong-id"=>assert_eq!(result.unwrap(),Err(ssh::ReceiveFailure::Body(download::Failure::Protocol))),
                "download-lost-close"=>assert_eq!(result.unwrap(),Err(ssh::ReceiveFailure::Body(download::Failure::Timeout))),_=>unreachable!(),
            }false
        };
        let close=Instant::now();let drain=ssh.close().await.unwrap();assert!(drain.ssh_task_ended);(received,stopped,close.elapsed().as_secs_f64())
    });
    drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);server.join().unwrap();
    assert_eq!(counts.auth.load(Ordering::SeqCst),1);assert_eq!(counts.socket_ended.load(Ordering::SeqCst),1);assert_eq!(counts.tasks_aborted.load(Ordering::SeqCst),0);
    if scenario=="download-denied"||scenario=="download-stop"{assert_eq!(received,0)}
    println!("{{\"passed\":true,\"scenario\":\"{scenario}\",\"generatedBytesChecked\":{received},\"explicitStop\":{stopped},\"elapsedSeconds\":{},\"closeSeconds\":{close_seconds},\"clientTasksAfterRuntimeDrop\":0,\"fixtureTasksAborted\":0,\"serverSocketEnded\":true,\"personalEndpoints\":0}}",began.elapsed().as_secs_f64());
}
