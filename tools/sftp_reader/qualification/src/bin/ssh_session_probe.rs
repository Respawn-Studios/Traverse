//! One admitted generated loopback session per process. Separate owned runtimes
//! let the fixture observe socket closure after cancelling a pre-Handle client.
mod ssh_fixture;
use ssh_fixture::{Counts,public,runtime,fixture};
use macexplorer_sftp_reader_qualification::ssh::{self,Action,Decision,Key,Peer,Verified};
use russh::keys::{Algorithm,PrivateKey};
use std::{net::SocketAddr,sync::{Arc,atomic::Ordering,mpsc as std_mpsc},time::{Duration,Instant}};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

const SCENARIOS:&[&str]=&["first","matching","changed-refused","changed-replaced","stale-decision",
    "cancel-host","host-deadline","pre-banner","bad-password","read-stop","lost-close","disconnect-read",
    "unsolicited","legacy-refused"];
const TIME:Duration=Duration::from_millis(400);
async fn client(scenario:&str,address:SocketAddr,key:Key,counts:Arc<Counts>)->(bool,bool){
    let previous=if scenario=="matching"{Some(key)}else if scenario.starts_with("changed"){
        Some(public(&PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap()))
    }else{None};
    let peer=Peer::new("generated.example",address.port(),[1;16]).unwrap();
    let(tx,mut requests)=mpsc::channel(1);
    let connect=Verified::connect(peer,address,previous,tx,TIME);
    tokio::pin!(connect);
    if ["pre-banner","legacy-refused"].contains(&scenario){assert!(connect.await.is_err());return(false,false)}
    let request=tokio::select!{
        request=requests.recv()=>request.expect("Host decision missing"),
        result=&mut connect=>{assert!(result.is_err());panic!("SSH ended before host verification")}
    };
    assert_eq!(counts.auth.load(Ordering::SeqCst),0);assert_eq!(counts.unexpected_auth.load(Ordering::SeqCst),0);
    assert_eq!(counts.credential_lookups.load(Ordering::SeqCst),0);
    if scenario=="cancel-host"{drop(request);return(false,false)}
    if scenario=="host-deadline"{assert!(connect.await.is_err());drop(request);return(false,false)}
    let mut challenge=request.challenge;
    let action=match scenario{"matching"=>Action::UseMatching,"changed-replaced"=>Action::ReplaceVerified,_=>Action::ConnectOnce};
    if scenario=="stale-decision"{challenge.peer=Peer::new("generated.example",address.port(),[2;16]).unwrap()}
    assert!(request.reply.send(Decision{challenge,action}).is_ok());
    let result=connect.await;
    if ["changed-refused","stale-decision"].contains(&scenario){assert!(result.is_err());return(false,false)}
    let mut verified=result.expect("Verified session missing");
    assert!(matches!(verified.metadata_reader().await,Err(ssh::Failure::Authentication)));
    counts.credential_lookups.fetch_add(1,Ordering::SeqCst);
    let password=Zeroizing::new(if scenario=="bad-password"{"generated wrong password"}else{"ephemeral qualification password"}.into());
    let authentication=verified.password("generated",password).await;
    if scenario=="bad-password"{assert_eq!(authentication,Err(ssh::Failure::Authentication));return(false,false)}
    authentication.unwrap();let mut reader=verified.metadata_reader().await.unwrap();
    assert!(matches!(verified.metadata_reader().await,Err(ssh::Failure::Closed)));
    reader.open_directory(".").await.unwrap();
    if scenario=="read-stop"{
        assert!(tokio::time::timeout(Duration::from_millis(80),reader.next_batch()).await.is_err());
        assert!(!reader.is_open());reader.stop();finish(verified,&counts).await;return(false,true)
    }
    if scenario=="disconnect-read"{
        assert!(reader.next_batch().await.is_err());reader.stop();finish(verified,&counts).await;return(false,true)
    }
    let entries=reader.next_batch().await.unwrap().unwrap();assert_eq!(entries.len(),2);
    assert_eq!(entries[0].name,"Generated first.txt");assert_eq!(entries[1].name,"Generated second.txt");
    assert_eq!(entries[0].metadata.size,Some(123));assert_eq!(entries[1].metadata.size,Some(456));
    assert!(reader.next_batch().await.unwrap().is_none());
    if scenario=="unsolicited"{
        let began=Instant::now();while counts.rejected.load(Ordering::SeqCst)<7{
            assert!(began.elapsed()<Duration::from_secs(2));tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }
    let drain=reader.close().await;assert!(drain.stream_released);
    assert_eq!(drain.directory_close_acknowledged,scenario!="lost-close");
    finish(verified,&counts).await;(drain.directory_close_acknowledged,true)
}
async fn finish(verified:Verified,counts:&Counts){
    let drain=verified.close().await.unwrap();assert!(drain.ssh_task_ended);
    counts.ssh_ended_normally.store(usize::from(drain.ended_normally),Ordering::SeqCst);
    counts.disconnect_queued.store(usize::from(drain.disconnect_queued),Ordering::SeqCst);
}
fn main(){
    let scenario=std::env::args().nth(1).unwrap_or_default();assert!(SCENARIOS.contains(&scenario.as_str()));
    let start=Instant::now();let counts=Arc::new(Counts::default());let(tx,rx)=std_mpsc::sync_channel(1);
    let server_counts=counts.clone();let server_scenario=scenario.clone();
    let server=std::thread::spawn(move||fixture(server_scenario,server_counts,tx));
    let(address,key)=rx.recv_timeout(Duration::from_secs(2)).unwrap();
    let runtime=runtime();let metrics=runtime.handle().clone();
    let(ack,authenticated)=runtime.block_on(client(&scenario,address,key,counts.clone()));
    // Includes russh tasks spawned before connect_stream returns its Handle.
    let before_drop=metrics.metrics().num_alive_tasks();
    drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);
    server.join().expect("Generated server failed to drain");
    assert_eq!(counts.socket_ended.load(Ordering::SeqCst),1);
    assert_eq!(counts.tasks_aborted.load(Ordering::SeqCst),0);
    let expected_auth=usize::from(authenticated||scenario=="bad-password");
    assert_eq!(counts.auth.load(Ordering::SeqCst),expected_auth);
    assert_eq!(counts.credential_lookups.load(Ordering::SeqCst),expected_auth);
    assert_eq!(counts.unexpected_auth.load(Ordering::SeqCst),0);
    println!("{{\"scenario\":\"{scenario}\",\"passed\":true,\"connectionAttempts\":1,\"authCalls\":{expected_auth},\"closeAcknowledged\":{ack},\"clientTasksBeforeRuntimeDrop\":{before_drop},\"clientTasksAfterRuntimeDrop\":0,\"serverSocketEnded\":true,\"fixtureTasksAborted\":0,\"fixtureTasksJoined\":{},\"unsolicitedRejected\":{},\"sshEndedNormally\":{},\"disconnectQueued\":{},\"seconds\":{},\"personalEndpoints\":0,\"keychainQueries\":0}}",
        counts.tasks_joined.load(Ordering::SeqCst),counts.rejected.load(Ordering::SeqCst),
        counts.ssh_ended_normally.load(Ordering::SeqCst),counts.disconnect_queued.load(Ordering::SeqCst),start.elapsed().as_secs_f64());
}
