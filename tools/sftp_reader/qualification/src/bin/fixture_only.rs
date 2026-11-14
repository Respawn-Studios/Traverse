//! Ephemeral generated loopback peer for the exact owned worker qualification.
#[allow(dead_code)]mod ssh_fixture;
use ssh_fixture::{Counts,fixture};
use std::{io::Write,sync::{Arc,mpsc,atomic::Ordering},time::{Duration,Instant}};
fn main(){
    let scenario=std::env::args().nth(1).unwrap_or_default();
    let normal=["first","cancel-host","read-stop","large-directory","review-delay","saved-sequence","workspace-sequence","browser","concurrent","idle-healthy","idle-drop","directory-recovery"].contains(&scenario.as_str());
    let transfer=cfg!(feature="download-qualification")&&["transfer-good","transfer-empty","transfer-changed","transfer-denied","transfer-stop","transfer-lost-close","transfer-wrong-id"].contains(&scenario.as_str());
    let upload=cfg!(feature="upload-qualification")&&["push-good","push-empty","push-conflict","push-stop-write","push-lost-rename"].contains(&scenario.as_str());
    assert!(normal||transfer||upload);
    let counts=Arc::new(Counts::default());let(tx,rx)=mpsc::sync_channel(1);let observed=counts.clone();
    let fixture_scenario=scenario.clone();let task=std::thread::spawn(move||fixture(fixture_scenario,observed,tx));
    let(address,key)=rx.recv_timeout(Duration::from_secs(2)).unwrap();
    let key=key.bytes().iter().map(|b|format!("{b:02x}")).collect::<String>();
    println!("{{\"ready\":true,\"port\":{},\"generatedPublicKey\":\"{key}\"}}",address.port());
    std::io::stdout().flush().unwrap();
    if scenario=="read-stop"{
        let began=Instant::now();while counts.requests.load(Ordering::SeqCst)<4{
            assert!(began.elapsed()<Duration::from_secs(3));std::thread::sleep(Duration::from_millis(2));
        }
        println!("{{\"readPending\":true}}");std::io::stdout().flush().unwrap();
    }
    if scenario=="transfer-stop"||scenario=="transfer-lost-close"{
        let began=Instant::now();while if scenario=="transfer-stop"{counts.file_reads.load(Ordering::SeqCst)==0}else{counts.closes.load(Ordering::SeqCst)<2}{
            assert!(began.elapsed()<Duration::from_secs(5));std::thread::sleep(Duration::from_millis(2));
        }
        println!("{{\"transferPending\":true}}");std::io::stdout().flush().unwrap();
    }
    #[cfg(feature="upload-qualification")]
    if scenario=="push-stop-write"{
        let began=Instant::now();while counts.upload_waiting.load(Ordering::Acquire)==0{
            assert!(began.elapsed()<Duration::from_secs(5));std::thread::sleep(Duration::from_millis(2));
        }
        println!("{{\"uploadPending\":true}}");std::io::stdout().flush().unwrap();
    }
    task.join().expect("Generated peer did not complete");
    assert_eq!(counts.socket_ended.load(Ordering::SeqCst),if scenario=="workspace-sequence"{4}else if scenario=="saved-sequence"{3}else if scenario=="concurrent"{2}else{1});assert_eq!(counts.tasks_aborted.load(Ordering::SeqCst),0);
    assert_eq!(counts.unexpected_auth.load(Ordering::SeqCst),0);
    #[cfg(feature="upload-qualification")]
    if upload{
        use sha2::{Digest,Sha256};
        let value=counts.upload.lock().unwrap();
        let digest=|bytes:&Option<Vec<u8>>|bytes.as_ref().map(|b|Sha256::digest(b).iter().map(|v|format!("{v:02x}")).collect::<String>()).unwrap_or_default();
        println!("{{\"uploadObserved\":true,\"temporaryExists\":{},\"temporaryBytes\":{},\"temporaryDigest\":\"{}\",\"finalExists\":{},\"finalBytes\":{},\"finalDigest\":\"{}\",\"renameRequests\":{},\"removeRequests\":0}}",
            value.temporary.is_some(),value.temporary.as_ref().map_or(0,Vec::len),digest(&value.temporary),value.final_file.is_some(),value.final_file.as_ref().map_or(0,Vec::len),digest(&value.final_file),value.operations.iter().filter(|&&v|v==18).count());
    }
    println!("{{\"ended\":true,\"authCalls\":{},\"requests\":{},\"closes\":{},\"fixtureTasksJoined\":{},\"fixtureTasksAborted\":0}}",
        counts.auth.load(Ordering::SeqCst),counts.requests.load(Ordering::SeqCst),counts.closes.load(Ordering::SeqCst),counts.tasks_joined.load(Ordering::SeqCst));
}
