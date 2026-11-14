//! Two generated loopback peers. Only the declared fake target is forwarded;
//! no external hostname, command, filesystem body or personal key is used.
#[allow(dead_code)]mod ssh_fixture;
use russh::{server::{self},keys::{PrivateKey,PublicKey,Algorithm},Channel};
use std::{io::{Read,Write},sync::{Arc,Mutex,atomic::{AtomicUsize,Ordering}},time::Duration};
use tokio::{net::{TcpListener,TcpStream},task::JoinHandle,sync::watch};
type Tasks=Arc<Mutex<Vec<JoinHandle<()>>>>;
struct Jump{
    authentication:ssh_fixture::Fixture,target:u16,deny:bool,forwards:Arc<AtomicUsize>,tasks:Tasks,
    own_forwards:usize,
}
impl server::Handler for Jump{
    type Error=russh::Error;
    async fn auth_none(&mut self,user:&str)->Result<server::Auth,russh::Error>{self.authentication.auth_none(user).await}
    async fn auth_publickey_offered(&mut self,user:&str,key:&PublicKey)->Result<server::Auth,russh::Error>{self.authentication.auth_publickey_offered(user,key).await}
    async fn auth_publickey(&mut self,user:&str,key:&PublicKey)->Result<server::Auth,russh::Error>{self.authentication.auth_publickey(user,key).await}
    async fn auth_password(&mut self,user:&str,password:&str)->Result<server::Auth,russh::Error>{self.authentication.auth_password(user,password).await}
    async fn auth_keyboard_interactive<'a>(&'a mut self,user:&str,submethods:&str,response:Option<server::Response<'a>>)->Result<server::Auth,russh::Error>{
        self.authentication.auth_keyboard_interactive(user,submethods,response).await
    }
    async fn channel_open_session(&mut self,channel:Channel<server::Msg>,reply:server::ChannelOpenHandle,_:&mut server::Session)->Result<(),russh::Error>{
        drop(reply);drop(channel);Ok(())
    }
    async fn channel_open_direct_tcpip(&mut self,channel:Channel<server::Msg>,host:&str,port:u32,origin:&str,origin_port:u32,
        reply:server::ChannelOpenHandle,_:&mut server::Session)->Result<(),russh::Error>{
        let ordinal=self.own_forwards;self.own_forwards+=1;self.forwards.fetch_add(1,Ordering::SeqCst);
        if self.deny||ordinal!=0||host!="private.internal.test"||port!=self.target as u32||origin!="127.0.0.1"||origin_port!=0{
            drop(reply);drop(channel);return Ok(())
        }
        let mut target=TcpStream::connect((std::net::Ipv4Addr::LOCALHOST,self.target)).await?;
        reply.accept().await;
        let task=tokio::spawn(async move{
            let mut stream=channel.into_stream();let _=tokio::io::copy_bidirectional(&mut stream,&mut target).await;
        });self.tasks.lock().unwrap().push(task);Ok(())
    }
}
fn config(key:PrivateKey)->Arc<server::Config>{Arc::new(server::Config{keys:vec![key],
    preferred:macexplorer_sftp_reader_qualification::ssh::profile_preferences(),
    auth_rejection_time:Duration::from_millis(1),auth_rejection_time_initial:Some(Duration::ZERO),
    inactivity_timeout:Some(Duration::from_secs(30)),channel_buffer_size:8,window_size:1024*1024,max_auth_attempts:2,..Default::default()})}
async fn join(tasks:Tasks)->usize{
    let owned=std::mem::take(&mut*tasks.lock().unwrap());let count=owned.len();
    for task in owned{tokio::time::timeout(Duration::from_millis(700),task).await.expect("Generated forwarding task remained").unwrap();}count
}
fn main(){
    let args=std::env::args().collect::<Vec<_>>();assert!(args.len()==2);
    let scenario=args[1].clone();assert!(["first","deny-forward","outer-prompts","target-prompts","both-prompts","reconnect","reconnect-prompts","read-stop","target-disconnect"].contains(&scenario.as_str()));
    let connections=if scenario.starts_with("reconnect"){2}else{1};
    let mut bytes=Vec::new();std::io::stdin().take(16385).read_to_end(&mut bytes).unwrap();assert!(bytes.len()<=16384);
    let authorized=PublicKey::from_bytes(&bytes).unwrap();let runtime=ssh_fixture::runtime();let metrics=runtime.handle().clone();
    let outer_counts=Arc::new(ssh_fixture::Counts::default());let target_counts=Arc::new(ssh_fixture::Counts::default());
    let forwards=Arc::new(AtomicUsize::new(0));
    let(target_connected,joined)=runtime.block_on(async{
        let outer_key=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let target_key=PrivateKey::random(&mut rand::rng(),Algorithm::Ecdsa{curve:russh::keys::EcdsaCurve::NistP256}).unwrap();
        let outer_config=config(outer_key.clone());let target_config=config(target_key.clone());
        let target_listener=TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await.unwrap();
        let target_port=target_listener.local_addr().unwrap().port();
        let outer_listener=TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await.unwrap();
        let hex=|key:&PrivateKey|ssh_fixture::public(key).bytes().iter().map(|b|format!("{b:02x}")).collect::<String>();
        println!("{{\"ready\":true,\"port\":{},\"targetPort\":{},\"generatedPublicKey\":\"{}\",\"targetPublicKey\":\"{}\"}}",
            outer_listener.local_addr().unwrap().port(),target_port,hex(&outer_key),hex(&target_key));std::io::stdout().flush().unwrap();
        let(done,mut ended)=watch::channel(false);let inner_counts=target_counts.clone();let target_authorized=authorized.clone();let target_scenario=scenario.clone();
        let target_task=tokio::spawn(async move{
            let mut connected=false;let mut joined=0;
            for _ in 0..connections{
            let stream=tokio::select!{biased;_ = ended.changed()=>break,accepted=target_listener.accept()=>accepted.unwrap().0};
            connected=true;
            let tasks:Tasks=Arc::new(Mutex::new(Vec::new()));
            let scenario=match target_scenario.as_str(){"target-prompts"|"both-prompts"|"reconnect-prompts"=>"mfa-key","read-stop"=>"read-stop","target-disconnect"=>"disconnect-read",_=>"first"};
            let fixture=ssh_fixture::Fixture::generated(scenario,target_authorized.clone(),inner_counts.clone(),tasks.clone());
            let handle=server::run_stream(target_config.clone(),stream,fixture).await.unwrap();
            let _=tokio::time::timeout(Duration::from_secs(35),handle).await.expect("Generated inner session remained");
            inner_counts.socket_ended.fetch_add(1,Ordering::SeqCst);joined+=join(tasks).await;
            }(connected,joined)
        });
        let mut joined=0;
        for _ in 0..connections{
        let(stream,_)=tokio::time::timeout(Duration::from_secs(if connections==2{30}else{10}),outer_listener.accept()).await.unwrap().unwrap();
        let tasks:Tasks=Arc::new(Mutex::new(Vec::new()));
        let auth=ssh_fixture::Fixture::generated(if ["outer-prompts","both-prompts","reconnect-prompts"].contains(&scenario.as_str()){"mfa-key"}else{"first"},authorized.clone(),outer_counts.clone(),tasks.clone());
        let handler=Jump{authentication:auth,target:target_port,deny:scenario=="deny-forward",forwards:forwards.clone(),tasks:tasks.clone(),own_forwards:0};
        let handle=server::run_stream(outer_config.clone(),stream,handler).await.unwrap();
        let _=tokio::time::timeout(Duration::from_secs(35),handle).await.expect("Generated jump session remained");
        outer_counts.socket_ended.fetch_add(1,Ordering::SeqCst);joined+=join(tasks).await;
        }
        let _=done.send(true);let(connected,target_joined)=tokio::time::timeout(Duration::from_secs(2),target_task).await.expect("Generated target listener remained").unwrap();
        (connected,joined+target_joined)
    });drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);
    assert_eq!(outer_counts.unexpected_auth.load(Ordering::SeqCst)+target_counts.unexpected_auth.load(Ordering::SeqCst),0);
    println!("{{\"ended\":true,\"outerSocketsEnded\":{},\"targetConnected\":{},\"targetSocketsEnded\":{},\"forwards\":{},\"outerAuth\":{},\"targetAuth\":{},\"outerPrompts\":{},\"targetPrompts\":{},\"metadataRequests\":{},\"fixtureTasksJoined\":{},\"runtimeTasksAfter\":0}}",
        outer_counts.socket_ended.load(Ordering::SeqCst),target_connected,target_counts.socket_ended.load(Ordering::SeqCst),forwards.load(Ordering::SeqCst),
        outer_counts.auth.load(Ordering::SeqCst),target_counts.auth.load(Ordering::SeqCst),outer_counts.interactive_calls.load(Ordering::SeqCst),
        target_counts.interactive_calls.load(Ordering::SeqCst),target_counts.requests.load(Ordering::SeqCst),joined);
}
