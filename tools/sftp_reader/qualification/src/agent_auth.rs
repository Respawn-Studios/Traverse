//! Explicit selected-key SSH-agent signing. This module has no environment,
//! config, key-file, forwarding, add/remove, or fallback path.
#![deny(warnings)]
use std::{fmt,fs,os::unix::{ffi::OsStrExt,fs::{FileTypeExt,MetadataExt,PermissionsExt}},path::Path,time::Duration};
use russh::{SendError,Signer,keys::{self,Algorithm,HashAlg,PublicKey,ssh_key::Signature}};
use russh::keys::ssh_encoding::{Decode,Encode};
use ring::digest::{digest,SHA256};
use tokio::{io::{AsyncReadExt,AsyncWriteExt},net::UnixStream,time::timeout};

const MAX_FRAME:usize=65_536;
const MAX_IDENTITIES:u32=16;
const MAX_BLOB:usize=8_192;
const MAX_COMMENT:usize=256;
const MAX_TO_SIGN:usize=32_768;
const MAX_SOCKET_PATH:usize=103;
unsafe extern "C" { fn geteuid()->u32; }

/// The IPC qualification mode accepts only the generated fixture's owned
/// socket under this repository. An arbitrary explicit path must never let
/// this signed QA helper enumerate a personal SSH agent.
pub fn require_generated_socket(path:&Path)->Result<(),Failure>{
    let repo=Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).ok_or(Failure::Input)?;
    let root=repo.join(".build/agent-qa");
    if path.parent()!=Some(root.as_path())||path.as_os_str().as_bytes().len()>MAX_SOCKET_PATH{
        return Err(Failure::Input)
    }
    let name=path.file_name().and_then(|value|value.to_str()).ok_or(Failure::Input)?;
    if name.len()!=27||!name.starts_with("agent-")||!name.ends_with(".sock")
        ||!name[6..22].bytes().all(|value|value.is_ascii_hexdigit()&&!value.is_ascii_uppercase()){
        return Err(Failure::Input)
    }
    for directory in [repo.join(".build"),root]{
        let facts=fs::symlink_metadata(&directory).map_err(socket_error)?;
        if !facts.is_dir()||facts.file_type().is_symlink()||facts.uid()!=unsafe{geteuid()}{
            return Err(Failure::Denied)
        }
        if directory.file_name().is_some_and(|value|value=="agent-qa")
            &&facts.permissions().mode()&0o777!=0o700{return Err(Failure::Denied)}
    }
    let facts=fs::symlink_metadata(path).map_err(socket_error)?;
    if !facts.file_type().is_socket()||facts.uid()!=unsafe{geteuid()}
        ||facts.permissions().mode()&0o077!=0{return Err(Failure::Denied)}
    Ok(())
}

#[derive(Clone,Copy,PartialEq,Eq)]
pub enum Failure{Input,Socket,Denied,Protocol,Identity,Algorithm,Signature,Timeout,Closed}
impl fmt::Debug for Failure{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{f.write_str("<SSH agent could not be used>")}}
impl From<SendError> for Failure{fn from(_:SendError)->Self{Self::Closed}}

/// The worker retains the listed canonical blobs. The parent sees only bounded
/// algorithm labels and SHA-256 digests, and selects exactly one listed digest.
pub struct IdentitySummary { pub digest:[u8;32],pub algorithm:String }
struct ListedIdentity { public:PublicKey,blob:Vec<u8>,summary:IdentitySummary }
pub struct AgentCatalog { socket:UnixStream,identities:Vec<ListedIdentity> }
impl fmt::Debug for AgentCatalog{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{f.write_str("<SSH agent identity catalog>")}}
impl AgentCatalog {
    pub async fn connect(path:&Path,deadline:Duration)->Result<Self,Failure>{
        let path_bytes=path.as_os_str().as_bytes();
        if !path.is_absolute()||path_bytes.is_empty()||path_bytes.len()>MAX_SOCKET_PATH
            ||path_bytes.contains(&0)||deadline.is_zero()||deadline>Duration::from_secs(60){return Err(Failure::Input)}
        let metadata=std::fs::symlink_metadata(path).map_err(socket_error)?;
        if !metadata.file_type().is_socket(){return Err(Failure::Socket)}
        let mut socket=timeout(deadline,UnixStream::connect(path)).await.map_err(|_|Failure::Timeout)?
            .map_err(socket_error)?;
        let response=exchange(&mut socket,&[11],deadline).await?;
        let mut cursor=Cursor::new(&response);
        if cursor.byte()!=Some(12){return Err(Failure::Protocol)}
        let count=cursor.number().ok_or(Failure::Protocol)?;
        if count==0||count>MAX_IDENTITIES{return Err(Failure::Identity)}
        let mut identities:Vec<ListedIdentity>=Vec::with_capacity(count as usize);
        for _ in 0..count{
            let blob=cursor.string(MAX_BLOB).ok_or(Failure::Protocol)?;
            let _comment=cursor.string(MAX_COMMENT).ok_or(Failure::Protocol)?;
            let public=PublicKey::from_bytes(blob).map_err(|_|Failure::Protocol)?;
            if public.to_bytes().map_err(|_|Failure::Protocol)?!=blob{return Err(Failure::Protocol)}
            if admitted(&public).is_err(){continue}
            let mut key_digest=[0u8;32];key_digest.copy_from_slice(digest(&SHA256,blob).as_ref());
            if identities.iter().any(|entry|entry.summary.digest==key_digest){return Err(Failure::Identity)}
            let algorithm=public.algorithm().to_string();
            if algorithm.len()>48{return Err(Failure::Algorithm)}
            identities.push(ListedIdentity{public,blob:blob.to_vec(),
                summary:IdentitySummary{digest:key_digest,algorithm}});
        }
        if !cursor.empty()||identities.is_empty(){return Err(Failure::Identity)}
        Ok(Self{socket,identities})
    }
    pub fn summaries(&self)->Vec<IdentitySummary>{
        self.identities.iter().map(|entry|IdentitySummary{
            digest:entry.summary.digest,algorithm:entry.summary.algorithm.clone()}).collect()
    }
    pub fn select(mut self,key_digest:[u8;32],deadline:Duration)->Result<SelectedAgent,Failure>{
        if deadline.is_zero()||deadline>Duration::from_secs(60){return Err(Failure::Input)}
        let index=self.identities.iter().position(|entry|entry.summary.digest==key_digest)
            .ok_or(Failure::Identity)?;
        let selected=self.identities.swap_remove(index);
        Ok(SelectedAgent{socket:self.socket,public:selected.public,blob:selected.blob,
            deadline,signatures:0,usable:true})
    }
}

/// One exact, user-selected public key from the already listed Unix socket.
pub struct SelectedAgent{
    socket:UnixStream,public:PublicKey,blob:Vec<u8>,deadline:Duration,
    signatures:u8,usable:bool,
}
impl fmt::Debug for SelectedAgent{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{f.write_str("<selected SSH agent identity>")}}

impl SelectedAgent{
    pub async fn connect(path:&Path,expected_blob:&[u8],deadline:Duration)->Result<Self,Failure>{
        if expected_blob.is_empty()||expected_blob.len()>MAX_BLOB
            ||deadline.is_zero()||deadline>Duration::from_secs(60){return Err(Failure::Input)}
        let expected=PublicKey::from_bytes(expected_blob).map_err(|_|Failure::Identity)?;
        admitted(&expected)?;
        if expected.to_bytes().map_err(|_|Failure::Identity)?!=expected_blob{return Err(Failure::Identity)}
        let catalog=AgentCatalog::connect(path,deadline).await?;
        let mut key_digest=[0u8;32];key_digest.copy_from_slice(digest(&SHA256,expected_blob).as_ref());
        let selected=catalog.select(key_digest,deadline)?;
        if selected.public!=expected||selected.blob!=expected_blob{return Err(Failure::Identity)}
        Ok(selected)
    }
    pub fn public(&self)->&PublicKey{&self.public}

    async fn exchange(&mut self,request:&[u8])->Result<Vec<u8>,Failure>{
        exchange(&mut self.socket,request,self.deadline).await
    }

    async fn sign(&mut self,data:&[u8],hash:Option<HashAlg>)->Result<Signature,Failure>{
        if !self.usable||self.signatures>=2{return Err(Failure::Closed)}
        self.usable=false;
        self.signatures+=1;
        if data.is_empty()||data.len()>MAX_TO_SIGN{return Err(Failure::Input)}
        let flags=match self.public.algorithm(){
            Algorithm::Rsa{..}=>match hash{Some(HashAlg::Sha256)=>2u32,Some(HashAlg::Sha512)=>4,_=>return Err(Failure::Algorithm)},
            _ if hash.is_none()=>0,
            _=>return Err(Failure::Algorithm),
        };
        let mut request=vec![13u8];
        put_string(&mut request,&self.blob)?;
        put_string(&mut request,data)?;
        request.extend(flags.to_be_bytes());
        let response=self.exchange(&request).await?;
        let mut cursor=Cursor::new(&response);
        if cursor.byte()!=Some(14){return Err(Failure::Protocol)}
        let encoded=cursor.string(MAX_BLOB).ok_or(Failure::Protocol)?;
        if !cursor.empty(){return Err(Failure::Protocol)}
        let mut slice=encoded;
        let signature=Signature::decode(&mut slice).map_err(|_|Failure::Signature)?;
        if !slice.is_empty(){return Err(Failure::Signature)}
        let required=match self.public.algorithm(){Algorithm::Rsa{..}=>Algorithm::Rsa{hash},algorithm=>algorithm};
        if signature.algorithm()!=required{return Err(Failure::Algorithm)}
        if matches!(required,Algorithm::SkEd25519|Algorithm::SkEcdsaSha2NistP256){
            let bytes=signature.as_bytes();
            if bytes.len()<5||bytes[bytes.len()-5]&1==0{return Err(Failure::Signature)}
        }
        keys::signature::Verifier::verify(&self.public,data,&signature).map_err(|_|Failure::Signature)?;
        self.usable=true;
        Ok(signature)
    }
}

async fn exchange(socket:&mut UnixStream,request:&[u8],deadline:Duration)->Result<Vec<u8>,Failure>{
    if request.is_empty()||request.len()>MAX_FRAME{return Err(Failure::Input)}
    timeout(deadline,async{
        socket.write_all(&(request.len()as u32).to_be_bytes()).await.map_err(|_|Failure::Socket)?;
        socket.write_all(request).await.map_err(|_|Failure::Socket)?;
        socket.flush().await.map_err(|_|Failure::Socket)?;
        let mut size=[0u8;4];
        socket.read_exact(&mut size).await.map_err(|_|Failure::Socket)?;
        let size=u32::from_be_bytes(size)as usize;
        if size==0||size>MAX_FRAME{return Err(Failure::Protocol)}
        let mut response=vec![0u8;size];
        socket.read_exact(&mut response).await.map_err(|_|Failure::Socket)?;
        Ok(response)
    }).await.map_err(|_|Failure::Timeout)?
}
fn socket_error(error:std::io::Error)->Failure{
    if error.kind()==std::io::ErrorKind::PermissionDenied{Failure::Denied}else{Failure::Socket}
}

impl Signer for SelectedAgent{
    type Error=Failure;
    async fn auth_sign(&mut self,identity:&keys::agent::AgentIdentity,hash:Option<HashAlg>,mut data:Vec<u8>)->Result<Vec<u8>,Failure>{
        match identity{keys::agent::AgentIdentity::PublicKey{key,..}if key==&self.public=>{},_=>return Err(Failure::Identity)}
        let signature=self.sign(&data,hash).await?;
        let mut encoded=Vec::new();
        signature.encode(&mut encoded).map_err(|_|Failure::Signature)?;
        data.extend((encoded.len()as u32).to_be_bytes());
        data.extend(encoded);
        Ok(data)
    }
}

fn admitted(public:&PublicKey)->Result<(),Failure>{
    match public.algorithm(){
        Algorithm::Ed25519|Algorithm::Ecdsa{..}|Algorithm::SkEd25519|Algorithm::SkEcdsaSha2NistP256=>Ok(()),
        Algorithm::Rsa{..}=>crate::key_auth::admitted_public(public).map_err(|_|Failure::Algorithm),
        _=>Err(Failure::Algorithm),
    }
}
fn put_string(target:&mut Vec<u8>,data:&[u8])->Result<(),Failure>{
    if data.len()>MAX_FRAME{return Err(Failure::Input)}
    target.extend((data.len()as u32).to_be_bytes());target.extend(data);Ok(())
}
struct Cursor<'a>{source:&'a[u8],offset:usize}
impl<'a> Cursor<'a>{
    fn new(source:&'a[u8])->Self{Self{source,offset:0}}
    fn byte(&mut self)->Option<u8>{let value=*self.source.get(self.offset)?;self.offset+=1;Some(value)}
    fn number(&mut self)->Option<u32>{let bytes=self.source.get(self.offset..self.offset.checked_add(4)?)?;
        self.offset+=4;Some(u32::from_be_bytes(bytes.try_into().ok()?))}
    fn string(&mut self,max:usize)->Option<&'a[u8]>{let length=self.number()?as usize;
        if length>max{return None}let end=self.offset.checked_add(length)?;
        let bytes=self.source.get(self.offset..end)?;self.offset=end;Some(bytes)}
    fn empty(&self)->bool{self.offset==self.source.len()}
}

#[cfg(test)]mod tests{
    use super::*;
    use std::{fs,os::unix::fs::{symlink,PermissionsExt},path::PathBuf,sync::{Arc,atomic::{AtomicU64,Ordering}}};
    use russh::{server,keys::{PrivateKey,signature::Signer as _}};
    use tokio::{net::{TcpListener,UnixListener},sync::mpsc};

    struct GeneratedServer{public:PublicKey}
    impl server::Handler for GeneratedServer{
        type Error=russh::Error;
        async fn auth_publickey_offered(&mut self,user:&str,key:server::PublicKeyOffer<'_>)->Result<server::Auth,Self::Error>{
            Ok(if user=="generated"&&key.public_key==&self.public{server::Auth::Accept}else{server::Auth::reject()})
        }
        async fn auth_publickey(&mut self,user:&str,key:server::VerifiedPublicKey<'_>)->Result<server::Auth,Self::Error>{
            Ok(if user=="generated"&&key.public_key==&self.public{server::Auth::Accept}else{server::Auth::reject()})
        }
    }

    fn path()->PathBuf{
        static NEXT:AtomicU64=AtomicU64::new(0);
        let repo=Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap();
        let root=repo.join(".build/agent-qa");fs::create_dir_all(&root).unwrap();
        root.join(format!("agent-{}-{}.sock",std::process::id(),NEXT.fetch_add(1,Ordering::Relaxed)))
    }
    #[tokio::test]async fn generated_worker_socket_must_be_owned_private_and_exactly_named(){
        static NEXT:AtomicU64=AtomicU64::new(0);
        let repo=Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap();
        let root=repo.join(".build/agent-qa");fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root,fs::Permissions::from_mode(0o700)).unwrap();
        let number=((std::process::id()as u64)<<32)|NEXT.fetch_add(1,Ordering::Relaxed);
        let socket=root.join(format!("agent-{number:016x}.sock"));
        let listener=UnixListener::bind(&socket).unwrap();
        fs::set_permissions(&socket,fs::Permissions::from_mode(0o600)).unwrap();
        assert!(require_generated_socket(&socket).is_ok());
        assert!(matches!(require_generated_socket(&root.join("personal.sock")),Err(Failure::Input)));
        assert!(matches!(require_generated_socket(&repo.join(".build/personal.sock")),Err(Failure::Input)));
        let alias=root.join(format!("agent-{:016x}.sock",number+1));
        symlink(&socket,&alias).unwrap();
        assert!(matches!(require_generated_socket(&alias),Err(Failure::Denied)));
        fs::remove_file(&alias).unwrap();drop(listener);fs::remove_file(&socket).unwrap();
    }
    async fn frame(socket:&mut UnixStream)->Vec<u8>{
        let mut size=[0u8;4];socket.read_exact(&mut size).await.unwrap();
        let size=u32::from_be_bytes(size)as usize;assert!(size<=MAX_FRAME);
        let mut body=vec![0;size];socket.read_exact(&mut body).await.unwrap();body
    }
    async fn reply(socket:&mut UnixStream,body:&[u8]){
        socket.write_all(&(body.len()as u32).to_be_bytes()).await.unwrap();socket.write_all(body).await.unwrap();
    }
    #[tokio::test]async fn exact_generated_agent_identity_and_signature(){
        let key=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let public=key.public_key().clone();let blob=public.to_bytes().unwrap();
        let path=path();assert!(path.as_os_str().as_bytes().len()<=MAX_SOCKET_PATH);
        let listener=UnixListener::bind(&path).unwrap();
        let server=tokio::spawn({let blob=blob.clone();async move{
            let(mut socket,_)=listener.accept().await.unwrap();
            assert_eq!(frame(&mut socket).await,vec![11]);
            let mut identities=vec![12];identities.extend(1u32.to_be_bytes());
            put_string(&mut identities,&blob).unwrap();put_string(&mut identities,b"generated").unwrap();
            reply(&mut socket,&identities).await;
            let signed=frame(&mut socket).await;let mut cursor=Cursor::new(&signed);
            assert_eq!(cursor.byte(),Some(13));assert_eq!(cursor.string(MAX_BLOB),Some(blob.as_slice()));
            let data=cursor.string(MAX_TO_SIGN).unwrap();assert_eq!(data,b"generated SSH auth data");
            assert_eq!(cursor.number(),Some(0));assert!(cursor.empty());
            let signature=key.try_sign(data).unwrap();let mut encoded=Vec::new();signature.encode(&mut encoded).unwrap();
            let mut response=vec![14];put_string(&mut response,&encoded).unwrap();reply(&mut socket,&response).await;
        }});
        let mut agent=SelectedAgent::connect(&path,&blob,Duration::from_secs(5)).await.unwrap();
        assert_eq!(agent.public(),&public);
        let identity=keys::agent::AgentIdentity::PublicKey{key:public,comment:String::new()};
        let signed=agent.auth_sign(&identity,None,b"generated SSH auth data".to_vec()).await.unwrap();
        assert!(signed.starts_with(b"generated SSH auth data"));
        server.await.unwrap();fs::remove_file(&path).unwrap();
    }
    #[tokio::test]async fn rejects_ambient_and_non_socket(){
        let key=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let blob=key.public_key().to_bytes().unwrap();
        assert!(matches!(SelectedAgent::connect(Path::new("relative.sock"),&blob,Duration::from_secs(5)).await,Err(Failure::Input)));
        let path=path();fs::write(&path,b"not a socket").unwrap();
        assert!(matches!(SelectedAgent::connect(&path,&blob,Duration::from_secs(5)).await,Err(Failure::Socket)));
        fs::remove_file(&path).unwrap();
    }
    #[tokio::test]async fn rejects_wrong_signature_and_disables_reuse(){
        let selected=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let other=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let public=selected.public_key().clone();let blob=public.to_bytes().unwrap();
        let path=path();let listener=UnixListener::bind(&path).unwrap();
        let server=tokio::spawn({let blob=blob.clone();async move{
            let(mut socket,_)=listener.accept().await.unwrap();assert_eq!(frame(&mut socket).await,vec![11]);
            let mut identities=vec![12];identities.extend(1u32.to_be_bytes());
            put_string(&mut identities,&blob).unwrap();put_string(&mut identities,b"generated").unwrap();
            reply(&mut socket,&identities).await;
            let signed=frame(&mut socket).await;let mut cursor=Cursor::new(&signed);
            assert_eq!(cursor.byte(),Some(13));assert_eq!(cursor.string(MAX_BLOB),Some(blob.as_slice()));
            let data=cursor.string(MAX_TO_SIGN).unwrap();assert_eq!(cursor.number(),Some(0));assert!(cursor.empty());
            let signature=other.try_sign(data).unwrap();let mut encoded=Vec::new();signature.encode(&mut encoded).unwrap();
            let mut response=vec![14];put_string(&mut response,&encoded).unwrap();reply(&mut socket,&response).await;
        }});
        let mut agent=SelectedAgent::connect(&path,&blob,Duration::from_secs(5)).await.unwrap();
        let identity=keys::agent::AgentIdentity::PublicKey{key:public,comment:String::new()};
        assert!(matches!(agent.auth_sign(&identity,None,b"generated SSH auth data".to_vec()).await,Err(Failure::Signature)));
        assert!(matches!(agent.auth_sign(&identity,None,b"generated SSH auth data".to_vec()).await,Err(Failure::Closed)));
        server.await.unwrap();fs::remove_file(&path).unwrap();
    }
    #[tokio::test]async fn generated_ssh_server_accepts_only_selected_agent_signature(){
        let key=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let public=key.public_key().clone();let blob=public.to_bytes().unwrap();
        let path=path();let listener=UnixListener::bind(&path).unwrap();
        let agent_server=tokio::spawn({let blob=blob.clone();async move{
            let(mut socket,_)=listener.accept().await.unwrap();assert_eq!(frame(&mut socket).await,vec![11]);
            let mut identities=vec![12];identities.extend(1u32.to_be_bytes());
            put_string(&mut identities,&blob).unwrap();put_string(&mut identities,b"generated").unwrap();
            reply(&mut socket,&identities).await;
            let signed=frame(&mut socket).await;let mut cursor=Cursor::new(&signed);
            assert_eq!(cursor.byte(),Some(13));assert_eq!(cursor.string(MAX_BLOB),Some(blob.as_slice()));
            let data=cursor.string(MAX_TO_SIGN).unwrap();assert_eq!(cursor.number(),Some(0));assert!(cursor.empty());
            let signature=key.try_sign(data).unwrap();let mut encoded=Vec::new();signature.encode(&mut encoded).unwrap();
            let mut response=vec![14];put_string(&mut response,&encoded).unwrap();reply(&mut socket,&response).await;
        }});
        let host=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let ssh_listener=TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await.unwrap();
        let address=ssh_listener.local_addr().unwrap();
        let ssh_server=tokio::spawn(async move{
            let(stream,_)=ssh_listener.accept().await.unwrap();
            let config=server::Config{keys:vec![host],auth_rejection_time:Duration::ZERO,
                auth_rejection_time_initial:Some(Duration::ZERO),inactivity_timeout:Some(Duration::from_secs(5)),
                preferred:crate::ssh::modern_preferences(),..Default::default()};
            let session=server::run_stream(Arc::new(config),stream,GeneratedServer{public}).await.unwrap();
            let _=timeout(Duration::from_secs(5),session).await.unwrap();
        });
        let (sender,mut requests)=mpsc::channel(1);
        let peer=crate::ssh::Peer::new("127.0.0.1",address.port(),[7;16]).unwrap();
        let connecting=tokio::spawn(async move{
            crate::ssh::Verified::connect(peer,address,None,sender,Duration::from_secs(5)).await
        });
        let request=timeout(Duration::from_secs(5),requests.recv()).await.unwrap().unwrap();
        assert!(request.reply.send(crate::ssh::Decision{challenge:request.challenge,
            action:crate::ssh::Action::ConnectOnce}).is_ok());
        let mut verified=connecting.await.unwrap().unwrap();
        let result=verified.agent_identity_then_interactive("generated",&path,&blob,Duration::from_secs(5),false).await.unwrap();
        assert!(matches!(result,crate::ssh::AgentAuthentication::Complete(_)));
        let drained=verified.close().await.unwrap();assert!(drained.ssh_task_ended);
        agent_server.await.unwrap();ssh_server.await.unwrap();fs::remove_file(&path).unwrap();
    }
}
