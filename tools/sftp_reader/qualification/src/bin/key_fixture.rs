//! Generated loopback authentication fixture. Not bundled or ordinarily used.
#[allow(dead_code)]mod ssh_fixture;
use std::{io::{Read,Write},sync::{Arc,mpsc,atomic::Ordering},time::Duration};
fn main(){
    let scenario=std::env::args().nth(1).unwrap_or_default();
    let composed=["key-auth-","mfa-key-auth-","interactive-auth-"].into_iter().find_map(|prefix|scenario.strip_prefix(prefix))
        .is_some_and(|role|["composed-success","composed-sync-failure","composed-lost-rename","composed-lost-close","composed-lost-create","composed-name-race","composed-stop-write",
            "transfer-denied","transfer-changed","transfer-lost-close","transfer-stop","push-success","push-lost-close","push-lost-create","push-name-race","push-conflict","push-stop-write","push-stop-readback","push-sync-failure"].contains(&role));
    let folder=cfg!(feature="folder-download-qualification")&&["key-auth-","mfa-key-auth-","interactive-auth-"].into_iter()
        .find_map(|prefix|scenario.strip_prefix(prefix)).is_some_and(|role|["folder-success","folder-changed-review","folder-changed-body","folder-final-membership",
            "folder-link","folder-collision","folder-limit","folder-denied","folder-stop","folder-lost-close","folder-malformed","folder-denied-close","folder-slow-body"].contains(&role));
    let fresh=cfg!(all(feature="folder-download-qualification",feature="upload-qualification"))&&["key-auth-","mfa-key-auth-","interactive-auth-"].into_iter()
        .find_map(|prefix|scenario.strip_prefix(prefix)).is_some_and(|role|["fresh-success","fresh-root-conflict","fresh-mkdir-race","fresh-open-race","fresh-lost-mkdir",
            "fresh-lost-open","fresh-lost-close","fresh-sync-failure","fresh-stop-write","fresh-stop-readback"].contains(&role));
    assert!(std::env::args().count()==2&&(["first","wrong-passphrase","bad-key","key-denied","key-changed","cancel-host","read-stop","fips","ecdsa-host","before-auth-stop",
        "interactive-two-rounds","interactive-empty","interactive-round-limit","interactive-prompt-limit","interactive-text-limit","mfa-key"].contains(&scenario.as_str())
        ||cfg!(all(feature="download-qualification",feature="upload-qualification"))&&composed||folder||fresh));
    let mut bytes=Vec::new();std::io::stdin().take(16385).read_to_end(&mut bytes).unwrap();assert!(bytes.len()<=16384);
    let public=russh::keys::PublicKey::from_bytes(&bytes).unwrap();
    let counts=Arc::new(ssh_fixture::Counts::default());let observed=counts.clone();let(tx,rx)=mpsc::sync_channel(1);let controls=scenario.clone();
    let task=std::thread::spawn(move||ssh_fixture::key_fixture(scenario,public,observed,tx));
    let(address,key)=rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let key=key.bytes().iter().map(|b|format!("{b:02x}")).collect::<String>();
    println!("{{\"ready\":true,\"port\":{},\"generatedPublicKey\":\"{key}\"}}",address.port());std::io::stdout().flush().unwrap();
    // Exact generated I/O boundaries let the test stop an in-flight body
    // request rather than guessing from elapsed time. Old cases emit no control.
    let mut pending_sent=false;
    while !task.is_finished(){
        #[cfg(feature="folder-download-qualification")]
        if folder&&!pending_sent{
            let pending=counts.folder_waiting.load(Ordering::SeqCst);
            if pending>0{println!("{{\"generatedBodyPending\":\"{}\"}}",if pending==1{"read"}else{"close"});std::io::stdout().flush().unwrap();pending_sent=true;}
        }
        let boundary=if controls.ends_with("transfer-stop")&&counts.file_reads.load(Ordering::SeqCst)>0{Some("read")}
            else if controls.ends_with("transfer-lost-close")&&counts.closes.load(Ordering::SeqCst)>1{Some("close")}
            else{
                #[cfg(feature="upload-qualification")]
                {if controls.ends_with("stop-write")&&counts.upload_waiting.load(Ordering::SeqCst)==1{Some("write")}
                 else if controls.ends_with("stop-readback")&&counts.upload_waiting.load(Ordering::SeqCst)==3{Some("readback")}else{None}}
                #[cfg(not(feature="upload-qualification"))]{None}
            };
        if !pending_sent{if let Some(boundary)=boundary{println!("{{\"generatedBodyPending\":\"{boundary}\"}}");std::io::stdout().flush().unwrap();pending_sent=true;}}
        std::thread::sleep(Duration::from_millis(2));
    }
    task.join().expect("Generated key fixture did not complete");
    assert_eq!(counts.socket_ended.load(Ordering::SeqCst),1);assert_eq!(counts.tasks_aborted.load(Ordering::SeqCst),0);
    assert_eq!(counts.unexpected_auth.load(Ordering::SeqCst),0);
    #[cfg(feature="upload-qualification")]
    let(upload_length,upload_digest,upload_operations)={
        use sha2::{Digest,Sha256};let saved=counts.upload.lock().unwrap();
        (counts.upload_published.load(Ordering::SeqCst),saved.final_file.as_ref().map(|v|Sha256::digest(v).iter().map(|b|format!("{b:02x}")).collect::<String>()).unwrap_or_default(),saved.operations.len())
    };
    #[cfg(feature="upload-qualification")]
    let(rename_requests,delete_requests,temporary_present,final_bytes)={let saved=counts.upload.lock().unwrap();
        (saved.operations.iter().filter(|&&v|v==18).count(),saved.operations.iter().filter(|&&v|v==13||v==15).count(),saved.temporary.is_some(),saved.final_file.as_ref().map(|v|v.len()as i64).unwrap_or(-1))};
    #[cfg(not(feature="upload-qualification"))]let(rename_requests,delete_requests,temporary_present,final_bytes)=(0,0,false,-1);
    #[cfg(not(feature="upload-qualification"))]let(upload_length,upload_digest,upload_operations)=(0,String::new(),0);
    println!("{{\"ended\":true,\"authCalls\":{},\"keyOffers\":{},\"interactiveCalls\":{},\"requests\":{},\"closes\":{},\"fileReadRequests\":{},\"uploadPublishedLengthPlusOne\":{},\"uploadFinalSHA256\":\"{}\",\"uploadOperations\":{},\"fixtureTasksJoined\":{},\"fixtureTasksAborted\":0,\"runtimeTasksAfter\":0}}",
        counts.auth.load(Ordering::SeqCst),counts.key_offers.load(Ordering::SeqCst),counts.interactive_calls.load(Ordering::SeqCst),counts.requests.load(Ordering::SeqCst),counts.closes.load(Ordering::SeqCst),counts.file_reads.load(Ordering::SeqCst),upload_length,upload_digest,upload_operations,counts.tasks_joined.load(Ordering::SeqCst));
    println!("{{\"exclusiveObservation\":true,\"renameRequests\":{rename_requests},\"deleteRequests\":{delete_requests},\"temporaryPresent\":{temporary_present},\"finalBytes\":{final_bytes}}}");
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    if fresh{println!("{}",ssh_fixture::fresh_upload::observation(&counts.fresh_upload.lock().unwrap()));}
}
