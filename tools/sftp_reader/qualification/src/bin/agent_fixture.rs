//! One generated loopback SSH server and one generated Unix agent. Never bundled.
#![deny(warnings)]
#[allow(dead_code)]mod ssh_fixture;
use std::{fs,io::Write,os::unix::{ffi::OsStrExt,fs::{MetadataExt,PermissionsExt}},path::PathBuf,
    sync::{Arc,mpsc,atomic::Ordering},time::Duration};
use russh::keys::{Algorithm,HashAlg,PrivateKey,signature::Signer as _,ssh_encoding::Encode};
use tokio::{io::{AsyncReadExt,AsyncWriteExt},net::{UnixListener,UnixStream},time::timeout};

const MAX_FRAME:usize=65_536;
unsafe extern "C" { fn geteuid()->u32; }
fn read_string<'a>(bytes:&'a[u8],at:&mut usize,max:usize)->Option<&'a[u8]>{
    let header=bytes.get(*at..at.checked_add(4)?)?;
    let size=u32::from_be_bytes(header.try_into().ok()?)as usize;
    if size>max{return None}*at+=4;
    let body=bytes.get(*at..at.checked_add(size)?)?;*at+=size;Some(body)
}
fn append_string(target:&mut Vec<u8>,value:&[u8]){
    target.extend((value.len()as u32).to_be_bytes());target.extend(value);
}
async fn read_frame(socket:&mut UnixStream)->Option<Vec<u8>>{
    let mut header=[0u8;4];timeout(Duration::from_secs(35),socket.read_exact(&mut header)).await.ok()?.ok()?;
    let size=u32::from_be_bytes(header)as usize;if size==0||size>MAX_FRAME{return None}
    let mut body=vec![0;size];timeout(Duration::from_secs(5),socket.read_exact(&mut body)).await.ok()?.ok()?;Some(body)
}
async fn send_frame(socket:&mut UnixStream,body:&[u8])->bool{
    timeout(Duration::from_secs(5),async{
        socket.write_all(&(body.len()as u32).to_be_bytes()).await?;
        socket.write_all(body).await
    }).await.is_ok_and(|result|result.is_ok())
}
fn socket_path()->PathBuf{
    let mut args=std::env::args_os().skip(1);
    assert_eq!(args.next().as_deref(),Some(std::ffi::OsStr::new("--socket")));
    let path=PathBuf::from(args.next().expect("generated socket path required"));
    assert!(args.next().is_none()&&path.is_absolute()&&path.as_os_str().as_bytes().len()<=103);
    let name=path.file_name().unwrap().to_str().unwrap();
    assert!(name.starts_with("agent-")&&name.ends_with(".sock")&&name.len()==27
        &&name[6..22].bytes().all(|byte|byte.is_ascii_hexdigit()&&!byte.is_ascii_uppercase()));
    let parent=path.parent().unwrap();
    assert_eq!(parent.file_name().unwrap(),"agent-qa");
    assert_eq!(parent.parent().unwrap().file_name().unwrap(),".build");
    let repo=PathBuf::from(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().to_path_buf();
    assert_eq!(parent.parent().unwrap(),repo.join(".build"));
    let facts=fs::symlink_metadata(parent).unwrap();
    assert!(facts.is_dir()&&!facts.file_type().is_symlink()&&facts.uid()==unsafe{geteuid()}
        &&facts.permissions().mode()&0o777==0o700);
    assert!(fs::symlink_metadata(&path).is_err());
    path
}
#[tokio::main(flavor="current_thread")]
async fn main(){
    let path=socket_path();
    let private=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
    let public=private.public_key().clone();let blob=public.to_bytes().unwrap();
    let agent_fingerprint=public.fingerprint(HashAlg::Sha256);
    let listener=UnixListener::bind(&path).unwrap();
    fs::set_permissions(&path,fs::Permissions::from_mode(0o600)).unwrap();
    let counts=Arc::new(ssh_fixture::Counts::default());
    let(tx,rx)=mpsc::sync_channel(1);
    let server_counts=counts.clone();
    let server=std::thread::spawn(move||ssh_fixture::key_fixture("agent-qa-first".into(),public,server_counts,tx));
    let(port,host_key)=rx.recv_timeout(Duration::from_secs(5)).unwrap();
    println!("{{\"ready\":true,\"port\":{},\"hostFingerprint\":\"{}\",\"agentFingerprint\":\"{}\"}}",
        port.port(),host_key.fingerprint(),agent_fingerprint);
    std::io::stdout().flush().unwrap();
    let(mut socket,_)=timeout(Duration::from_secs(60),listener.accept()).await.unwrap().unwrap();
    let mut listed=0u8;let mut signed=0u8;
    while let Some(request)=read_frame(&mut socket).await{
        match request.as_slice(){
            [11] if listed==0=>{
                let mut reply=vec![12];reply.extend(1u32.to_be_bytes());
                append_string(&mut reply,&blob);append_string(&mut reply,b"generated");
                assert!(send_frame(&mut socket,&reply).await);listed=1;
            },
            [13,..] if listed==1&&signed<2=>{
                let mut at=1usize;
                let selected=read_string(&request,&mut at,8192).unwrap();
                let data=read_string(&request,&mut at,32768).unwrap();
                let flags=request.get(at..at+4).unwrap();
                assert_eq!(selected,blob);assert_eq!(flags,[0,0,0,0]);assert_eq!(at+4,request.len());
                let signature=private.try_sign(data).unwrap();let mut encoded=Vec::new();
                signature.encode(&mut encoded).unwrap();
                let mut reply=vec![14];append_string(&mut reply,&encoded);
                assert!(send_frame(&mut socket,&reply).await);signed+=1;
            },
            _=>panic!("Unexpected generated agent protocol command"),
        }
    }
    drop(socket);drop(listener);
    tokio::task::spawn_blocking(move||server.join().unwrap()).await.unwrap();
    println!("{{\"ended\":true,\"agentLists\":{},\"agentSigns\":{},\"sshAuthCalls\":{},\"serverEnded\":{}}}",
        listed,signed,counts.auth.load(Ordering::SeqCst),counts.socket_ended.load(Ordering::SeqCst)==1);
}
