//! Generated one-hop bridge to one separately owned loopback fixture only.
//! No shell, filesystem body, personal endpoint or dynamic target forwarding.
#[allow(dead_code)]mod ssh_fixture;
use russh::{server::{self},keys::{PrivateKey,PublicKey,Algorithm},Channel};
use std::{io::{Read,Write},sync::{Arc,Mutex,atomic::{AtomicUsize,Ordering}},time::Duration};
use tokio::{net::{TcpListener,TcpStream},task::JoinHandle};
type Tasks=Arc<Mutex<Vec<JoinHandle<()>>>>;
fn permitted(host:&str,port:u32,target:u16,origin:&str,origin_port:u32,ordinal:usize,deny:bool)->bool {
    !deny&&ordinal==0&&host=="private.internal.test"&&port==u32::from(target)&&origin=="127.0.0.1"&&origin_port==0
}
struct Bridge{auth:ssh_fixture::Fixture,target:u16,deny:bool,forwards:Arc<AtomicUsize>,tasks:Tasks}
impl server::Handler for Bridge {
    type Error=russh::Error;
    async fn auth_none(&mut self,user:&str)->Result<server::Auth,russh::Error>{self.auth.auth_none(user).await}
    async fn auth_publickey_offered(&mut self,user:&str,key:&PublicKey)->Result<server::Auth,russh::Error>{self.auth.auth_publickey_offered(user,key).await}
    async fn auth_publickey(&mut self,user:&str,key:&PublicKey)->Result<server::Auth,russh::Error>{self.auth.auth_publickey(user,key).await}
    async fn auth_password(&mut self,user:&str,password:&str)->Result<server::Auth,russh::Error>{self.auth.auth_password(user,password).await}
    async fn auth_keyboard_interactive<'a>(&'a mut self,user:&str,submethods:&str,response:Option<server::Response<'a>>)->Result<server::Auth,russh::Error>{self.auth.auth_keyboard_interactive(user,submethods,response).await}
    async fn channel_open_session(&mut self,channel:Channel<server::Msg>,reply:server::ChannelOpenHandle,_:&mut server::Session)->Result<(),russh::Error>{drop(reply);drop(channel);Ok(())}
    async fn channel_open_direct_tcpip(&mut self,channel:Channel<server::Msg>,host:&str,port:u32,origin:&str,origin_port:u32,
        reply:server::ChannelOpenHandle,_:&mut server::Session)->Result<(),russh::Error>{
        let ordinal=self.forwards.fetch_add(1,Ordering::SeqCst);
        if !permitted(host,port,self.target,origin,origin_port,ordinal,self.deny){drop(reply);drop(channel);return Ok(())}
        let mut target=TcpStream::connect((std::net::Ipv4Addr::LOCALHOST,self.target)).await?;reply.accept().await;
        self.tasks.lock().unwrap().push(tokio::spawn(async move{
            let mut stream=channel.into_stream();let _=tokio::io::copy_bidirectional(&mut stream,&mut target).await;
        }));Ok(())
    }
}
fn main(){
    let args=std::env::args().collect::<Vec<_>>();assert_eq!(args.len(),3);
    let port=args[1].parse::<u16>().unwrap();assert!(port>0);
    let scenario=args[2].as_str();assert!(matches!(scenario,"key"|"mfa"|"prompts"|"password"|"deny"));
    let mut public=vec![];std::io::stdin().take(16385).read_to_end(&mut public).unwrap();assert!(public.len()<=16384);
    let public=PublicKey::from_bytes(&public).unwrap();let runtime=ssh_fixture::runtime();let metrics=runtime.handle().clone();
    let counts=Arc::new(ssh_fixture::Counts::default());let forwards=Arc::new(AtomicUsize::new(0));
    let joined=runtime.block_on(async{
        let key=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let config=Arc::new(server::Config{keys:vec![key.clone()],preferred:macexplorer_sftp_reader_qualification::ssh::profile_preferences(),
            auth_rejection_time:Duration::from_millis(1),auth_rejection_time_initial:Some(Duration::ZERO),inactivity_timeout:Some(Duration::from_secs(120)),
            channel_buffer_size:8,window_size:1024*1024,max_auth_attempts:2,..Default::default()});
        let listener=TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await.unwrap();
        let bytes=ssh_fixture::public(&key).bytes().iter().map(|b|format!("{b:02x}")).collect::<String>();
        println!("{{\"ready\":true,\"port\":{},\"targetPort\":{port},\"generatedPublicKey\":\"{bytes}\"}}",listener.local_addr().unwrap().port());std::io::stdout().flush().unwrap();
        let(stream,_)=tokio::time::timeout(Duration::from_secs(30),listener.accept()).await.unwrap().unwrap();
        let tasks:Tasks=Arc::new(Mutex::new(vec![]));
        let auth=ssh_fixture::Fixture::generated(match scenario{"mfa"=>"mfa-key","prompts"=>"interactive-two-rounds",_=>"first"},public,counts.clone(),tasks.clone());
        let handler=Bridge{auth,target:port,deny:scenario=="deny",forwards:forwards.clone(),tasks:tasks.clone()};
        let handle=server::run_stream(config,stream,handler).await.unwrap();
        let _=tokio::time::timeout(Duration::from_secs(180),handle).await.expect("Generated bridge session remained");
        counts.socket_ended.fetch_add(1,Ordering::SeqCst);
        let owned=std::mem::take(&mut*tasks.lock().unwrap());let joined=owned.len();
        for task in owned{tokio::time::timeout(Duration::from_millis(900),task).await.expect("Generated bridge task remained").unwrap();}joined
    });drop(runtime);assert_eq!(metrics.metrics().num_alive_tasks(),0);assert_eq!(counts.unexpected_auth.load(Ordering::SeqCst),0);
    println!("{{\"ended\":true,\"socketEnded\":1,\"forwards\":{},\"authCalls\":{},\"interactiveCalls\":{},\"fixtureTasksJoined\":{joined},\"runtimeTasksAfter\":0}}",
        forwards.load(Ordering::SeqCst),counts.auth.load(Ordering::SeqCst),counts.interactive_calls.load(Ordering::SeqCst));
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn only_the_exact_first_generated_target_can_be_forwarded(){
        assert!(permitted("private.internal.test",2222,2222,"127.0.0.1",0,0,false));
        for(host,port,origin,source,ordinal,deny)in[
            ("personal.example",2222,"127.0.0.1",0,0,false),("private.internal.test",22,"127.0.0.1",0,0,false),
            ("private.internal.test",2222,"0.0.0.0",0,0,false),("private.internal.test",2222,"127.0.0.1",1,0,false),
            ("private.internal.test",2222,"127.0.0.1",0,1,false),("private.internal.test",2222,"127.0.0.1",0,0,true)]{
            assert!(!permitted(host,port,2222,origin,source,ordinal,deny));
        }
    }
}
