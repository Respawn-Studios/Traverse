//! Experimental SSH owner. No ambient credential/config access.
#[cfg(feature="inplace-edit-v1")]mod inplace_close;
#[cfg(feature="inplace-edit-v1")]use inplace_close::{CloseRegistry,CloseWatch};
use std::{borrow::Cow, net::{IpAddr,SocketAddr}, sync::{Arc,atomic::{AtomicBool,Ordering}}, time::Duration};
#[cfg(feature="agent-qualification")]use std::path::Path;
use russh::{client,keys::{Algorithm,HashAlg,PublicKeyOrCertificate},Channel,ChannelStream};
use tokio::{net::TcpStream,sync::{mpsc,oneshot,watch}};
use zeroize::Zeroizing;

#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Failure { Identity, Key, Trust, Timeout, Transport, Authentication, Closed,
    KeyInput, KeyPassphrase, KeyUnsupported, KeyChanged, ForwardDenied, CertificateExpired, CertificateNotYetValid,
    #[cfg(feature="agent-qualification")]AgentDenied }
#[cfg(feature="agent-qualification")]
fn agent_failure(error:crate::agent_auth::Failure)->Failure{match error{
    crate::agent_auth::Failure::Input=>Failure::KeyInput,
    crate::agent_auth::Failure::Identity=>Failure::KeyChanged,
    crate::agent_auth::Failure::Algorithm=>Failure::KeyUnsupported,
    crate::agent_auth::Failure::Timeout=>Failure::Timeout,
    crate::agent_auth::Failure::Denied=>Failure::AgentDenied,
    _=>Failure::Transport,
}}
#[cfg(feature="download-qualification")]
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum ReceiveFailure{Connection(Failure),Body(crate::download::Failure)}
#[cfg(feature="upload-qualification")]
#[derive(Debug,PartialEq,Eq)]
pub enum SendFailure{Connection(Failure),Body(crate::upload::Interrupted)}
type Result<T> = std::result::Result<T,Failure>;

#[derive(Debug,Clone,PartialEq,Eq)]
pub struct Peer { host:String, port:u16, nonce:[u8;16] }
impl Peer {
    pub fn new(host:&str,port:u16,nonce:[u8;16])->Result<Self>{
        if host.is_empty()||host.len()>253||port==0||nonce==[0;16]{return Err(Failure::Identity)}
        let host=if let Ok(ip)=host.parse::<IpAddr>(){ip.to_string()}else{
            if !host.is_ascii()||host.ends_with('.')||!host.split('.').all(|label|
                !label.is_empty()&&label.len()<=63&&label.as_bytes()[0].is_ascii_alphanumeric()
                &&label.as_bytes()[label.len()-1].is_ascii_alphanumeric()
                &&label.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-')){return Err(Failure::Identity)}
            host.to_ascii_lowercase()
        };Ok(Self{host,port,nonce})
    }
    pub fn host(&self)->&str{&self.host}
    pub fn port(&self)->u16{self.port}
}
#[derive(Debug,Clone,PartialEq,Eq)]
pub struct Key { bytes:Vec<u8>, algorithm:String, fingerprint:String }
impl Key {
    pub fn from_bytes(bytes:&[u8])->Result<Self>{
        if bytes.is_empty()||bytes.len()>16384{return Err(Failure::Key)}
        let public=russh::keys::PublicKey::from_bytes(bytes).map_err(|_|Failure::Key)?;
        let key=Self::observe(&public.into())?;
        if key.bytes!=bytes{return Err(Failure::Key)}
        Ok(key)
    }
    pub fn bytes(&self)->&[u8]{&self.bytes}
    pub fn algorithm(&self)->&str{&self.algorithm}
    pub fn fingerprint(&self)->&str{&self.fingerprint}
    fn observe(value:&PublicKeyOrCertificate)->Result<Self>{
        if value.certificate().is_some(){return Err(Failure::Key)}
        let public=value.public_key();
        crate::key_auth::admitted_public(&public).map_err(|_|Failure::Key)?;
        let bytes=public.to_bytes().map_err(|_|Failure::Key)?;
        let algorithm=public.algorithm().to_string();let fingerprint=public.fingerprint(HashAlg::Sha256).to_string();
        if bytes.len()>16384||algorithm.len()>32||fingerprint.len()>128{return Err(Failure::Key)}
        Ok(Self{bytes,algorithm,fingerprint})
    }
}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum TrustKind { First, Matching, Changed }
#[derive(Debug,Clone,PartialEq,Eq)]
pub struct Challenge { pub peer:Peer, pub current:Key, pub previous:Option<Key> }
impl Challenge {
    pub fn kind(&self)->TrustKind{match &self.previous{None=>TrustKind::First,
        Some(old)if old==&self.current=>TrustKind::Matching,Some(_)=>TrustKind::Changed}}
    fn accepts(&self,decision:&Decision)->bool{
        decision.challenge==*self&&match (self.kind(),decision.action){
            (TrustKind::First,Action::ConnectOnce|Action::Remember)=>true,
            (TrustKind::Matching,Action::UseMatching)=>true,
            (TrustKind::Changed,Action::ReplaceVerified)=>true,_=>false,
        }
    }
}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Action { Reject, ConnectOnce, Remember, UseMatching, ReplaceVerified }
pub struct Decision { pub challenge:Challenge, pub action:Action }
pub struct TrustRequest { pub challenge:Challenge, pub reply:oneshot::Sender<Decision> }

pub fn modern_preferences()->russh::Preferred{
    let mut preferred=profile_preferences();
    preferred.kex=Cow::Owned(vec![russh::kex::CURVE25519,russh::kex::EXTENSION_SUPPORT_AS_CLIENT,
        russh::kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT]);
    preferred.key=Cow::Owned(vec![Algorithm::Ed25519]);
    preferred.cipher=Cow::Owned(vec![russh::cipher::AES_256_GCM,russh::cipher::AES_128_GCM]);preferred
}
pub fn profile_preferences()->russh::Preferred{
    russh::Preferred{
        kex:Cow::Owned(vec![russh::kex::CURVE25519,russh::kex::ECDH_SHA2_NISTP256,
            russh::kex::ECDH_SHA2_NISTP384,russh::kex::ECDH_SHA2_NISTP521,russh::kex::DH_G14_SHA256,russh::kex::EXTENSION_SUPPORT_AS_CLIENT,
            russh::kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT]),
        key:Cow::Owned(vec![Algorithm::Ed25519,
            Algorithm::Ecdsa{curve:russh::keys::EcdsaCurve::NistP256},Algorithm::Ecdsa{curve:russh::keys::EcdsaCurve::NistP384},
            Algorithm::Ecdsa{curve:russh::keys::EcdsaCurve::NistP521},Algorithm::Rsa{hash:Some(HashAlg::Sha512)},
            Algorithm::Rsa{hash:Some(HashAlg::Sha256)}]),host_key_certificates:Cow::Borrowed(&[]),
        cipher:Cow::Owned(vec![russh::cipher::AES_256_GCM,russh::cipher::AES_128_GCM,russh::cipher::AES_256_CTR,russh::cipher::AES_128_CTR]),
        mac:Cow::Owned(vec![russh::mac::HMAC_SHA256_ETM]),
        compression:Cow::Owned(vec![russh::compression::NONE]),
    }
}

struct Handler {
    #[cfg(feature="inplace-edit-v1")]inplace_closes:Arc<CloseRegistry>,
    peer:Peer, previous:Option<Key>, requests:mpsc::Sender<TrustRequest>,
    accepted:Arc<AtomicBool>, verified:Option<Key>, deadline:Duration,review_phase:Option<watch::Sender<bool>>,profiles:bool,
}
macro_rules! refuse_channel {
    ($name:ident $(,$arg:ident:$kind:ty)*) => {
        async fn $name(&mut self,channel:Channel<client::Msg>,$($arg:$kind,)*
            reply:client::ChannelOpenHandle,_session:&mut client::Session)->std::result::Result<(),russh::Error>{
            drop(reply);drop(channel);Ok(())
        }
    };
}
impl client::Handler for Handler {
    type Error=russh::Error;
    #[cfg(feature="inplace-edit-v1")]
    async fn channel_close(&mut self,channel:russh::ChannelId,_session:&mut client::Session)->std::result::Result<(),russh::Error>{
        self.inplace_closes.observed(channel.number());Ok(())
    }
    async fn check_server_key(&mut self,value:&PublicKeyOrCertificate)->std::result::Result<bool,russh::Error>{
        // Rekey of this same connection still requires the exact approved key.
        let Ok(current)=Key::observe(value)else{return Ok(false)};
        if !self.profiles&&value.public_key().algorithm()!=Algorithm::Ed25519{return Ok(false)}
        if let Some(verified)=&self.verified{return Ok(verified==&current)}
        let challenge=Challenge{peer:self.peer.clone(),current,previous:self.previous.clone()};
        let (reply,answer)=oneshot::channel();
        if let Some(phase)=&self.review_phase{let _=phase.send(true);}
        let approved=tokio::time::timeout(self.deadline,async{
            self.requests.send(TrustRequest{challenge:challenge.clone(),reply}).await.ok()?;
            let decision=answer.await.ok()?;Some(challenge.accepts(&decision))
        }).await.ok().flatten().unwrap_or(false);
        if let Some(phase)=&self.review_phase{let _=phase.send(false);}
        self.accepted.store(approved,Ordering::SeqCst);
        if approved{self.verified=Some(challenge.current)}
        Ok(approved)
    }
    refuse_channel!(server_channel_open_forwarded_tcpip,_connected_address:&str,_connected_port:u32,_originator_address:&str,_originator_port:u32);
    refuse_channel!(server_channel_open_forwarded_streamlocal,_socket_path:&str);
    refuse_channel!(server_channel_open_agent_forward);
    refuse_channel!(server_channel_open_session);
    refuse_channel!(server_channel_open_direct_tcpip,_host_to_connect:&str,_port_to_connect:u32,_originator_address:&str,_originator_port:u32);
    refuse_channel!(server_channel_open_direct_streamlocal,_socket_path:&str);
    refuse_channel!(server_channel_open_x11,_originator_address:&str,_originator_port:u32);
    refuse_channel!(server_channel_open_unknown);
    async fn should_accept_unknown_server_channel(&mut self,_id:russh::ChannelId,_kind:&str)->bool{false}
}

/// No raw Handle escapes: callers cannot request a shell, exec, tunnel, agent
/// or unqualified authentication. Explicit body operations have separate gates.
pub struct Verified {
    #[cfg(feature="inplace-edit-v1")]inplace_closes:Arc<CloseRegistry>, handle:Option<client::Handle<Handler>>, deadline:Duration, authenticated:bool, channel_opened:bool,
    interactive_started:bool,interactive_pending:Option<usize> }
pub enum KeyAuthentication{Complete(Key),AdditionalStep(Key)}
#[cfg(feature="agent-qualification")]
pub enum AgentAuthentication{Complete(String),AdditionalStep(String)}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub struct Drain {
    pub disconnect_queued:bool,
    pub ssh_task_ended:bool,
    pub ended_normally:bool,
}
impl Verified {
    pub async fn connect(peer:Peer,address:SocketAddr,previous:Option<Key>,requests:mpsc::Sender<TrustRequest>,deadline:Duration)->Result<Self>{
        Self::connect_limits(peer,address,previous,requests,deadline,deadline,false,false).await
    }
    /// A bounded human decision has its own clock; it does not consume the
    /// remaining network budget. No credential authentication occurs here.
    pub async fn connect_reviewed(peer:Peer,address:SocketAddr,previous:Option<Key>,requests:mpsc::Sender<TrustRequest>,network:Duration,review:Duration)->Result<Self>{
        Self::connect_limits(peer,address,previous,requests,network,review.min(Duration::from_secs(120)),true,false).await
    }
    pub async fn connect_profile_reviewed(peer:Peer,address:SocketAddr,previous:Option<Key>,requests:mpsc::Sender<TrustRequest>,network:Duration,review:Duration)->Result<Self>{
        Self::connect_limits(peer,address,previous,requests,network,review.min(Duration::from_secs(120)),true,true).await
    }
    /// One authenticated jump opens exactly one forward, to this frozen peer.
    /// The destination hostname is resolved by that server. No local listener,
    /// local destination DNS, shell, agent or raw forwarding handle escapes.
    pub async fn connect_through_jump(&mut self,peer:Peer,previous:Option<Key>,requests:mpsc::Sender<TrustRequest>)->Result<Self>{
        self.check_open()?;
        if self.channel_opened{return Err(Failure::Closed)}self.channel_opened=true;
        let handle=self.handle.as_ref().ok_or(Failure::Closed)?;
        let channel=tokio::time::timeout(self.deadline,handle.channel_open_direct_tcpip(peer.host(),peer.port()as u32,"127.0.0.1",0))
            .await.map_err(|_|Failure::Timeout)?.map_err(|_|Failure::ForwardDenied)?;
        let accepted=Arc::new(AtomicBool::new(false));let(phase,changes)=watch::channel(false);
        #[cfg(feature="inplace-edit-v1")]let inplace_closes=Arc::new(CloseRegistry::default());
        let handler=Handler{#[cfg(feature="inplace-edit-v1")]inplace_closes:inplace_closes.clone(),peer,previous,requests,accepted:accepted.clone(),verified:None,
            deadline:Duration::from_secs(120),review_phase:Some(phase),profiles:true};
        let config=Arc::new(client::Config{preferred:profile_preferences(),window_size:1024*1024,
            maximum_packet_size:32768,channel_buffer_size:8,keepalive_interval:None,
            inactivity_timeout:None,nodelay:true,..Default::default()});
        let connecting=async{client::connect_stream(config,channel.into_stream(),handler).await.map_err(|_|Failure::Transport)};
        let inner=network_budget(connecting,changes,self.deadline).await?;
        if !accepted.load(Ordering::SeqCst){return Err(Failure::Trust)}
        Ok(Self{#[cfg(feature="inplace-edit-v1")]inplace_closes,handle:Some(inner),deadline:self.deadline,authenticated:false,channel_opened:false,
            interactive_started:false,interactive_pending:None})
    }
    async fn connect_limits(peer:Peer,address:SocketAddr,previous:Option<Key>,requests:mpsc::Sender<TrustRequest>,deadline:Duration,review:Duration,separate:bool,profiles:bool)->Result<Self>{
        if address.port()!=peer.port(){return Err(Failure::Identity)}
        let deadline=deadline.min(Duration::from_secs(30));
        if deadline.is_zero()||review.is_zero(){return Err(Failure::Identity)}
        let accepted=Arc::new(AtomicBool::new(false));
        let(phase,changes)=watch::channel(false);
        #[cfg(feature="inplace-edit-v1")]let inplace_closes=Arc::new(CloseRegistry::default());
        let handler=Handler{#[cfg(feature="inplace-edit-v1")]inplace_closes:inplace_closes.clone(),peer,previous,requests,accepted:accepted.clone(),verified:None,deadline:review,review_phase:if separate{Some(phase)}else{None},profiles};
        let config=Arc::new(client::Config{preferred:if profiles{profile_preferences()}else{modern_preferences()},window_size:1024*1024,
            maximum_packet_size:32768,channel_buffer_size:8,keepalive_interval:None,
            // Connect/review/auth/read/close retain their explicit deadlines.
            // Post-auth idle liveness belongs to the worker, not user activity.
            inactivity_timeout:None,nodelay:true,..Default::default()});
        let connecting=async{
            let stream=TcpStream::connect(address).await.map_err(|_|Failure::Transport)?;
            client::connect_stream(config,stream,handler).await.map_err(|_|Failure::Transport)
        };
        let handle=if separate{network_budget(connecting,changes,deadline).await?}
            else{tokio::time::timeout(deadline,connecting).await.map_err(|_|Failure::Timeout)??};
        if !accepted.load(Ordering::SeqCst){return Err(Failure::Trust)}
        Ok(Self{#[cfg(feature="inplace-edit-v1")]inplace_closes,handle:Some(handle),deadline,authenticated:false,channel_opened:false,interactive_started:false,interactive_pending:None})
    }
    /// The caller may obtain credentials only after connect returns Verified.
    /// This takes a zeroizing owner; the SSH library's internal copies have a
    /// separate lifetime and remain contained by runtime/process shutdown.
    pub async fn password(&mut self,user:&str,password:Zeroizing<String>)->Result<()>{
        if user.is_empty()||user.len()>256||user.chars().any(char::is_control)||password.len()>4096{
            return Err(Failure::Authentication)
        }
        if self.authenticated{return Err(Failure::Authentication)}
        let mut handle=self.handle.take().ok_or(Failure::Closed)?;
        let result=tokio::time::timeout(self.deadline,handle.authenticate_password(user,password.as_str()))
            .await.map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Transport)?;
        if !result.success(){return Err(Failure::Authentication)}
        self.authenticated=true;self.handle=Some(handle);Ok(())
    }
    /// Caller supplies already granted bytes AFTER Verified. A failed method
    /// never silently tries passwords, personal default keys or another route.
    pub async fn public_key(&mut self,user:&str,bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,expected:Option<&Key>)->Result<Key>{
        match self.key_authentication(user,bytes,passphrase,expected,false).await?{
            KeyAuthentication::Complete(key)=>Ok(key),KeyAuthentication::AdditionalStep(_)=>Err(Failure::Authentication),
        }
    }
    pub async fn public_key_then_interactive(&mut self,user:&str,bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,expected:Option<&Key>)->Result<KeyAuthentication>{
        self.key_authentication(user,bytes,passphrase,expected,true).await
    }
    /// The certificate and its matching private key are explicit parent-supplied
    /// bytes after host review. This never changes host-certificate trust.
    pub async fn user_certificate(&mut self,user:&str,bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,
        expected:Option<&Key>,certificate:Zeroizing<Vec<u8>>)->Result<Key>{
        match self.certificate_authentication(user,bytes,passphrase,expected,certificate,false).await?{
            KeyAuthentication::Complete(key)=>Ok(key),KeyAuthentication::AdditionalStep(_)=>Err(Failure::Authentication),
        }
    }
    pub async fn user_certificate_then_interactive(&mut self,user:&str,bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,
        expected:Option<&Key>,certificate:Zeroizing<Vec<u8>>)->Result<KeyAuthentication>{
        self.certificate_authentication(user,bytes,passphrase,expected,certificate,true).await
    }
    async fn certificate_authentication(&mut self,user:&str,bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,
        expected:Option<&Key>,certificate:Zeroizing<Vec<u8>>,allow_interactive:bool)->Result<KeyAuthentication>{
        if self.authenticated||user.is_empty()||user.len()>256||user.chars().any(char::is_control){return Err(Failure::Authentication)}
        let mut key=crate::key_auth::PreparedKey::decode(bytes,passphrase).map_err(|error|match error{
            crate::key_auth::Failure::Passphrase=>Failure::KeyPassphrase,
            crate::key_auth::Failure::Algorithm|crate::key_auth::Failure::Cost|crate::key_auth::Failure::Format=>Failure::KeyUnsupported,
            _=>Failure::KeyInput,
        })?;
        let public=key.public().clone();let identity=Key::from_bytes(&public.to_bytes().map_err(|_|Failure::KeyInput)?)?;
        if expected.is_some_and(|expected|expected!=&identity){return Err(Failure::KeyChanged)}
        let certificate=key.bind_user_certificate(&certificate).map_err(|error|match error{
            crate::key_auth::Failure::Inconsistent=>Failure::KeyChanged,
            crate::key_auth::Failure::CertificateExpired=>Failure::CertificateExpired,
            crate::key_auth::Failure::CertificateNotYetValid=>Failure::CertificateNotYetValid,
            _=>Failure::KeyInput,
        })?;
        let handle=self.handle.as_mut().ok_or(Failure::Closed)?;
        let hash=if matches!(public.algorithm(),Algorithm::Rsa{..}){
            let supported=tokio::time::timeout(self.deadline,handle.best_supported_rsa_hash()).await.map_err(|_|Failure::Timeout)?
                .map_err(|_|Failure::Transport)?;
            match supported{Some(Some(HashAlg::Sha256))=>Some(HashAlg::Sha256),_=>Some(HashAlg::Sha512)}
        }else{None};
        let result=tokio::time::timeout(self.deadline,handle.authenticate_certificate_with(user,certificate,hash,&mut key)).await
            .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Authentication)?;
        match result{
            client::AuthResult::Success=>{self.authenticated=true;Ok(KeyAuthentication::Complete(identity))},
            client::AuthResult::Failure{partial_success:true,remaining_methods}if allow_interactive
                &&remaining_methods.contains(&russh::MethodKind::KeyboardInteractive)=>Ok(KeyAuthentication::AdditionalStep(identity)),
            _=>Err(Failure::Authentication),
        }
    }
    async fn key_authentication(&mut self,user:&str,bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,expected:Option<&Key>,allow_interactive:bool)->Result<KeyAuthentication>{
        if self.authenticated||user.is_empty()||user.len()>256||user.chars().any(char::is_control){return Err(Failure::Authentication)}
        let mut key=crate::key_auth::PreparedKey::decode(bytes,passphrase).map_err(|error|match error{
            crate::key_auth::Failure::Passphrase=>Failure::KeyPassphrase,
            crate::key_auth::Failure::Algorithm|crate::key_auth::Failure::Cost|crate::key_auth::Failure::Format=>Failure::KeyUnsupported,
            _=>Failure::KeyInput,
        })?;
        let public=key.public().clone();let identity=Key::from_bytes(&public.to_bytes().map_err(|_|Failure::KeyInput)?)?;
        if expected.is_some_and(|expected|expected!=&identity){return Err(Failure::KeyChanged)}
        let handle=self.handle.as_mut().ok_or(Failure::Closed)?;
        let hash=if matches!(public.algorithm(),Algorithm::Rsa{..}){
            // No nested-optional SHA-1 fallback. Unknown extension support uses
            // an explicit modern offer; a rejection ends this attempt.
            let supported=tokio::time::timeout(self.deadline,handle.best_supported_rsa_hash()).await.map_err(|_|Failure::Timeout)?
                .map_err(|_|Failure::Transport)?;
            match supported{Some(Some(HashAlg::Sha256))=>Some(HashAlg::Sha256),_=>Some(HashAlg::Sha512)}
        }else{None};
        let result=tokio::time::timeout(self.deadline,handle.authenticate_publickey_with(user,public,hash,&mut key)).await
            .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Authentication)?;
        match result{
            client::AuthResult::Success=>{self.authenticated=true;Ok(KeyAuthentication::Complete(identity))},
            client::AuthResult::Failure{partial_success:true,remaining_methods}if allow_interactive
                &&remaining_methods.contains(&russh::MethodKind::KeyboardInteractive)=>Ok(KeyAuthentication::AdditionalStep(identity)),
            _=>Err(Failure::Authentication),
        }
    }
    /// The caller selects one explicit socket and one exact public key after
    /// host trust. This qualification-only route never consults SSH_AUTH_SOCK
    /// or falls back to a password, default key or another agent identity.
    #[cfg(feature="agent-qualification")]
    pub async fn agent_identity_then_interactive(&mut self,user:&str,socket:&Path,expected_blob:&[u8],
        sign_deadline:Duration,allow_interactive:bool)->Result<AgentAuthentication>{
        let signer=crate::agent_auth::SelectedAgent::connect(socket,expected_blob,self.deadline).await
            .map_err(agent_failure)?;
        self.agent_selected_identity(user,signer,sign_deadline,allow_interactive).await
    }
    #[cfg(feature="agent-qualification")]
    pub async fn agent_selected_identity(&mut self,user:&str,mut signer:crate::agent_auth::SelectedAgent,
        sign_deadline:Duration,allow_interactive:bool)->Result<AgentAuthentication>{
        if self.authenticated||user.is_empty()||user.len()>256||user.chars().any(char::is_control)
            ||sign_deadline.is_zero()||sign_deadline>Duration::from_secs(60){return Err(Failure::KeyInput)}
        let public=signer.public().clone();
        let fingerprint=public.fingerprint(HashAlg::Sha256).to_string();
        let mut handle=self.handle.take().ok_or(Failure::Closed)?;
        let hash=if matches!(public.algorithm(),Algorithm::Rsa{..}){
            let supported=tokio::time::timeout(self.deadline,handle.best_supported_rsa_hash()).await
                .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Transport)?;
            match supported{Some(Some(HashAlg::Sha256))=>Some(HashAlg::Sha256),_=>Some(HashAlg::Sha512)}
        }else{None};
        let result=tokio::time::timeout(sign_deadline,
            handle.authenticate_publickey_with(user,public,hash,&mut signer)).await
            .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Authentication)?;
        match result{
            client::AuthResult::Success=>{
                self.authenticated=true;self.handle=Some(handle);Ok(AgentAuthentication::Complete(fingerprint))
            },
            client::AuthResult::Failure{partial_success:true,remaining_methods}if allow_interactive
                &&remaining_methods.contains(&russh::MethodKind::KeyboardInteractive)=>{
                    self.handle=Some(handle);Ok(AgentAuthentication::AdditionalStep(fingerprint))
                },
            _=>Err(Failure::Authentication),
        }
    }
    pub async fn interactive_start(&mut self,user:&str)->Result<crate::interactive::Step>{
        if self.authenticated||self.interactive_started||user.is_empty()||user.len()>256||user.chars().any(char::is_control){return Err(Failure::Authentication)}
        self.interactive_started=true;
        let handle=self.handle.as_mut().ok_or(Failure::Closed)?;
        let result=tokio::time::timeout(self.deadline,handle.authenticate_keyboard_interactive_start(user,None::<String>)).await
            .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Transport)?;
        self.interactive_reply(result)
    }
    pub async fn interactive_response(&mut self,responses:Zeroizing<Vec<String>>)->Result<crate::interactive::Step>{
        if self.authenticated||!self.interactive_started{return Err(Failure::Authentication)}
        let count=self.interactive_pending.take().ok_or(Failure::Authentication)?;
        let mut responses=crate::interactive::answers(responses,count).map_err(|_|Failure::Authentication)?;
        let handle=self.handle.as_mut().ok_or(Failure::Closed)?;
        // The library owns its bounded String copies after admission; final
        // runtime/process drain contains those copies as well as our buffers.
        let result=tokio::time::timeout(self.deadline,handle.authenticate_keyboard_interactive_respond(std::mem::take(&mut *responses))).await
            .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Transport)?;
        self.interactive_reply(result)
    }
    fn interactive_reply(&mut self,reply:client::KeyboardInteractiveAuthResponse)->Result<crate::interactive::Step>{
        let step=crate::interactive::step(reply).map_err(|_|Failure::Authentication)?;
        match &step{crate::interactive::Step::Complete=>self.authenticated=true,
            crate::interactive::Step::Challenge(challenge)=>self.interactive_pending=Some(challenge.prompts.len())}
        Ok(step)
    }
    pub fn check_transport(&self)->Result<()>{
        if self.handle.as_ref().ok_or(Failure::Closed)?.is_closed(){return Err(Failure::Closed)}Ok(())
    }
    pub async fn metadata_reader(&mut self)->Result<crate::reader::Reader<ChannelStream<client::Msg>>>{
        if !self.authenticated{return Err(Failure::Authentication)}
        if self.channel_opened{return Err(Failure::Closed)}
        self.channel_opened=true;
        let handle=self.handle.take().ok_or(Failure::Closed)?;
        let reader=tokio::time::timeout(self.deadline,async{
            let channel=handle.channel_open_session().await.map_err(|_|Failure::Transport)?;
            channel.request_subsystem(true,"sftp").await.map_err(|_|Failure::Transport)?;
            let mut reader=crate::reader::Reader::new(channel.into_stream(),self.deadline);
            reader.initialize().await.map_err(|_|Failure::Transport)?;
            Ok(reader)
        }).await.map_err(|_|Failure::Timeout)??;
        self.handle=Some(handle);Ok(reader)
    }
    pub fn check_open(&self)->Result<()>{
        if !self.authenticated||self.handle.as_ref().ok_or(Failure::Closed)?.is_closed(){return Err(Failure::Closed)}Ok(())
    }
    /// Experimental requested body read. One mutable borrow owns the entire
    /// channel lifetime; the metadata reader and its opcode gate stay separate.
    /// The worker must still drain this SSH connection/runtime on cancellation.
    #[cfg(feature="download-qualification")]
    pub async fn receive_file<T:crate::download::Sink>(&mut self,path:&str,expected:crate::wire::Metadata,limits:crate::download::Limits,sink:T)
        ->std::result::Result<crate::download::Receipt,ReceiveFailure>
    {
        self.receive_file_controlled(path,expected,limits,None,sink).await
    }
    #[cfg(feature="download-qualification")]
    pub async fn receive_file_controlled<T:crate::download::Sink>(&mut self,path:&str,expected:crate::wire::Metadata,limits:crate::download::Limits,
        stop:Option<Arc<AtomicBool>>,mut sink:T)->std::result::Result<crate::download::Receipt,ReceiveFailure>{
        crate::download::admitted(path,expected,limits).map_err(ReceiveFailure::Body)?;
        self.check_open().map_err(ReceiveFailure::Connection)?;
        let handle=self.handle.take().ok_or(ReceiveFailure::Connection(Failure::Closed))?;
        let opening=tokio::time::timeout(self.deadline,async{
            let channel=handle.channel_open_session().await.map_err(|_|Failure::Transport)?;
            channel.request_subsystem(true,"sftp").await.map_err(|_|Failure::Transport)?;
            Ok(channel.into_stream())
        });
        let opened=tokio::select!{biased;
            _=crate::download::wait_for_stop(stop.clone())=>Err(ReceiveFailure::Body(crate::download::Failure::Stopped)),
            result=opening=>result.map_err(|_|Failure::Timeout).and_then(|r|r).map_err(ReceiveFailure::Connection),
        };
        self.handle=Some(handle);
        let stream=opened?;
        crate::download::notify_checkpoint(&mut sink,&stop,limits.request_deadline).await.map_err(ReceiveFailure::Body)?;
        crate::download::receive_controlled(stream,path,expected,limits,stop,sink).await.map_err(ReceiveFailure::Body)
    }
    /// Isolated immutable-generated-source experiment. This cannot read a
    /// native file, and no ordinary helper entrypoint exposes this capability.
    #[cfg(feature="upload-qualification")]
    pub async fn send_generated(&mut self,target:&crate::upload::Target,source:&[u8],limits:crate::upload::Limits,
        stop:Option<Arc<AtomicBool>>)->std::result::Result<crate::upload::Receipt,SendFailure>{
        let admission=upload_admission_failure;
        crate::upload::admitted_generated(source.len(),limits).map_err(admission)?;
        let stream=self.upload_channel(stop.clone()).await?;
        crate::upload::send_generated(stream,target,source,limits,stop).await.map_err(SendFailure::Body)
    }
    #[cfg(feature="upload-qualification")]
    pub(crate) async fn send_upload_source<T:crate::upload::Source>(&mut self,target:&crate::upload::Target,source:T,limits:crate::upload::Limits,
        stop:Option<Arc<AtomicBool>>)->std::result::Result<crate::upload::Receipt,SendFailure>{
        crate::upload::admitted_source(source.size(),limits).map_err(upload_admission_failure)?;
        let stream=self.upload_channel(stop.clone()).await?;
        crate::upload::send_source_exclusive(stream,target,source,limits,stop).await.map_err(SendFailure::Body)
    }
    #[cfg(feature="inplace-edit-v1")]
    pub(crate) async fn open_inplace_v1<T:crate::upload::inplace_v1::ReadSink>(&mut self,path:String,expected:crate::wire::Metadata,sink:T,
        limits:crate::upload::Limits,stop:Option<Arc<AtomicBool>>)->std::result::Result<crate::upload::inplace_v1::Session<ChannelStream<client::Msg>>,crate::upload::Failure>{
        let stream=self.upload_channel(stop.clone()).await.map_err(|_|crate::upload::Failure::Io)?;
        crate::upload::inplace_v1::Session::open(stream,path,expected,sink,limits,stop).await
    }
    /// Startup3 only. A typed no-header refusal is returned only after the
    /// actual new subsystem channel has closed on this SAME SSH connection.
    #[cfg(feature="inplace-edit-v1")]
    pub(crate) async fn open_inplace_v3<T:crate::upload::inplace_v1::ReadSink>(&mut self,path:String,expected:crate::wire::Metadata,sink:T,
        limits:crate::upload::Limits,stop:Option<Arc<AtomicBool>>)->std::result::Result<crate::upload::inplace_v1::Session<ChannelStream<client::Msg>>,crate::upload::inplace_v1::OpenFailure>{
        use crate::upload::{Failure as F,inplace_v1::{OpenFailure,PreflightOpenFailure}};
        let watch=self.inplace_closes.begin()?;
        let stream=self.upload_channel_observed(stop.clone(),Some(&watch)).await.map_err(|error|OpenFailure::Fatal(match error {
            SendFailure::Body(value)=>value.cause,
            SendFailure::Connection(Failure::Timeout)=>F::Timeout,
            _=>F::Io,
        }))?;
        match crate::upload::inplace_v1::Session::open_preflight(stream,path,expected,sink,limits,stop.clone()).await {
            Ok(session)=>Ok(session),
            Err(PreflightOpenFailure::Rejected{reason,mut stream})=>{
                // EOF leaves russh's established-channel entry intact. Keep
                // this exact stream owned until the peer Close callback; Drop
                // would queue local Close and erase that entry before the ACK.
                let end=tokio::time::Instant::now()+self.deadline;
                tokio::select!{biased;
                    _=crate::upload::wait_stop(stop.clone())=>return Err(OpenFailure::Fatal(F::Stopped)),
                    value=tokio::time::timeout_at(end,tokio::io::AsyncWriteExt::shutdown(&mut stream))=>{
                        value.map_err(|_|F::Timeout)?.map_err(|_|F::Io)?;
                    },
                }
                // EOF send is not proof. One shared deadline bounds EOF+Close.
                let remaining=end.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero(){return Err(OpenFailure::Fatal(F::Timeout))}
                watch.wait(stop,remaining).await?;
                if tokio::time::Instant::now()>=end{return Err(OpenFailure::Fatal(F::Timeout))}
                drop(stream); // Only AFTER the actual authenticated peer Close.
                Err(OpenFailure::Rejected(reason))
            },
            Err(PreflightOpenFailure::Fatal(cause))=>Err(OpenFailure::Fatal(cause)),
        }
    }
    #[cfg(feature="original-edit-qualification")]
    pub(crate) async fn read_original<T:crate::upload::original::ReadSink>(&mut self,path:&str,expected:crate::wire::Metadata,sink:T,
        limits:crate::upload::Limits,stop:Option<Arc<AtomicBool>>)->std::result::Result<(crate::upload::original::Observed,[u8;32]),crate::upload::original::Cause>{
        let stream=self.upload_channel(stop.clone()).await.map_err(|_|crate::upload::original::Cause::Wire(crate::upload::Failure::Io))?;
        crate::upload::original::read(stream,path,expected,sink,limits,stop).await
    }
    #[cfg(feature="original-edit-qualification")]
    pub(crate) async fn save_original<T:crate::upload::original::Control>(&mut self,baseline:&crate::upload::original::Baseline,target:&crate::upload::original::Target,
        source:T,limits:crate::upload::Limits,stop:Option<Arc<AtomicBool>>)->std::result::Result<crate::upload::original::Receipt,crate::upload::original::Interrupted>{
        use crate::upload::original::{Cause,Phase,Facts,Interrupted};
        let stream=self.upload_channel(stop.clone()).await.map_err(|_|Interrupted{cause:Cause::Wire(crate::upload::Failure::Io),phase:Phase::Admission,facts:Facts::default()})?;
        crate::upload::original::send(stream,baseline,target,source,limits,stop).await
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    pub(crate) async fn send_upload_folder<T:crate::folder_upload::Source>(&mut self,directory:&str,name:&str,nonce:[u8;16],manifest:&crate::folder_upload::Manifest,
        source:T,limits:crate::upload::Limits,stop:Option<Arc<AtomicBool>>)->std::result::Result<crate::folder_upload::Receipt,crate::folder_upload::Interrupted>{
        let stream=self.upload_channel(stop.clone()).await.map_err(|error|{
            let cause=match error{SendFailure::Body(v)=>v.cause,SendFailure::Connection(Failure::Timeout)=>crate::upload::Failure::Timeout,_=>crate::upload::Failure::Io};
            crate::folder_upload::Interrupted::admission(cause)
        })?;
        crate::folder_upload::send(stream,directory,name,nonce,manifest,source,limits,stop).await
    }
    #[cfg(feature="upload-qualification")]
    async fn upload_channel(&mut self,stop:Option<Arc<AtomicBool>>)->std::result::Result<ChannelStream<client::Msg>,SendFailure>{
        self.upload_channel_observed(stop, None).await
    }
    #[cfg(feature="remote-action-qualification")]
    pub(crate) async fn copy_file_same_session(&mut self,target:&crate::upload::server_copy::Target,
        selected:crate::wire::Metadata,stop:Option<Arc<AtomicBool>>)
        ->std::result::Result<crate::upload::server_copy::Receipt,crate::upload::server_copy::Interrupted>{
        use crate::upload::{Failure as U,server_copy::{Interrupted,Phase}};
        let stream=self.upload_channel(stop.clone()).await.map_err(|error|{
            let cause=match error{SendFailure::Body(value)=>value.cause,
                SendFailure::Connection(Failure::Timeout)=>U::Timeout,_=>U::Io};
            Interrupted{cause,phase:Phase::Admission,stage_may_exist:false,publication_may_have_happened:false}
        })?;
        crate::upload::server_copy::send(stream,target,selected,crate::upload::Limits::default(),stop).await
    }
    #[cfg(feature="upload-qualification")]
    async fn upload_channel_observed(&mut self,stop:Option<Arc<AtomicBool>>,
        #[cfg(feature="inplace-edit-v1")]watch:Option<&CloseWatch>,
        #[cfg(not(feature="inplace-edit-v1"))]_watch:Option<()>)
        ->std::result::Result<ChannelStream<client::Msg>,SendFailure>{
        let admission=upload_admission_failure;
        if stop.as_ref().is_some_and(|v|v.load(Ordering::Acquire)){return Err(admission(crate::upload::Failure::Stopped))}
        self.check_open().map_err(SendFailure::Connection)?;
        let handle=self.handle.take().ok_or(SendFailure::Connection(Failure::Closed))?;
        let opening=tokio::time::timeout(self.deadline,async{
            let channel=handle.channel_open_session().await.map_err(|_|Failure::Transport)?;
            #[cfg(feature="inplace-edit-v1")]
            if let Some(watch)=watch{watch.bind(channel.id().number()).map_err(|_|Failure::Closed)?;}
            channel.request_subsystem(true,"sftp").await.map_err(|_|Failure::Transport)?;
            Ok(channel.into_stream())
        });
        let opened=tokio::select!{biased;
            _=crate::upload::wait_stop(stop.clone())=>Err(admission(crate::upload::Failure::Stopped)),
            result=opening=>result.map_err(|_|Failure::Timeout).and_then(|r|r).map_err(SendFailure::Connection),
        };
        self.handle=Some(handle);
        opened
    }
    pub async fn ping(&self)->Result<()>{
        self.check_open()?;
        let handle=self.handle.as_ref().ok_or(Failure::Closed)?;
        tokio::time::timeout(self.deadline.min(Duration::from_secs(5)),handle.send_ping()).await
            .map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Transport)?;
        self.check_open()
    }
    /// A queued disconnect is not a drained task. Await the actual SSH Handle;
    /// failure/deadline still requires dropping this connection's owned runtime.
    pub async fn close(mut self)->Result<Drain>{
        let handle=self.handle.take().ok_or(Failure::Closed)?;
        tokio::time::timeout(self.deadline,async{
            let queued=handle.disconnect(russh::Disconnect::ByApplication,"Client closed","").await.is_ok();
            // russh 0.64.1 returns Err(Disconnect) after its own requested
            // disconnect: run_inner starts with that result and only changes
            // it to Ok for a received peer SSH disconnect. Accept that exact
            // local exit only when our request was queued. This is task
            // termination, never a claim that the peer acknowledged Close.
            // Every other task/transport error remains distinct from a drain.
            let ended_normally=match handle.await{
                Ok(())=>true,
                Err(russh::Error::Disconnect) if queued=>true,
                Err(_)=>false,
            };
            Drain{disconnect_queued:queued,ssh_task_ended:true,ended_normally}
        }).await.map_err(|_|Failure::Timeout)
    }
}

#[cfg(feature="upload-qualification")]
fn upload_admission_failure(cause:crate::upload::Failure)->SendFailure{
    SendFailure::Body(crate::upload::Interrupted{cause,phase:crate::upload::Phase::Admission,temporary_may_exist:false,publication_may_have_happened:false})
}

/// Pause only on the worker-owned host-review phase, not arbitrary input or
/// callback traffic. All pre/post-review network time consumes one budget.
async fn network_budget<F,T>(operation:F,mut phases:watch::Receiver<bool>,budget:Duration)->Result<T>
where F:std::future::Future<Output=Result<T>>{
    tokio::pin!(operation);let mut paused=*phases.borrow_and_update();let mut remaining=budget;
    let mut measured=tokio::time::Instant::now();let timer=tokio::time::sleep(remaining);tokio::pin!(timer);
    loop{tokio::select!{biased;
        change=phases.changed()=>{
            if change.is_err(){return Err(Failure::Transport)}let now=tokio::time::Instant::now();
            if !paused{remaining=remaining.saturating_sub(now-measured);if remaining.is_zero(){return Err(Failure::Timeout)}}
            paused=*phases.borrow_and_update();measured=now;timer.as_mut().reset(now+remaining);
        },
        _=&mut timer,if !paused=>return Err(Failure::Timeout),
        result=&mut operation=>return result,
    }}
}

#[cfg(test)]
mod tests {
    use super::*;
    fn challenge(previous:Option<Key>)->Challenge{
        Challenge{peer:Peer::new("generated.example",22,[1;16]).unwrap(),current:key(1),previous}
    }
    fn key(value:u8)->Key{Key{bytes:vec![value;32],algorithm:"ssh-ed25519".into(),fingerprint:format!("SHA256:generated-{value}")}}
    #[test]fn exact_decision_cannot_cross_host_port_nonce_or_key(){
        let c=challenge(None);assert!(c.accepts(&Decision{challenge:c.clone(),action:Action::ConnectOnce}));
        for field in 0..4{let mut other=c.clone();match field{0=>other.peer.host="other.example".into(),
            1=>other.peer.port=2222,2=>other.peer.nonce=[2;16],_=>other.current=key(2)};
            assert!(!c.accepts(&Decision{challenge:other,action:Action::ConnectOnce}));}
    }
    #[test]fn changed_key_cannot_use_first_or_matching_actions(){
        let c=challenge(Some(key(2)));assert_eq!(c.kind(),TrustKind::Changed);
        for action in [Action::Reject,Action::ConnectOnce,Action::Remember,Action::UseMatching]{assert!(!c.accepts(&Decision{challenge:c.clone(),action}));}
        assert!(c.accepts(&Decision{challenge:c.clone(),action:Action::ReplaceVerified}));
        let matching=challenge(Some(key(1)));assert!(matching.accepts(&Decision{challenge:matching.clone(),action:Action::UseMatching}));
    }
    #[test]fn frozen_identity_rejects_paths_controls_and_empty_tokens(){
        for host in ["", "user@host","a/b","host.","a..b","-host","host\n"]{assert_eq!(Peer::new(host,22,[1;16]),Err(Failure::Identity));}
        assert!(Peer::new("host",0,[1;16]).is_err());assert!(Peer::new("host",22,[0;16]).is_err());
        assert_eq!(Peer::new("HOST",22,[1;16]).unwrap().host(),"host");
        assert_eq!(Peer::new("::1",22,[1;16]).unwrap().host(),"::1");
    }
    #[test]fn modern_policy_retains_strict_kex_without_legacy_fallback(){
        let p=modern_preferences();assert!(p.kex.contains(&russh::kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT));
        assert_eq!(p.key.as_ref(),[Algorithm::Ed25519]);assert!(p.host_key_certificates.is_empty());
        assert_eq!(p.compression.as_ref(),[russh::compression::NONE]);
        assert_eq!(p.cipher.as_ref(),[russh::cipher::AES_256_GCM,russh::cipher::AES_128_GCM]);
    }
    #[test]fn profile_algorithms_add_modern_compatibility_without_sha1_or_certificates(){
        let p=profile_preferences();assert!(p.kex.contains(&russh::kex::ECDH_SHA2_NISTP256));
        assert!(p.kex.contains(&russh::kex::DH_G14_SHA256));assert!(p.key.contains(&Algorithm::Rsa{hash:Some(HashAlg::Sha512)}));
        assert!(p.key.contains(&Algorithm::Rsa{hash:Some(HashAlg::Sha256)}));
        assert!(!p.key.contains(&Algorithm::Rsa{hash:None}));assert!(!p.key.contains(&Algorithm::Dsa));
        assert!(p.host_key_certificates.is_empty());assert_eq!(p.mac.as_ref(),[russh::mac::HMAC_SHA256_ETM]);
    }
    #[test]fn saved_public_key_is_bounded_canonical_and_derived(){
        for bytes in [vec![],vec![0;16385],vec![1;50]]{assert_eq!(Key::from_bytes(&bytes),Err(Failure::Key));}
        let private=russh::keys::PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let bytes=private.public_key().to_bytes().unwrap();let key=Key::from_bytes(&bytes).unwrap();
        assert_eq!(key.bytes(),bytes);assert_eq!(key.algorithm(),"ssh-ed25519");
        assert_eq!(key.fingerprint(),private.public_key().fingerprint(HashAlg::Sha256).to_string());
        let mut trailing=bytes.clone();trailing.push(0);assert_eq!(Key::from_bytes(&trailing),Err(Failure::Key));
    }
    #[tokio::test]async fn human_review_pauses_but_does_not_reset_network_budget(){
        let(tx,rx)=watch::channel(false);let budget=Duration::from_millis(80);
        let operation=async{
            tokio::time::sleep(Duration::from_millis(10)).await;tx.send(true).unwrap();
            tokio::time::sleep(Duration::from_millis(150)).await;tx.send(false).unwrap();
            tokio::time::sleep(Duration::from_millis(10)).await;Ok(7)
        };assert_eq!(network_budget(operation,rx,budget).await,Ok(7));
        let(tx,rx)=watch::channel(false);let operation=async{
            tokio::time::sleep(Duration::from_millis(50)).await;tx.send(true).unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;tx.send(false).unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;Ok(7)
        };assert_eq!(network_budget(operation,rx,budget).await,Err(Failure::Timeout));
    }
    #[tokio::test]async fn stalled_network_and_stalled_review_keep_distinct_bounds(){
        let(_tx,rx)=watch::channel(false);
        assert_eq!(network_budget(async{std::future::pending::<Result<()>>().await},rx,Duration::from_millis(20)).await,Err(Failure::Timeout));
        let(_tx,rx)=watch::channel(true);
        // Handler's separate review deadline ends the operation, while a
        // paused network clock must not incorrectly win first.
        let operation=async{tokio::time::sleep(Duration::from_millis(60)).await;Err::<(),_>(Failure::Trust)};
        assert_eq!(network_budget(operation,rx,Duration::from_millis(20)).await,Err(Failure::Trust));
    }
}

#[cfg(all(test,feature="inplace-edit-v1"))]mod startup3_close_controls;
