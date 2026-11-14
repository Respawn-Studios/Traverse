//! Shared generated encrypted peer. Never an application server.
use macexplorer_sftp_reader_qualification::{ssh::Key,wire};
use russh::{server,keys::{Algorithm,PrivateKey},Channel,ChannelId,ChannelStream};
use std::{net::SocketAddr,sync::{Arc,Mutex,atomic::{AtomicUsize,Ordering},mpsc as std_mpsc},time::Duration};
use tokio::{io::{AsyncReadExt,AsyncWriteExt},net::TcpListener,task::JoinHandle};

#[derive(Default)]
pub struct Counts { pub auth:AtomicUsize, pub requests:AtomicUsize, pub closes:AtomicUsize, pub rejected:AtomicUsize,
    pub socket_ended:AtomicUsize, pub tasks_joined:AtomicUsize, pub tasks_aborted:AtomicUsize, pub credential_lookups:AtomicUsize,
    pub ssh_ended_normally:AtomicUsize, pub disconnect_queued:AtomicUsize,pub unexpected_auth:AtomicUsize,
    #[cfg(feature="folder-download-qualification")]pub folder:Mutex<folder::State>,
    #[cfg(feature="folder-download-qualification")]pub folder_waiting:AtomicUsize,
    pub file_reads:AtomicUsize,pub key_offers:AtomicUsize,pub interactive_calls:AtomicUsize,
    #[cfg(feature="upload-qualification")]pub upload:Mutex<upload::Observed>,
    #[cfg(feature="upload-qualification")]pub upload_published:AtomicUsize,
    #[cfg(feature="upload-qualification")]pub upload_waiting:AtomicUsize,
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]pub fresh_upload:Mutex<fresh_upload::Seen> }
type Tasks=Arc<Mutex<Vec<JoinHandle<()>>>>;
// Fixture-only composition: authentication remains on the SSH session, while
// subsequent SFTP channels get explicit metadata/body roles. No app routing.
fn operation_scenario(scenario:&str,channel:usize)->String{
    let operation=["key-auth-","mfa-key-auth-","interactive-auth-"].into_iter()
        .find_map(|prefix|scenario.strip_prefix(prefix)).unwrap_or(scenario);
    if operation=="folder-slow-body"&&channel==1{return "folder-slow-metadata".into()}
    if let Some(upload)=operation.strip_prefix("composed-"){
        return match channel{2=>"download-success".into(),3=>format!("upload-{upload}"),_=>"transfer-success".into()}
    }
    if operation.starts_with("fresh-"){return if channel==2{operation.into()}else{"transfer-success".into()}}
    if channel>1{
        if let Some(rest)=operation.strip_prefix("transfer-"){return format!("download-{rest}")}
        if let Some(rest)=operation.strip_prefix("push-"){return format!("upload-{rest}")}
    }
    operation.into()
}
#[cfg(feature="download-qualification")]
#[path="download.rs"]mod download;
#[cfg(feature="folder-download-qualification")]
#[path="folder.rs"]mod folder;
#[cfg(feature="upload-qualification")]
#[path="upload.rs"]pub mod upload;
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
#[path="fresh_upload.rs"]pub mod fresh_upload;
pub(crate) struct Fixture { scenario:String, counts:Arc<Counts>, tasks:Tasks,channels:usize,public_key:Option<russh::keys::PublicKey>,deny_key:bool,
    interactive_stage:u8,key_partial:bool }
impl Fixture{
    pub(crate) fn generated(scenario:&str,public_key:russh::keys::PublicKey,counts:Arc<Counts>,tasks:Tasks)->Self{
        Self{scenario:scenario.into(),counts,tasks,channels:0,public_key:Some(public_key),deny_key:false,interactive_stage:0,key_partial:false}
    }
}
impl server::Handler for Fixture {
    type Error=russh::Error;
    async fn auth_none(&mut self,_user:&str)->Result<server::Auth,russh::Error>{
        self.counts.unexpected_auth.fetch_add(1,Ordering::SeqCst);Ok(server::Auth::reject())
    }
    async fn auth_publickey_offered(&mut self,user:&str,key:&russh::keys::PublicKey)->Result<server::Auth,russh::Error>{
        if let Some(expected)=&self.public_key{
            self.counts.key_offers.fetch_add(1,Ordering::SeqCst);
            return Ok(if user=="generated"&&key==expected{server::Auth::Accept}else{server::Auth::reject()})
        }
        self.counts.unexpected_auth.fetch_add(1,Ordering::SeqCst);Ok(server::Auth::reject())
    }
    async fn auth_publickey(&mut self,user:&str,key:&russh::keys::PublicKey)->Result<server::Auth,russh::Error>{
        self.counts.auth.fetch_add(1,Ordering::SeqCst);
        if self.scenario.starts_with("mfa-key")&&user=="generated"&&self.public_key.as_ref()==Some(key){
            self.key_partial=true;return Ok(server::Auth::Reject{proceed_with_methods:Some((&[russh::MethodKind::KeyboardInteractive][..]).into()),partial_success:true})
        }
        Ok(if !self.deny_key&&user=="generated"&&self.public_key.as_ref()==Some(key){server::Auth::Accept}else{server::Auth::reject()})
    }
    async fn auth_keyboard_interactive<'a>(&'a mut self,user:&str,_submethods:&str,response:Option<server::Response<'a>>)->Result<server::Auth,russh::Error>{
        if !(self.scenario.starts_with("interactive-")||self.scenario.starts_with("mfa-key")){
            self.counts.unexpected_auth.fetch_add(1,Ordering::SeqCst);return Ok(server::Auth::reject())
        }
        self.counts.interactive_calls.fetch_add(1,Ordering::SeqCst);
        if user!="generated"||(self.scenario.starts_with("mfa-key")&&!self.key_partial){return Ok(server::Auth::reject())}
        let empty=self.scenario=="interactive-empty";
        let many=self.scenario=="interactive-round-limit";
        if let Some(values)=response{
            let values=values.take(9).map(|v|v.to_vec()).collect::<Vec<_>>();
            let expected=if empty{Vec::new()}else if many{vec![b"123456".to_vec()]}
                else if self.interactive_stage==0{vec![b"generated".to_vec(),b"123456".to_vec()]}else{vec![b"654321".to_vec()]};
            if values!=expected{return Ok(server::Auth::reject())}self.interactive_stage+=1;
            if empty||!many&&self.interactive_stage==2||many&&self.interactive_stage==9{return Ok(server::Auth::Accept)}
        }
        let prompts=if empty{Vec::new()}else if self.scenario=="interactive-prompt-limit"{vec![(std::borrow::Cow::Borrowed("Code"),false);9]}
            else if many{vec![(std::borrow::Cow::Borrowed("One-time code"),false)]}
            else if self.interactive_stage==0{vec![(std::borrow::Cow::Borrowed("Confirm account"),true),(std::borrow::Cow::Borrowed("One-time code"),false)]}
            else{vec![(std::borrow::Cow::Borrowed("Confirmation code"),false)]};
        Ok(server::Auth::Partial{name:std::borrow::Cow::Borrowed("Generated verification"),
            instructions:if self.scenario=="interactive-text-limit"{std::borrow::Cow::Owned("x".repeat(4097))}
                else{std::borrow::Cow::Borrowed("Generated server prompts only.\nResponses are not saved.")},prompts:std::borrow::Cow::Owned(prompts)})
    }
    async fn auth_password(&mut self,user:&str,password:&str)->Result<server::Auth,russh::Error>{
        self.counts.auth.fetch_add(1,Ordering::SeqCst);
        Ok(if user=="generated"&&password=="ephemeral qualification password"{server::Auth::Accept}else{server::Auth::reject()})
    }
    async fn channel_open_session(&mut self,channel:Channel<server::Msg>,reply:server::ChannelOpenHandle,
        session:&mut server::Session)->Result<(),russh::Error>{
        reply.accept().await;
        self.channels+=1;
        let counts=self.counts.clone();let scenario=operation_scenario(&self.scenario,self.channels);let handle=session.handle();
        let task=tokio::spawn(async move{serve(channel.into_stream(),scenario,counts,handle).await});
        self.tasks.lock().unwrap().push(task);Ok(())
    }
    async fn subsystem_request(&mut self,channel:ChannelId,name:&str,session:&mut server::Session)->Result<(),russh::Error>{
        if name!="sftp"{session.channel_failure(channel)?;return Ok(())}
        session.channel_success(channel)?;
        if self.scenario=="unsolicited"{
            let handle=session.handle();let counts=self.counts.clone();
            let task=tokio::spawn(async move{
                // Every supported unsolicited server-channel family is tested.
                assert!(handle.channel_open_agent().await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
                assert!(handle.channel_open_session().await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
                assert!(handle.channel_open_direct_tcpip("127.0.0.1",1,"127.0.0.1",1).await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
                assert!(handle.channel_open_direct_streamlocal("/generated-only-unused-socket").await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
                assert!(handle.channel_open_forwarded_tcpip("127.0.0.1",1,"127.0.0.1",1).await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
                assert!(handle.channel_open_forwarded_streamlocal("/generated-only-unused-socket").await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
                assert!(handle.channel_open_x11("127.0.0.1",1).await.is_err());counts.rejected.fetch_add(1,Ordering::SeqCst);
            });self.tasks.lock().unwrap().push(task);
        }Ok(())
    }
}
fn word(b:&mut Vec<u8>,v:u32){b.extend(v.to_be_bytes())}
fn text(b:&mut Vec<u8>,v:&[u8]){word(b,v.len()as u32);b.extend(v)}
fn head(kind:u8,id:u32)->Vec<u8>{let mut b=vec![kind];word(&mut b,id);b}
fn status(id:u32,code:u32)->Vec<u8>{let mut b=head(101,id);word(&mut b,code);text(&mut b,b"");text(&mut b,b"");b}
async fn serve(mut stream:ChannelStream<server::Msg>,scenario:String,counts:Arc<Counts>,handle:server::Handle){
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    if scenario.starts_with("fresh-"){fresh_upload::serve(stream,scenario,counts).await;return}
    #[cfg(feature="folder-download-qualification")]
    if scenario.starts_with("folder-"){folder::serve(stream,scenario,counts).await;return}
    #[cfg(feature="upload-qualification")]
    if scenario.starts_with("upload-"){upload::serve(stream,scenario,counts).await;return}
    #[cfg(feature="download-qualification")]
    if scenario.starts_with("download-"){download::serve(stream,scenario,counts).await;return}
    let mut sent_names=false;let mut ordinal=0usize;let mut current_path=String::new();
    loop{
        let Ok(length)=stream.read_u32().await else{return};assert!(length as usize<=wire::MAX_PACKET);
        let mut body=vec![0;length as usize];stream.read_exact(&mut body).await.unwrap();
        let request=wire::outgoing(&body).unwrap();let id=request.id.unwrap_or(0);
        counts.requests.fetch_add(1,Ordering::SeqCst);
        let reply=match request.kind{
            1=>vec![2,0,0,0,3],
            16 if scenario=="directory-recovery"&&&body[9..]==b"/missing-canonical"=>status(id,2),
            16=>{let mut b=head(104,id);word(&mut b,1);
                let requested=if scenario=="browser"||scenario=="directory-recovery"{std::str::from_utf8(&body[9..]).unwrap()}else{"."};
                let canonical=if requested=="."{"/generated".to_owned()}else if let Some(rest)=requested.strip_prefix("./"){format!("/generated/{rest}")}else{requested.to_owned()};
                text(&mut b,canonical.as_bytes());text(&mut b,b"");word(&mut b,0);b},
            11 if scenario=="directory-recovery"&&[b"/denied".as_slice(),b"/missing-open",b"/unavailable"].contains(&&body[9..])=>{
                status(id,if &body[9..]==b"/denied"{3}else if &body[9..]==b"/missing-open"{2}else{4})
            },
            11=>{ordinal=0;sent_names=false;current_path=String::from_utf8(body[9..].to_vec()).unwrap();let mut b=head(102,id);text(&mut b,&[0,255,3]);b},
            12 if scenario=="read-stop"=>{
                let mut byte=[0;1];let _=stream.read(&mut byte).await;return
            },
            12 if scenario=="disconnect-read"=>{
                handle.disconnect(russh::Disconnect::ByApplication,"Generated disconnect".into(),"".into()).await.unwrap();return
            },
            12 if (scenario=="large-directory"||scenario=="browser"&&current_path.ends_with("/Large"))&&ordinal<100000=>{
                let count=(100000-ordinal).min(256);let mut b=head(104,id);word(&mut b,count as u32);
                for index in ordinal..ordinal+count{let n=(index*48271)%100000;
                    text(&mut b,format!("Item {n}").as_bytes());text(&mut b,b"");word(&mut b,13);
                    b.extend(((n*17)as u64).to_be_bytes());word(&mut b,if n%10==0{0x41ed}else{0x81a4});word(&mut b,0);word(&mut b,(100000-n)as u32);
                }ordinal+=count;b
            },
            12 if scenario=="large-directory"||scenario=="browser"&&current_path.ends_with("/Large")=>status(id,1),
            12 if scenario.starts_with("transfer-")&&!sent_names=>{
                sent_names=true;let mut b=head(104,id);
                #[cfg(feature="upload-qualification")]let uploaded=counts.upload_published.load(Ordering::Acquire);
                #[cfg(not(feature="upload-qualification"))]let uploaded=0;
                word(&mut b,2+u32::from(uploaded>0));
                for(name,mode,size)in[(b"Folder".as_slice(),0o40755,0u64),(b"Requested.bin".as_slice(),0o100644,if scenario=="transfer-empty"{0}else{1024*1024+17})]{
                    text(&mut b,name);text(&mut b,b"");word(&mut b,13);b.extend(size.to_be_bytes());word(&mut b,mode);word(&mut b,0);word(&mut b,19);
                }
                if uploaded>0{
                    text(&mut b,b"Draft-Notes.bin");text(&mut b,b"");word(&mut b,13);b.extend(((uploaded-1)as u64).to_be_bytes());word(&mut b,0o100644);word(&mut b,0);word(&mut b,19);
                }b
            },
            12 if scenario=="browser"&&!sent_names=>{
                sent_names=true;let mut b=head(104,id);
                let root=current_path=="/generated";let names:Vec<(&[u8],bool)>=if root{vec![(b"Folder",true),(b"Large",true),(b"Generated.txt",false)]}
                    else{vec![(b"Nested.txt",false),(b"Unknown attributes",false)]};
                word(&mut b,names.len()as u32);
                for(name,folder)in names{text(&mut b,name);text(&mut b,b"");
                    if name==b"Unknown attributes"{word(&mut b,0)}else{word(&mut b,13);b.extend(123u64.to_be_bytes());word(&mut b,if folder{0o40755}else{0o100644});word(&mut b,0);word(&mut b,19);}
                }b
            },
            12 if !sent_names=>{
                sent_names=true;let mut b=head(104,id);
                #[cfg(feature="upload-qualification")]let uploaded=counts.upload_published.load(Ordering::Acquire);
                #[cfg(not(feature="upload-qualification"))]let uploaded=0;
                word(&mut b,2+u32::from(uploaded>0));
                for(index,name)in [b"Generated first.txt".as_slice(),b"Generated second.txt"].into_iter().enumerate(){
                    text(&mut b,name);text(&mut b,b"");word(&mut b,0x8000000d);
                    b.extend((123+index as u64*333).to_be_bytes());word(&mut b,0o100644);word(&mut b,0);word(&mut b,19);
                    word(&mut b,0);
                }
                if uploaded>0{
                    text(&mut b,b"Draft-Notes.bin");text(&mut b,b"");word(&mut b,13);b.extend(((uploaded-1)as u64).to_be_bytes());word(&mut b,0o100644);word(&mut b,0);word(&mut b,19);
                }b
            },
            12=>status(id,1),
            4=>{
                counts.closes.fetch_add(1,Ordering::SeqCst);
                if scenario=="lost-close"{let mut byte=[0;1];let _=stream.read(&mut byte).await;return}
                status(id,0)
            },
            _=>panic!("Prohibited or unexpected generated operation"),
        };
        if stream.write_u32(reply.len()as u32).await.is_err()||stream.write_all(&reply).await.is_err(){return}
        // EOF alone is still an in-flight directory read: the qualified client
        // requires CLOSE acknowledgement before sealing its observed result.
        if scenario=="idle-drop"&&request.kind==4{
            tokio::time::sleep(Duration::from_millis(250)).await;
            let _=handle.disconnect(russh::Disconnect::ByApplication,"Generated idle disconnect".into(),"".into()).await;return
        }
    }
}
pub fn public(key:&PrivateKey)->Key{
    Key::from_bytes(&key.public_key().to_bytes().unwrap()).unwrap()
}
pub fn runtime()->tokio::runtime::Runtime{tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()}
pub fn fixture(scenario:String,counts:Arc<Counts>,ready:std_mpsc::SyncSender<(SocketAddr,Key)>){
    let runtime=runtime();let metrics=runtime.handle().clone();
    runtime.block_on(async{
        let key=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();let observed=public(&key);
        let listener=TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await.unwrap();
        ready.send((listener.local_addr().unwrap(),observed)).unwrap();
        if scenario=="concurrent"{
            let mut sessions=Vec::new();
            for _ in 0..2{
                let(stream,_)=tokio::time::timeout(Duration::from_secs(8),listener.accept()).await.unwrap().unwrap();
                let tasks:Tasks=Arc::new(Mutex::new(Vec::new()));let counts=counts.clone();let key=key.clone();
                sessions.push(tokio::spawn(async move{
                    let config=server::Config{keys:vec![key],auth_rejection_time:Duration::from_millis(1),auth_rejection_time_initial:Some(Duration::ZERO),
                        inactivity_timeout:Some(Duration::from_secs(30)),channel_buffer_size:8,window_size:1024*1024,max_auth_attempts:2,..Default::default()};
                    let session=server::run_stream(Arc::new(config),stream,Fixture{scenario:"first".into(),counts:counts.clone(),tasks:tasks.clone(),channels:0,public_key:None,deny_key:false,interactive_stage:0,key_partial:false}).await.unwrap();
                    let _=tokio::time::timeout(Duration::from_secs(35),session).await.expect("Generated concurrent session remained live");
                    counts.socket_ended.fetch_add(1,Ordering::SeqCst);
                    let owned=std::mem::take(&mut*tasks.lock().unwrap());
                    for task in owned{tokio::time::timeout(Duration::from_millis(300),task).await.expect("Concurrent fixture task remained live").unwrap();counts.tasks_joined.fetch_add(1,Ordering::SeqCst);}
                }));
            }
            for session in sessions{session.await.unwrap();}return
        }
        let sessions=if scenario=="workspace-sequence"{4}else if scenario=="saved-sequence"{3}else{1};
        for ordinal in 0..sessions {
        let(stream,_)=tokio::time::timeout(Duration::from_secs(if sessions>1{10}else{3}),listener.accept()).await.unwrap().unwrap();
        if scenario=="pre-banner"{
            let mut stream=stream;let mut read=0;
            loop{let mut b=[0u8;256];let n=tokio::time::timeout(Duration::from_secs(2),stream.read(&mut b)).await.unwrap().unwrap();
                if n==0{counts.socket_ended.store(1,Ordering::SeqCst);return}read+=n;assert!(read<=4096)}
        }
        let tasks:Tasks=Arc::new(Mutex::new(Vec::new()));
        let large=scenario=="large-directory"||scenario=="browser";let reviewing=scenario=="review-delay"||scenario=="idle-healthy";
        let presented=if scenario=="saved-sequence"&&ordinal==2{PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap()}else{key.clone()};
        let mut config=server::Config{keys:vec![presented],auth_rejection_time:Duration::from_millis(1),
            auth_rejection_time_initial:Some(Duration::ZERO),inactivity_timeout:Some(Duration::from_secs(if large||sessions>1{10}else if reviewing{45}else{3})),
            channel_buffer_size:8,window_size:1024*1024,max_auth_attempts:2,..Default::default()};
        if scenario=="legacy-refused"{config.preferred.cipher=std::borrow::Cow::Owned(vec![russh::cipher::AES_128_CTR]);}
        let content=if scenario=="workspace-sequence"{"browser".to_owned()}else{scenario.clone()};
        let session=server::run_stream(Arc::new(config),stream,Fixture{scenario:content,counts:counts.clone(),tasks:tasks.clone(),channels:0,public_key:None,deny_key:false,interactive_stage:0,key_partial:false}).await.unwrap();
        // A protocol disconnect/error is expected in refusal/cancellation cases;
        // its actual future completion, rather than its message, is the gate.
        let _=tokio::time::timeout(Duration::from_secs(if large||reviewing{60}else{4}),session).await.expect("Generated server session remained live");
        counts.socket_ended.fetch_add(1,Ordering::SeqCst);
        let owned=std::mem::take(&mut*tasks.lock().unwrap());
        for mut task in owned{
            match tokio::time::timeout(Duration::from_millis(300),&mut task).await{
                Err(_)=>{counts.tasks_aborted.fetch_add(1,Ordering::SeqCst);task.abort();let _=task.await;},
                Ok(result)=>result.expect("Generated fixture task failed"),
            }
            counts.tasks_joined.fetch_add(1,Ordering::SeqCst);
        }
        }
    });drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);
}

/// One generated key-auth peer; no filesystem, accounts, shell or personal
/// credentials. The caller supplies only the generated authorized PUBLIC key.
pub fn key_fixture(scenario:String,authorized:russh::keys::PublicKey,counts:Arc<Counts>,ready:std_mpsc::SyncSender<(SocketAddr,Key)>){
    let runtime=runtime();let metrics=runtime.handle().clone();
    runtime.block_on(async{
        let ecdsa=scenario=="fips"||scenario=="ecdsa-host";
        let algorithm=if ecdsa{Algorithm::Ecdsa{curve:russh::keys::EcdsaCurve::NistP256}}else{Algorithm::Ed25519};
        let key=PrivateKey::random(&mut rand::rng(),algorithm).unwrap();let observed=public(&key);
        let listener=TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await.unwrap();
        ready.send((listener.local_addr().unwrap(),observed)).unwrap();
        let accept_seconds=if scenario=="agent-qa-first"{60}else{10};
        let(stream,_)=tokio::time::timeout(Duration::from_secs(accept_seconds),listener.accept()).await.unwrap().unwrap();
        let tasks:Tasks=Arc::new(Mutex::new(Vec::new()));
        let mut config=server::Config{keys:vec![key],auth_rejection_time:Duration::from_millis(1),auth_rejection_time_initial:Some(Duration::ZERO),
            inactivity_timeout:Some(Duration::from_secs(30)),channel_buffer_size:8,window_size:1024*1024,max_auth_attempts:2,
            preferred:macexplorer_sftp_reader_qualification::ssh::profile_preferences(),..Default::default()};
        if scenario=="fips"{
            config.preferred.kex=std::borrow::Cow::Owned(vec![russh::kex::ECDH_SHA2_NISTP256,russh::kex::EXTENSION_OPENSSH_STRICT_KEX_AS_SERVER]);
            config.preferred.cipher=std::borrow::Cow::Owned(vec![russh::cipher::AES_128_CTR]);
        }
        let content=if scenario.starts_with("interactive-")||scenario.starts_with("mfa-key")||scenario.starts_with("key-auth-"){scenario.as_str()}else if scenario=="read-stop"{"read-stop"}else{"first"};
        let session=server::run_stream(Arc::new(config),stream,Fixture{scenario:content.into(),counts:counts.clone(),tasks:tasks.clone(),channels:0,
            public_key:Some(authorized),deny_key:scenario=="key-denied",interactive_stage:0,key_partial:false}).await.unwrap();
        // Only the explicit slow-round-trip control needs a longer server
        // lifetime. Individual production request deadlines remain unchanged.
        let fixture_seconds=if scenario.ends_with("folder-slow-body"){120}
            else if scenario=="agent-qa-first"{60}else{35};
        let _=tokio::time::timeout(Duration::from_secs(fixture_seconds),session).await.expect("Generated key fixture session remained");
        counts.socket_ended.fetch_add(1,Ordering::SeqCst);
        let owned=std::mem::take(&mut*tasks.lock().unwrap());
        for task in owned{tokio::time::timeout(Duration::from_millis(500),task).await.expect("Generated key fixture task remained").unwrap();counts.tasks_joined.fetch_add(1,Ordering::SeqCst);}
    });drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);
}

#[cfg(test)]mod operation_tests{
    use super::operation_scenario;
    #[test]fn fresh_folder_uses_metadata_channel_before_its_exact_write_channel(){
        for prefix in["key-auth-","mfa-key-auth-","interactive-auth-"]{
            for fault in["success","root-conflict","lost-mkdir","lost-open","stop-write","stop-readback"]{
                let scenario=format!("{prefix}fresh-{fault}");
                assert_eq!(operation_scenario(&scenario,1),"transfer-success");
                assert_eq!(operation_scenario(&scenario,2),format!("fresh-{fault}"));
                assert_eq!(operation_scenario(&scenario,3),"transfer-success");
            }
        }
    }
    #[test]fn explicit_authentication_composes_with_existing_body_roles(){
        for prefix in["key-auth-","mfa-key-auth-","interactive-auth-"]{
            let scenario=format!("{prefix}composed-success");
            assert_eq!(operation_scenario(&scenario,1),"transfer-success");
            assert_eq!(operation_scenario(&scenario,2),"download-success");
            assert_eq!(operation_scenario(&scenario,3),"upload-success");
            assert_eq!(operation_scenario(&scenario,4),"transfer-success");
            for failure in["sync-failure","lost-rename","stop-write"]{
                assert_eq!(operation_scenario(&format!("{prefix}composed-{failure}"),3),format!("upload-{failure}"));
            }
            for failure in["denied","changed","lost-close","stop"]{
                assert_eq!(operation_scenario(&format!("{prefix}transfer-{failure}"),1),format!("transfer-{failure}"));
                assert_eq!(operation_scenario(&format!("{prefix}transfer-{failure}"),2),format!("download-{failure}"));
            }
        }
    }
    #[test]fn existing_plain_fixture_roles_remain_distinct(){
        for scenario in["first","browser","read-stop","interactive-two-rounds","mfa-key"]{
            for channel in 1..5{assert_eq!(operation_scenario(scenario,channel),scenario)}
        }
        assert_eq!(operation_scenario("transfer-success",2),"download-success");
        assert_eq!(operation_scenario("push-success",2),"upload-success");
    }
}
