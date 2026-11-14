//! Isolated private-channel worker. Not bundled or ordinarily activated.
use crate::{catalog,catalog_owner::{Writer,ThreadOwner,Authority},ipc::{self,Command,Mode},reader,ssh::{self,Decision,Verified}};
use std::{future::Future,io::Write,os::fd::FromRawFd,sync::{Arc,Mutex,atomic::{AtomicBool,AtomicU8,Ordering}},time::Duration};
use tokio::{io::{AsyncReadExt,AsyncWriteExt},net::{UnixStream,unix::{OwnedReadHalf,OwnedWriteHalf}},sync::{mpsc,Notify}};
use zeroize::Zeroizing;
#[cfg(feature="agent-qualification")]use std::path::Path;
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]mod folder_upload_control;

#[cfg(feature="original-edit-qualification")]mod original_control;
#[cfg(feature="inplace-edit-v1")]mod inplace_control;
#[cfg(feature="remote-action-qualification")]mod action_control;

#[derive(Debug,Clone,Copy,PartialEq,Eq)]
#[repr(u8)]pub enum Issue{Stopped=0,InputClosed=1,Invalid=2,Deadline=3,Transport=4,Authentication=5,Trust=6,Phase=7,Denied=8,Storage=9,
    #[cfg(any(feature="download-qualification",feature="upload-qualification"))]SourceChanged=10,
    KeyInput=11,KeyPassphrase=12,KeyUnsupported=13,KeyChanged=14,ForwardDenied=15,
    CertificateExpired=16,CertificateNotYetValid=17}
#[derive(Clone)]struct Stop{reason:Arc<AtomicU8>,wake:Arc<Notify>,catalog:Arc<AtomicBool>}
impl Stop{
    fn new()->Self{Self{reason:Arc::new(AtomicU8::new(255)),wake:Arc::new(Notify::new()),catalog:Arc::new(AtomicBool::new(false))}}
    fn set(&self,issue:Issue){let _=self.reason.compare_exchange(255,issue as u8,Ordering::SeqCst,Ordering::SeqCst);self.catalog.store(true,Ordering::Release);self.wake.notify_waiters();}
    fn first(&self,fallback:Issue)->Issue{self.set(fallback);issue(self.reason.load(Ordering::SeqCst))}
    async fn wait(&self)->Issue{loop{
        let wake=self.wake.notified();tokio::pin!(wake);wake.as_mut().enable();
        let reason=self.reason.load(Ordering::SeqCst);if reason!=255{return issue(reason)}wake.await;
    }}
}
fn issue(value:u8)->Issue{match value{0=>Issue::Stopped,1=>Issue::InputClosed,2=>Issue::Invalid,3=>Issue::Deadline,
    4=>Issue::Transport,5=>Issue::Authentication,6=>Issue::Trust,7=>Issue::Phase,8=>Issue::Denied,9=>Issue::Storage,
    #[cfg(any(feature="download-qualification",feature="upload-qualification"))]10=>Issue::SourceChanged,
    11=>Issue::KeyInput,12=>Issue::KeyPassphrase,13=>Issue::KeyUnsupported,14=>Issue::KeyChanged,15=>Issue::ForwardDenied,
    16=>Issue::CertificateExpired,17=>Issue::CertificateNotYetValid,_=>Issue::Invalid}}
fn ssh_error(error:ssh::Failure)->Issue{match error{ssh::Failure::Authentication=>Issue::Authentication,
    ssh::Failure::Trust|ssh::Failure::Key=>Issue::Trust,ssh::Failure::Timeout=>Issue::Deadline,
    ssh::Failure::KeyInput=>Issue::KeyInput,ssh::Failure::KeyPassphrase=>Issue::KeyPassphrase,
    ssh::Failure::KeyUnsupported=>Issue::KeyUnsupported,ssh::Failure::KeyChanged=>Issue::KeyChanged,
    ssh::Failure::CertificateExpired=>Issue::CertificateExpired,ssh::Failure::CertificateNotYetValid=>Issue::CertificateNotYetValid,
    ssh::Failure::ForwardDenied=>Issue::ForwardDenied,
    #[cfg(feature="agent-qualification")]ssh::Failure::AgentDenied=>Issue::Denied,
    _=>Issue::Transport}}
#[cfg(feature="agent-qualification")]
fn agent_error(error:crate::agent_auth::Failure)->Issue{match error{
    crate::agent_auth::Failure::Input=>Issue::KeyInput,
    crate::agent_auth::Failure::Identity=>Issue::KeyChanged,
    crate::agent_auth::Failure::Algorithm=>Issue::KeyUnsupported,
    crate::agent_auth::Failure::Timeout=>Issue::Deadline,
    crate::agent_auth::Failure::Denied=>Issue::Denied,
    _=>Issue::Transport,
}}
fn read_error(error:reader::Failure)->Issue{match error{reader::Failure::Timeout=>Issue::Deadline,
    reader::Failure::Status(3)=>Issue::Denied,_=>Issue::Transport}}
async fn guarded<F,T>(stop:&Stop,future:F)->Result<T,Issue>where F:Future<Output=Result<T,Issue>>{
    tokio::select!{biased;reason=stop.wait()=>Err(reason),value=future=>value}
}
/// Authentication has ended before this timer is constructed. An idle check
/// never lists a directory or reads a file; it observes the SSH task and sends
/// at most one bounded keepalive while the serial command owner is idle.
async fn next_authenticated(input:&mut mpsc::Receiver<Command>,stop:&Stop,ssh:&Verified,
    next_ping:&mut tokio::time::Instant)->Result<Command,Issue>{
    loop{
        tokio::select!{biased;
            reason=stop.wait()=>return Err(reason),
            command=input.recv()=>return command.ok_or(Issue::InputClosed),
            _=tokio::time::sleep(Duration::from_secs(1))=>{
                ssh.check_open().map_err(ssh_error)?;
                if tokio::time::Instant::now()>=*next_ping{
                    guarded(stop,async{ssh.ping().await.map_err(ssh_error)}).await?;
                    *next_ping=tokio::time::Instant::now()+Duration::from_secs(15);
                }
            }
        }
    }
}
async fn frame(input:&mut OwnedReadHalf)->Result<Zeroizing<Vec<u8>>,Issue>{
    // Idle input is allowed while a user reviews a host. Once a prefix starts,
    // a partial command has a deadline and cannot pin the worker indefinitely.
    let first=input.read_u8().await.map_err(|_|Issue::InputClosed)?;
    let mut prefix=[first,0,0,0];
    tokio::time::timeout(Duration::from_secs(5),input.read_exact(&mut prefix[1..])).await
        .map_err(|_|Issue::Deadline)?.map_err(|_|Issue::InputClosed)?;
    let size=u32::from_be_bytes(prefix) as usize;
    if !(ipc::HEADER..=ipc::MAX_FRAME).contains(&size){return Err(Issue::Invalid)}
    let mut bytes=Zeroizing::new(vec![0u8;size]);
    tokio::time::timeout(Duration::from_secs(5),input.read_exact(&mut bytes)).await
        .map_err(|_|Issue::Deadline)?.map_err(|_|Issue::InputClosed)?;Ok(bytes)
}
struct WriteState{session:Option<[u8;16]>,sequence:u64,valid:bool,mode:Mode}
struct Output{stream:OwnedWriteHalf,state:Arc<Mutex<WriteState>>}
#[cfg(feature="upload-qualification")]
struct UploadInput<'a>{output:&'a mut Output,input:&'a mut mpsc::Receiver<Command>,request:[u8;16],size:u64}
#[cfg(feature="upload-qualification")]
impl crate::upload::Source for UploadInput<'_>{
    fn size(&self)->u64{self.size}
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>,crate::upload::Failure>{
        use crate::upload::Failure as U;
        let mut payload=self.request.to_vec();payload.extend(offset.to_be_bytes());payload.extend((count as u32).to_be_bytes());
        self.output.event(131,&payload).await.map_err(upload_local_issue)?;
        let Some(Command::SourceBytes{request,offset:actual,mut bytes})=self.input.recv().await else{return Err(U::Protocol)};
        if request!=self.request||actual!=offset||bytes.len()!=count{return Err(U::SourceChanged)}
        Ok(std::mem::take(&mut*bytes))
    }
    async fn permit_publication(&mut self,digest:[u8;32])->Result<(),crate::upload::Failure>{
        use crate::upload::Failure as U;
        let mut payload=self.request.to_vec();payload.extend(self.size.to_be_bytes());payload.extend(digest);
        self.output.event(132,&payload).await.map_err(upload_local_issue)?;
        let Some(Command::PublicationPermit{request,digest:checked})=self.input.recv().await else{return Err(U::Protocol)};
        if request!=self.request||checked!=digest{return Err(U::SourceChanged)}Ok(())
    }
}
#[cfg(feature="upload-qualification")]
fn upload_local_issue(error:Issue)->crate::upload::Failure{
    use crate::upload::Failure as U;
    match error{Issue::Stopped=>U::Stopped,Issue::Deadline=>U::Timeout,Issue::InputClosed=>U::Io,_=>U::Protocol}
}
#[cfg(feature="upload-qualification")]
fn upload_failure(error:crate::ssh::SendFailure)->(Issue,crate::upload::Interrupted){
    use crate::{upload::{Failure as U,Phase,Interrupted},ssh::SendFailure as S};
    match error{
        S::Connection(error)=>(ssh_error(error),Interrupted{cause:U::Io,phase:Phase::Admission,temporary_may_exist:false,publication_may_have_happened:false}),
        S::Body(error)=>{
            let issue=match error.cause{U::Stopped=>Issue::Stopped,U::Timeout=>Issue::Deadline,U::SourceChanged=>Issue::SourceChanged,U::Status(3)=>Issue::Denied,U::Input|U::Protocol=>Issue::Invalid,_=>Issue::Transport};(issue,error)
        }
    }
}
#[cfg(feature="upload-qualification")]
fn upload_observed_failure(stop:&Stop,error:crate::ssh::SendFailure)->(Issue,crate::upload::Interrupted){
    let(fallback,mut observation)=upload_failure(error);let first=stop.reason.load(Ordering::SeqCst);
    if first==255{return(fallback,observation)}
    let reason=issue(first);observation.cause=upload_local_issue(reason);(reason,observation)
}
#[cfg(feature="upload-qualification")]
fn upload_interruption_bytes(request:[u8;16],error:&crate::upload::Interrupted)->Vec<u8>{
    use crate::upload::{Failure as U,Phase as P};
    let cause=match error.cause{U::Input=>0,U::Io=>1,U::Timeout=>2,U::Stopped=>3,U::Truncated=>4,U::Protocol=>5,U::Status(_)=>6,U::Conflict=>7,U::UnsupportedSync=>8,U::Verification=>9,U::SourceChanged=>10};
    let phase=match error.phase{P::Admission=>0,P::Negotiation=>1,P::Destination=>2,P::OpeningTemporary=>3,P::Writing=>4,P::Readback=>5,P::Permissions=>6,P::Syncing=>7,P::Closing=>8,P::TemporaryCheck=>9,P::Authorization=>10,P::Publishing=>11,P::FinalReadback=>12,P::Shutdown=>13,P::OpeningFinal=>14};
    let mut bytes=request.to_vec();bytes.extend([cause,phase,u8::from(error.temporary_may_exist),u8::from(error.publication_may_have_happened)]);
    bytes.extend((if let U::Status(code)=error.cause{code}else{0}).to_be_bytes());bytes
}
#[cfg(feature="download-qualification")]
struct DownloadOutput<'a>{output:&'a mut Output,request:[u8;16],checkpoints:bool,last:Option<std::time::Instant>}
#[cfg(feature="download-qualification")]
impl crate::download::Sink for DownloadOutput<'_>{
    async fn consume(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),()>{
        let mut payload=self.request.to_vec();payload.extend(offset.to_be_bytes());ipc::field(&mut payload,&bytes).map_err(|_|())?;
        self.output.event(121,&payload).await.map_err(|_|())
    }
    async fn checkpoint(&mut self)->Result<(),()>{
        if !self.checkpoints||self.last.is_some_and(|at|at.elapsed()<Duration::from_millis(250)){return Ok(())}
        self.output.event(123,&self.request).await.map_err(|_|())?;self.last=Some(std::time::Instant::now());Ok(())
    }
}
#[cfg(feature="download-qualification")]
fn download_error(error:crate::ssh::ReceiveFailure)->Issue{
    use crate::{download::Failure as D,ssh::ReceiveFailure as R};
    match error{R::Connection(e)=>ssh_error(e),R::Body(D::Changed)=>Issue::SourceChanged,
        R::Body(D::Stopped)=>Issue::Stopped,
        R::Body(D::Timeout)=>Issue::Deadline,R::Body(D::Status(3))=>Issue::Denied,
        R::Body(D::Input)=>Issue::Invalid,_=>Issue::Transport}
}
#[cfg(feature="folder-download-qualification")]
fn folder_error(error:crate::folder_download::Failure)->Issue{
    use crate::folder_download::Failure as F;
    match error{F::Input|F::Limit=>Issue::Invalid,F::Changed|F::Metadata(reader::Failure::Status(2))=>Issue::SourceChanged,
        F::Metadata(error)=>read_error(error),F::Output=>Issue::InputClosed}
}
#[cfg(feature="folder-download-qualification")]
struct FolderProgress<'a>{output:&'a mut Output,request:[u8;16],phase:u8,last:&'a mut Option<std::time::Instant>}
#[cfg(feature="folder-download-qualification")]
impl crate::folder_download::Progress for FolderProgress<'_>{
    async fn changed(&mut self,nodes:usize,bytes:u64)->Result<(),crate::folder_download::Failure>{
        if self.last.is_some_and(|at|at.elapsed()<Duration::from_millis(250)){return Ok(())}
        let mut payload=self.request.to_vec();payload.push(self.phase);payload.extend((nodes as u32).to_be_bytes());payload.extend(bytes.to_be_bytes());
        self.output.event(151,&payload).await.map_err(|_|crate::folder_download::Failure::Output)?;
        *self.last=Some(std::time::Instant::now());Ok(())
    }
}
#[cfg(feature="folder-download-qualification")]
struct FolderOutput<'a>{output:&'a mut Output,request:[u8;16],ordinal:u32,last:&'a mut Option<std::time::Instant>}
#[cfg(feature="folder-download-qualification")]
impl crate::download::Sink for FolderOutput<'_>{
    async fn consume(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),()>{
        let mut payload=self.request.to_vec();payload.extend(self.ordinal.to_be_bytes());payload.extend(offset.to_be_bytes());
        ipc::field(&mut payload,&bytes).map_err(|_|())?;self.output.event(156,&payload).await.map_err(|_|())
    }
    async fn checkpoint(&mut self)->Result<(),()>{
        if self.last.is_some_and(|at|at.elapsed()<Duration::from_millis(250)){return Ok(())}
        let mut payload=self.request.to_vec();payload.push(2);payload.extend(0u32.to_be_bytes());payload.extend(0u64.to_be_bytes());
        self.output.event(151,&payload).await.map_err(|_|())?;*self.last=Some(std::time::Instant::now());Ok(())
    }
}
impl Output{
    async fn event(&mut self,kind:u8,payload:&[u8])->Result<(),Issue>{
        if payload.len()>ipc::MAX_FRAME-ipc::HEADER{return Err(Issue::Invalid)}
        let mut bytes={let mut state=self.state.lock().map_err(|_|Issue::Invalid)?;
            if !state.valid{return Err(Issue::Invalid)}let session=state.session.ok_or(Issue::Invalid)?;
            let bytes=ipc::header_for(state.mode,session,state.sequence,kind);state.valid=false;bytes};
        bytes.extend(payload);
        tokio::time::timeout(Duration::from_millis(500),async{
            self.stream.write_u32(bytes.len()as u32).await?;self.stream.write_all(&bytes).await
        }).await.map_err(|_|Issue::Deadline)?.map_err(|_|Issue::InputClosed)?;
        let mut state=self.state.lock().map_err(|_|Issue::Invalid)?;
        state.sequence=state.sequence.checked_add(1).ok_or(Issue::Invalid)?;state.valid=true;Ok(())
    }
    async fn challenge(&mut self,challenge:&ssh::Challenge,outer:Option<[u8;16]>)->Result<(),Issue>{
        let mut bytes=outer.map_or_else(Vec::new,|token|token.to_vec());
        bytes.push(match challenge.kind(){ssh::TrustKind::First=>1,ssh::TrustKind::Matching=>2,ssh::TrustKind::Changed=>3});
        ipc::field(&mut bytes,challenge.peer.host().as_bytes()).map_err(|_|Issue::Invalid)?;
        bytes.extend(challenge.peer.port().to_be_bytes());ipc::field(&mut bytes,challenge.current.bytes()).map_err(|_|Issue::Invalid)?;
        ipc::field(&mut bytes,challenge.previous.as_ref().map_or(&[],ssh::Key::bytes)).map_err(|_|Issue::Invalid)?;
        self.event(if outer.is_some(){142}else{100},&bytes).await
    }
    async fn row(&mut self,generation:[u8;16],entry:crate::wire::Entry)->Result<(),Issue>{
        let metadata=entry.metadata;let mut b=generation.to_vec();
        b.push(u8::from(metadata.size.is_some())|u8::from(metadata.modified.is_some())<<1|u8::from(metadata.permissions.is_some())<<2);
        b.extend(metadata.size.unwrap_or(0).to_be_bytes());b.extend(metadata.modified.unwrap_or(0).to_be_bytes());
        b.extend(metadata.permissions.unwrap_or(0).to_be_bytes());ipc::field(&mut b,entry.name.as_bytes()).map_err(|_|Issue::Invalid)?;
        self.event(104,&b).await
    }
    async fn snapshot(&mut self,kind:u8,generation:[u8;16],snapshot:catalog::Snapshot,path:Option<&str>)->Result<(),Issue>{
        let mut b=generation.to_vec();if let Some(path)=path{ipc::field(&mut b,path.as_bytes()).map_err(|_|Issue::Invalid)?;}
        snapshot_bytes(&mut b,snapshot);self.event(kind,&b).await
    }
    async fn page(&mut self,page:ipc::Page,snapshot:catalog::Snapshot,rows:Vec<catalog::Row>)->Result<(),Issue>{
        let mut b=page.request.to_vec();b.extend(page.generation);snapshot_bytes(&mut b,snapshot);b.extend((page.offset as u64).to_be_bytes());
        self.event(114,&b).await?;let count=rows.len();
        for row in rows{let e=row.entry;let mut b=page.request.to_vec();b.extend((row.observation as u64).to_be_bytes());
            b.push(u8::from(e.size.is_some())|u8::from(e.modified.is_some())<<1|u8::from(e.mode.is_some())<<2);
            b.extend(e.size.unwrap_or(0).to_be_bytes());b.extend(e.modified.unwrap_or(0).to_be_bytes());b.extend(e.mode.unwrap_or(0).to_be_bytes());
            ipc::field(&mut b,e.name.as_bytes()).map_err(|_|Issue::Invalid)?;self.event(115,&b).await?;
        }
        let mut b=page.request.to_vec();b.extend((count as u32).to_be_bytes());self.event(116,&b).await
    }
    async fn filtered_page(&mut self,page:ipc::Page,find:&catalog::Find,rows:Vec<catalog::Row>)->Result<(),Issue>{
        let id=page.find.ok_or(Issue::Invalid)?;let mut b=page.request.to_vec();b.extend(id);b.extend(page.generation);
        snapshot_bytes(&mut b,find.snapshot);b.extend((page.offset as u64).to_be_bytes());
        b.extend((find.count as u64).to_be_bytes());b.extend((find.folders as u64).to_be_bytes());
        self.event(174,&b).await?;let count=rows.len();
        for row in rows{let e=row.entry;let mut b=page.request.to_vec();b.extend(id);b.extend((row.observation as u64).to_be_bytes());
            b.push(u8::from(e.size.is_some())|u8::from(e.modified.is_some())<<1|u8::from(e.mode.is_some())<<2);
            b.extend(e.size.unwrap_or(0).to_be_bytes());b.extend(e.modified.unwrap_or(0).to_be_bytes());b.extend(e.mode.unwrap_or(0).to_be_bytes());
            ipc::field(&mut b,e.name.as_bytes()).map_err(|_|Issue::Invalid)?;self.event(175,&b).await?;
        }
        let mut b=page.request.to_vec();b.extend(id);b.extend((count as u32).to_be_bytes());self.event(176,&b).await
    }
}
fn snapshot_bytes(b:&mut Vec<u8>,s:catalog::Snapshot){for n in[s.read,s.revision,s.count,s.folders]{b.extend((n as u64).to_be_bytes());}b.push(s.state as u8);}
async fn handshake(start:ipc::Start,input:&mut mpsc::Receiver<Command>,output:&mut Output,stop:&Stop,mode:Mode,outer:Option<[u8;16]>)->Result<Verified,Issue>{
    let(tx,requests)=mpsc::channel(1);
    let reviewed=start.store.is_some();
    let connect=async{
        if mode.key_auth(){Verified::connect_profile_reviewed(start.peer,start.address,start.previous,tx,Duration::from_secs(30),Duration::from_secs(120)).await}
        else if reviewed{Verified::connect_reviewed(start.peer,start.address,start.previous,tx,Duration::from_secs(30),Duration::from_secs(120)).await}
        else{Verified::connect(start.peer,start.address,start.previous,tx,Duration::from_secs(30)).await}
    };
    review_connection(connect,requests,input,output,stop,mode,outer).await
}
async fn review_connection<F>(connect:F,mut requests:mpsc::Receiver<ssh::TrustRequest>,input:&mut mpsc::Receiver<Command>,
    output:&mut Output,stop:&Stop,mode:Mode,outer:Option<[u8;16]>)->Result<Verified,Issue>
where F:Future<Output=Result<Verified,ssh::Failure>>{
    tokio::pin!(connect);let mut pending:Option<ssh::TrustRequest>=None;
    loop{tokio::select!{biased;
        reason=stop.wait()=>return Err(reason),
        request=requests.recv(),if pending.is_none()=>{
            let request=request.ok_or(Issue::Trust)?;
            guarded(stop,output.challenge(&request.challenge,outer)).await?;pending=Some(request);
        },
        command=input.recv()=>{
            let(action,key)=match(command,outer){
                (Some(Command::Approve{action,key}),None)=>(action,key),
                (Some(Command::JumpApprove{nonce,action,key}),Some(expected))if nonce==expected=>(action,key),
                _=>return Err(Issue::Phase),
            };
            if mode.jump()&&(!mode.remembered_jump()&&!matches!(action,ssh::Action::Reject|ssh::Action::ConnectOnce)
                ||mode.remembered_jump()&&matches!(action,ssh::Action::Remember)){return Err(Issue::Trust)}
            let request=pending.take().ok_or(Issue::Phase)?;let mut challenge=request.challenge;
            if action!=ssh::Action::Reject{
                let observed=key.ok_or(Issue::Trust)?;if observed!=challenge.current{return Err(Issue::Trust)}challenge.current=observed;
            }
            request.reply.send(Decision{challenge,action}).map_err(|_|Issue::Trust)?;
        },
        result=&mut connect=>return result.map_err(ssh_error),
    }}
}
struct Outcome{reason:Issue,close_ack:bool,ssh_task_ended:bool,jump_task_ended:bool}
async fn interactive_authentication(ssh:&mut Verified,account:&str,input:&mut mpsc::Receiver<Command>,output:&mut Output,stop:&Stop,
    expires:tokio::time::Instant,outer:Option<[u8;16]>)->Result<(),Issue>{
    use crate::interactive::{Rounds,Step};
    let mut rounds=Rounds::default();
    let mut step=guarded(stop,async{tokio::time::timeout_at(expires,ssh.interactive_start(account)).await.map_err(|_|Issue::Deadline)?.map_err(ssh_error)}).await?;
    loop{
        match step{
            Step::Complete=>{rounds.complete().map_err(|_|Issue::Phase)?;return Ok(())},
            Step::Challenge(challenge)=>{
                let round=rounds.challenge(challenge.prompts.len()).map_err(|_|Issue::Authentication)?;
                let until=expires.min(tokio::time::Instant::now()+Duration::from_secs(120));
                let seconds=until.saturating_duration_since(tokio::time::Instant::now()).as_secs().min(120)as u16;
                if seconds==0{return Err(Issue::Deadline)}
                let mut payload=outer.map_or_else(Vec::new,|token|token.to_vec());payload.push(round);payload.extend(seconds.to_be_bytes());ipc::field(&mut payload,challenge.name.as_bytes()).map_err(|_|Issue::Invalid)?;
                ipc::field(&mut payload,challenge.instructions.as_bytes()).map_err(|_|Issue::Invalid)?;payload.push(challenge.prompts.len()as u8);
                for prompt in &challenge.prompts{payload.push(u8::from(prompt.echo));ipc::field(&mut payload,prompt.text.as_bytes()).map_err(|_|Issue::Invalid)?;}
                guarded(stop,output.event(if outer.is_some(){146}else{136},&payload)).await?;
                let command=loop{tokio::select!{biased;
                    reason=stop.wait()=>return Err(reason),
                    command=input.recv()=>break command.ok_or(Issue::InputClosed)?,
                    _=tokio::time::sleep_until(until)=>return Err(Issue::Deadline),
                    _=tokio::time::sleep(Duration::from_millis(200))=>ssh.check_transport().map_err(ssh_error)?,
                }};
                let(actual,answers)=match(command,outer){
                    (Command::InteractiveAnswers{round,answers},None)=>(round,answers),
                    (Command::JumpAnswers{nonce,round,answers},Some(expected))if nonce==expected=>(round,answers),
                    _=>return Err(Issue::Phase),
                };
                let answers=rounds.response(actual,answers).map_err(|_|Issue::Phase)?;
                step=guarded(stop,async{tokio::time::timeout_at(expires,ssh.interactive_response(answers)).await.map_err(|_|Issue::Deadline)?.map_err(ssh_error)}).await?;
            },
        }
    }
}
async fn authenticate(ssh:&mut Verified,credential:Command,input:&mut mpsc::Receiver<Command>,output:&mut Output,
    stop:&Stop,mode:Mode,outer:Option<[u8;16]>)->Result<(),Issue>{
    let expires=tokio::time::Instant::now()+Duration::from_secs(180);
    match credential{
        Command::Credentials{account,password}=>guarded(stop,async{ssh.password(&account,password).await.map_err(ssh_error)}).await?,
        Command::KeyCredentials{account,key,passphrase,expected,interactive}if mode.key_auth()=>{
            let identity=if interactive&&mode.interactive(){
                let acceptance=guarded(stop,async{ssh.public_key_then_interactive(&account,key,passphrase,expected.as_ref()).await.map_err(ssh_error)}).await?;
                match acceptance{ssh::KeyAuthentication::Complete(identity)=>identity,
                    ssh::KeyAuthentication::AdditionalStep(identity)=>{
                        interactive_authentication(ssh,&account,input,output,stop,expires,outer).await?;identity
                    }}
            }else{guarded(stop,async{ssh.public_key(&account,key,passphrase,expected.as_ref()).await.map_err(ssh_error)}).await?};
            let mut payload=outer.map_or_else(Vec::new,|token|token.to_vec());ipc::field(&mut payload,identity.bytes()).map_err(|_|Issue::Invalid)?;
            guarded(stop,output.event(if outer.is_some(){144}else{135},&payload)).await?;
        },
        Command::CertificateCredentials{account,key,passphrase,expected,certificate,interactive}
            if mode.key_auth()&&!mode.jump()&&!mode.agent()=>{
            let identity=if interactive&&mode.interactive(){
                let acceptance=guarded(stop,async{ssh.user_certificate_then_interactive(&account,key,passphrase,expected.as_ref(),certificate)
                    .await.map_err(ssh_error)}).await?;
                match acceptance{ssh::KeyAuthentication::Complete(identity)=>identity,
                    ssh::KeyAuthentication::AdditionalStep(identity)=>{
                        interactive_authentication(ssh,&account,input,output,stop,expires,outer).await?;identity
                    }}
            }else{guarded(stop,async{ssh.user_certificate(&account,key,passphrase,expected.as_ref(),certificate)
                .await.map_err(ssh_error)}).await?};
            let mut payload=Vec::new();ipc::field(&mut payload,identity.bytes()).map_err(|_|Issue::Invalid)?;
            guarded(stop,output.event(135,&payload)).await?;
        },
        Command::InteractiveStart{account}if mode.interactive()=>interactive_authentication(ssh,&account,input,output,stop,expires,outer).await?,
        _=>return Err(Issue::Phase),
    }Ok(())
}
#[cfg(feature="agent-qualification")]
async fn authenticate_agent(ssh:&mut Verified,credential:Command,input:&mut mpsc::Receiver<Command>,
    output:&mut Output,stop:&Stop)->Result<(),Issue>{
    let Command::AgentList{socket}=credential else{return Err(Issue::Phase)};
    crate::agent_auth::require_generated_socket(Path::new(&socket)).map_err(agent_error)?;
    let catalog=guarded(stop,async{
        crate::agent_auth::AgentCatalog::connect(Path::new(&socket),Duration::from_secs(10))
            .await.map_err(agent_error)
    }).await?;
    let identities=catalog.summaries();
    let mut payload=vec![u8::try_from(identities.len()).map_err(|_|Issue::Invalid)?];
    for identity in identities{
        payload.extend(identity.digest);
        ipc::field(&mut payload,identity.algorithm.as_bytes()).map_err(|_|Issue::Invalid)?;
    }
    guarded(stop,output.event(138,&payload)).await?;
    let selected=guarded(stop,async{input.recv().await.ok_or(Issue::InputClosed)}).await?;
    let Command::AgentSelect{account,digest}=selected else{return Err(Issue::Phase)};
    let signer=catalog.select(digest,Duration::from_secs(30)).map_err(agent_error)?;
    let result=guarded(stop,async{
        ssh.agent_selected_identity(&account,signer,Duration::from_secs(30),false)
            .await.map_err(ssh_error)
    }).await?;
    if !matches!(result,ssh::AgentAuthentication::Complete(_)){return Err(Issue::Authentication)}
    guarded(stop,output.event(139,&digest)).await?;
    Ok(())
}
fn relinquish_output(output:Output){
    // OwnedWriteHalf::drop shuts down the shared socket's write direction,
    // including duplicate descriptors. forget() suppresses that shutdown while
    // releasing its Arc/descriptor normally, so the retained terminal owner can
    // publish only after the connection runtime and all SSH tasks are disposed.
    output.stream.forget();
}
async fn execute(stream:UnixStream,state:Arc<Mutex<WriteState>>,mode:Mode,thread:Arc<Mutex<Option<ThreadOwner>>>)->Outcome{
    let(mut read,write)=stream.into_split();let mut decoder=ipc::Decoder::new(mode);
    let initial=tokio::time::timeout(Duration::from_secs(5),frame(&mut read)).await;
    let start=match initial{
        Ok(Ok(bytes))=>match decoder.consume(&bytes){Ok(Command::Start(start))=>start,
            _=>return Outcome{reason:Issue::Invalid,close_ack:false,ssh_task_ended:false,jump_task_ended:false}},
        _=>return Outcome{reason:Issue::InputClosed,close_ack:false,ssh_task_ended:false,jump_task_ended:false},
    };
    let transfer_caps=decoder.transfer_capabilities();let editor_enabled=decoder.inplace_enabled();
    let allows_downloads=mode.transfers()||(mode.inplace()||mode.actions())&&transfer_caps&1!=0;
    let allows_folders=mode.folders()||(mode.inplace()||mode.actions())&&transfer_caps&2!=0;
    let allows_uploads=mode.uploads()||(mode.inplace()||mode.actions())&&transfer_caps&4!=0;
    let allows_folder_uploads=mode.folder_uploads()||(mode.inplace()||mode.actions())&&transfer_caps&8!=0;
    state.lock().unwrap().session=Some(start.session);
    let stop=Stop::new();let input_stop=stop.clone();let(tx,mut input)=mpsc::channel(4);
    let input_task=tokio::spawn(async move{
        loop{
            let command=match frame(&mut read).await{
                Ok(bytes)=>match decoder.consume(&bytes){Ok(command)=>command,Err(_)=>{input_stop.set(Issue::Invalid);return}},
                Err(error)=>{input_stop.set(error);return},
            };
            if matches!(command,Command::Stop){input_stop.set(Issue::Stopped);return}
            if tx.try_send(command).is_err(){input_stop.set(Issue::Invalid);return}
        }
    });
    let mut output=Output{stream:write,state};let mut verified:Option<Verified>=None;let mut jump_verified:Option<Verified>=None;let mut writer:Option<Writer>=None;
    let mut reader:Option<reader::Reader<russh::ChannelStream<russh::client::Msg>>>=None;
    let operation=async{
        if let Some(store)=start.store.as_ref(){
            let(w,owner,ready)=Writer::spawn(Authority{path:store.path.clone(),directory:4,database:5,lease:6,quota:store.quota},stop.catalog.clone()).map_err(|_|Issue::Storage)?;
            *thread.lock().map_err(|_|Issue::Storage)?=Some(owner);writer=Some(w);
            guarded(&stop,async{ready.await.map_err(|_|Issue::Storage)?.map_err(|_|Issue::Storage)}).await?;
        }
        // Exact dialect acceptance precedes trust/auth and carries no authority
        // beyond the startup already validated by the same strict decoder.
        if editor_enabled{
            if mode.actions(){guarded(&stop,output.event(200,&[4,7,2,transfer_caps,1])).await?;}
            else{guarded(&stop,output.event(200,&[3,7,1,transfer_caps])).await?;}
        }
        let mut start=start;
        if let Some(jump)=start.jump.take(){
            let outer_start=ipc::Start{session:jump.nonce,peer:jump.peer,address:start.address,previous:jump.previous,store:None,jump:None};
            jump_verified=Some(handshake(outer_start,&mut input,&mut output,&stop,mode,Some(jump.nonce)).await?);
            guarded(&stop,output.event(143,&jump.nonce)).await?;
            let credential=guarded(&stop,async{input.recv().await.ok_or(Issue::InputClosed)}).await?;
            let Command::JumpCredentials{nonce,authentication}=credential else{return Err(Issue::Phase)};
            if nonce!=jump.nonce{return Err(Issue::Phase)}
            let outer=jump_verified.as_mut().ok_or(Issue::Phase)?;
            authenticate(outer,authentication.command(),&mut input,&mut output,&stop,mode,Some(jump.nonce)).await?;
            guarded(&stop,output.event(145,&jump.nonce)).await?;
            let(tx,requests)=mpsc::channel(1);
            verified=Some(review_connection(outer.connect_through_jump(start.peer,start.previous,tx),requests,&mut input,&mut output,&stop,mode,None).await?);
        }else{verified=Some(handshake(start,&mut input,&mut output,&stop,mode,None).await?);}
        guarded(&stop,output.event(101,&[])).await?;
        let credential=guarded(&stop,async{input.recv().await.ok_or(Issue::InputClosed)}).await?;
        let ssh=verified.as_mut().ok_or(Issue::Phase)?;
        #[cfg(feature="agent-qualification")]
        if mode.agent(){authenticate_agent(ssh,credential,&mut input,&mut output,&stop).await?;}
        else{authenticate(ssh,credential,&mut input,&mut output,&stop,mode,None).await?;}
        #[cfg(not(feature="agent-qualification"))]
        authenticate(ssh,credential,&mut input,&mut output,&stop,mode,None).await?;
        guarded(&stop,output.event(102,&[])).await?;
        reader=Some(guarded(&stop,async{ssh.metadata_reader().await.map_err(ssh_error)}).await?);
        #[cfg(feature="remote-action-qualification")]
        if mode.actions(){reader.as_mut().ok_or(Issue::Phase)?.enable_actions();}
        #[cfg(feature="remote-action-qualification")]
        if mode.actions(){
            let supported=reader.as_ref().ok_or(Issue::Phase)?.supports_server_copy();
            guarded(&stop,output.event(214,&[u8::from(supported)])).await?;
        }
        guarded(&stop,output.event(109,&[])).await?;
        let reader=reader.as_mut().ok_or(Issue::Phase)?;let mut generation=None;let mut complete=false;
        let mut snapshot:Option<catalog::Snapshot>=None;
        let mut active_find:Option<([u8;16],[u8;16],catalog::Find)>=None;
        #[cfg(feature="folder-download-qualification")]let mut prepared:Option<crate::folder_download::Prepared>=None;
        #[cfg(feature="folder-download-qualification")]let mut folder_progress=None;
        #[cfg(feature="upload-qualification")]let mut current_path=String::new();
        #[cfg(feature="original-edit-qualification")]let mut edit_baselines=original_control::Baselines::default();
        #[cfg(feature="inplace-edit-v1")]let mut inplace_baselines=inplace_control::Baselines::default();
        let mut next_ping=tokio::time::Instant::now()+Duration::from_secs(15);
        let mut directory_recovery=false;let mut directory_attempted=false;
        loop{
            let command=next_authenticated(&mut input,&stop,ssh,&mut next_ping).await?;
            #[cfg(feature="folder-download-qualification")]
            if prepared.is_some()&&!matches!(&command,Command::ReceiveFolder{..}|Command::ReleaseFolder{..}|Command::Page(_)){return Err(Issue::Phase)}
            match command{
                #[cfg(feature="folder-download-qualification")]
                Command::SummarizeFolder{request,generation:expected,read,revision,count,folders,state,observation}if mode.catalog()=>{
                    use crate::folder_size::{self as size,Failure,Unavailable};
                    let current=snapshot;
                    let selected=if generation!=Some(expected)||!complete||current.is_none_or(|v|
                        v.read!=read||v.revision!=revision||v.count!=count||v.folders!=folders||v.state!=catalog::State::Complete||state!=1){
                        Err(Unavailable::Stale)
                    }else{
                        let w=writer.as_ref().ok_or(Issue::Phase)?;
                        match guarded(&stop,async{w.selected_file(current.unwrap(),observation).await.map_err(|error|
                            if error==catalog::Error::Stale{Issue::SourceChanged}else{Issue::Storage})}).await{
                            Ok(value)=>Ok(value),Err(Issue::SourceChanged)=>Err(Unavailable::Stale),Err(error)=>return Err(error),
                        }
                    };
                    let outcome=match selected{
                        Err(reason)=>Err(reason),
                        Ok((path,entry))=>{
                            let metadata=crate::wire::Metadata{size:entry.size,modified:entry.modified,permissions:entry.mode};
                            let scanned=tokio::select!{biased;reason=stop.wait()=>return Err(reason),
                                value=size::summarize(reader,&path,metadata)=>value};
                            match scanned{
                                Ok(result)=>Ok(result),
                                Err(Failure::Reason(reason))if reader.is_open()=>Err(reason),
                                Err(Failure::Channel(problem))if reader.directory_rejection(problem).is_some()=>Err(match problem{
                                    reader::Failure::Status(2)=>Unavailable::Changed,
                                    reader::Failure::Status(3)=>Unavailable::Denied,
                                    _=>Unavailable::Unavailable,
                                }),
                                Err(Failure::Channel(problem))=>return Err(read_error(problem)),
                                Err(Failure::Close|Failure::Reason(_))=>return Err(Issue::Transport),
                            }
                        },
                    };
                    match outcome{
                        Ok(result)=>{
                            let mut payload=request.to_vec();payload.extend(expected);
                            for value in [read,revision,count,folders]{payload.extend((value as u64).to_be_bytes());}
                            payload.push(state);payload.extend((observation as u64).to_be_bytes());
                            payload.extend(result.bytes.to_be_bytes());payload.extend(result.files.to_be_bytes());
                            payload.extend(result.folders.to_be_bytes());payload.extend(result.excluded_links.to_be_bytes());
                            output.event(220,&payload).await?;
                        },
                        Err(reason)=>{let mut payload=request.to_vec();payload.push(reason as u8);output.event(221,&payload).await?;},
                    }
                },
                #[cfg(feature="original-edit-qualification")]
                Command::BeginEdit{request,generation:expected,revision,observation}if mode.original()&&generation==Some(expected)&&complete=>{
                    let current=snapshot.ok_or(Issue::Phase)?;
                    if current.revision!=revision||current.state!=catalog::State::Complete{return Err(Issue::Phase)}
                    let w=writer.as_ref().ok_or(Issue::Phase)?;
                    let(path,entry)=guarded(&stop,async{w.selected_file(current,observation).await.map_err(|_|Issue::Storage)}).await?;
                    let metadata=crate::wire::Metadata{size:entry.size,modified:entry.modified,permissions:entry.mode};
                    edit_baselines.begin(ssh,&mut output,&mut input,&stop,request,expected,path,metadata).await?;
                },
                #[cfg(feature="original-edit-qualification")]
                Command::SaveOriginal{request,token,revision,operation,generation:editor_generation,size,digest}if mode.original()=>{
                    edit_baselines.save(ssh,&mut output,&mut input,&stop,request,token,revision,operation,editor_generation,size,digest).await?;
                },
                #[cfg(feature="original-edit-qualification")]
                Command::ReleaseBaselineV1{request,token,revision}if mode.original()=>{
                    let receipt=edit_baselines.release_request(request,token,revision);output.event(189,&receipt).await?;
                },
                #[cfg(feature="inplace-edit-v1")]
                Command::BeginInPlace{request,generation:expected,revision,observation}if editor_enabled&&generation==Some(expected)&&complete=>{
                    let current=snapshot.ok_or(Issue::Phase)?;if current.revision!=revision||current.state!=catalog::State::Complete{return Err(Issue::Phase)}
                    let w=writer.as_ref().ok_or(Issue::Phase)?;
                    let(path,entry)=guarded(&stop,async{w.selected_file(current,observation).await.map_err(|_|Issue::Storage)}).await?;
                    let metadata=crate::wire::Metadata{size:entry.size,modified:entry.modified,permissions:entry.mode};
                    inplace_baselines.begin(ssh,&mut output,&mut input,&stop,request,expected,revision as u64,observation as u64,path,metadata).await?;
                },
                #[cfg(feature="inplace-edit-v1")]
                Command::SaveInPlace{request,token,revision,generation:editor_generation,size,digest}if editor_enabled=>{
                    inplace_baselines.save(&mut output,&mut input,request,token,revision,editor_generation,size,digest).await?;
                },
                #[cfg(feature="inplace-edit-v1")]
                Command::ReleaseInPlace{request,token,revision}if editor_enabled=>{
                    inplace_baselines.release(&mut output,request,token,revision).await?;
                },
                #[cfg(feature="remote-action-qualification")]
                Command::ActionPrepare(action)if mode.actions()&&generation==Some(action.generation)&&complete=>{
                    use action_control::Refusal;
                    let current=snapshot.ok_or(Issue::Phase)?;
                    if current.read!=action.read||current.revision!=action.revision||current.state!=catalog::State::Complete{return Err(Issue::Phase)}
                    let w=writer.as_ref().ok_or(Issue::Phase)?;
                    let selected=if action.kind==1{None}else{
                        match guarded(&stop,async{w.selected_file(current,action.observation).await.map_err(|error|
                            if error==catalog::Error::Stale{Issue::SourceChanged}else{Issue::Storage})}).await{
                            Ok(value)=>Some(value),Err(Issue::SourceChanged)=>{
                                let mut bytes=action.request.to_vec();bytes.push(Refusal::SourceChanged as u8);
                                guarded(&stop,output.event(212,&bytes)).await?;continue
                            },Err(error)=>return Err(error),
                        }
                    };
                    let target=match action_control::target(&action,&current_path,selected){
                        Ok(value)=>value,Err(Issue::SourceChanged|Issue::Invalid)=>{
                            let mut bytes=action.request.to_vec();bytes.push(Refusal::SourceChanged as u8);
                            guarded(&stop,output.event(212,&bytes)).await?;continue
                        },Err(error)=>return Err(error),
                    };
                    let editor_conflict=action.kind!=1 && (if [4,5,7].contains(&action.kind){
                        inplace_baselines.conflicts_within(&target.path)||
                        (action.kind==7&&target.destination.as_deref().is_some_and(|path|inplace_baselines.conflicts_within(path)))
                    }else{
                        inplace_baselines.conflicts(&target.path)||
                        ([6,8].contains(&action.kind)&&target.destination.as_deref().is_some_and(|path|inplace_baselines.conflicts(path)))
                    });
                    if editor_conflict{
                        let mut bytes=action.request.to_vec();bytes.push(Refusal::Busy as u8);
                        guarded(&stop,output.event(212,&bytes)).await?;continue
                    }
                    if let Some(reason)=guarded(&stop,action_control::preflight(reader,&action,&current_path,&target)).await?{
                        let mut bytes=action.request.to_vec();bytes.push(reason as u8);
                        guarded(&stop,output.event(212,&bytes)).await?;continue
                    }
                    guarded(&stop,output.event(210,&action.request)).await?;
                    let permit=next_authenticated(&mut input,&stop,ssh,&mut next_ping).await?;
                    if !matches!(permit,Command::ActionPermit{request}if request==action.request){return Err(Issue::Phase)}
                    if let Some(reason)=guarded(&stop,action_control::preflight(reader,&action,&current_path,&target)).await?{
                        let mut bytes=action.request.to_vec();bytes.push(reason as u8);
                        guarded(&stop,output.event(212,&bytes)).await?;continue
                    }
                    let result=if action.kind==8{
                        let copy=crate::upload::server_copy::Target::new(&target.path,
                            target.destination.as_deref().ok_or(Issue::Phase)?,action.request).map_err(|_|Issue::Invalid)?;
                        let selected=target.expected.ok_or(Issue::Phase)?;
                        match ssh.copy_file_same_session(&copy,selected,Some(stop.catalog.clone())).await{
                            Ok(_)=>Ok(true),
                            Err(error) if !error.stage_may_exist&&!error.publication_may_have_happened=>{
                                let refusal=match error.cause{
                                    crate::upload::Failure::Status(3)=>Refusal::Denied,
                                    crate::upload::Failure::Conflict=>Refusal::TargetExists,
                                    crate::upload::Failure::SourceChanged|crate::upload::Failure::Status(2)=>Refusal::SourceChanged,
                                    _=>Refusal::Unavailable,
                                };
                                let mut bytes=action.request.to_vec();bytes.push(refusal as u8);
                                guarded(&stop,output.event(212,&bytes)).await?;continue
                            },
                            Err(_)=>Err(Issue::SourceChanged),
                        }
                    }else{guarded(&stop,action_control::mutate_and_verify(reader,&action,&target)).await};
                    // A permit makes the old catalog stale even if the server
                    // returned an error: no retry or row reuse follows it.
                    guarded(&stop,async{w.retire(current.read).await.map_err(|_|Issue::Storage)}).await?;
                    snapshot=None;generation=None;complete=false;current_path.clear();active_find=None;
                    match result{
                        Ok(true)=>guarded(&stop,output.event(211,&action.request)).await?,
                        Ok(false)|Err(_)=>{
                            let _=output.event(213,&action.request).await;
                            return Err(Issue::SourceChanged)
                        },
                    }
                },
                Command::DirectoryRecovery if mode.catalog()&&!directory_recovery&&!directory_attempted=>{
                    guarded(&stop,output.event(169,&[1])).await?;directory_recovery=true;
                },
                #[cfg(feature="folder-download-qualification")]
                Command::PrepareFolder{request,generation:expected,read,revision,observation}if allows_folders&&generation==Some(expected)&&complete=>{
                    use crate::folder_download::{self as folder,Prepared};
                    let current=snapshot.ok_or(Issue::Phase)?;
                    if current.read!=read||current.revision!=revision||current.state!=catalog::State::Complete{return Err(Issue::Phase)}
                    let w=writer.as_ref().ok_or(Issue::Phase)?;
                    let(path,entry)=guarded(&stop,async{w.selected_file(current,observation).await.map_err(|_|Issue::Storage)}).await?;
                    let metadata=crate::wire::Metadata{size:entry.size,modified:entry.modified,permissions:entry.mode};
                    let mut payload=request.to_vec();payload.extend(expected);payload.extend((read as u64).to_be_bytes());
                    payload.extend((revision as u64).to_be_bytes());payload.extend((observation as u64).to_be_bytes());output.event(150,&payload).await?;
                    let began=std::time::Instant::now();
                    let progress=FolderProgress{output:&mut output,request,phase:0,last:&mut folder_progress};
                    let manifest=guarded(&stop,async{tokio::time::timeout(folder::ACTIVE_DEADLINE,folder::collect(reader,&path,metadata,progress)).await
                        .map_err(|_|Issue::Deadline)?.map_err(folder_error)}).await?;
                    for(ordinal,node)in manifest.nodes.iter().enumerate(){
                        let mut payload=request.to_vec();payload.extend((ordinal as u32).to_be_bytes());payload.push(node.parts.len()as u8);
                        for part in &node.parts{ipc::field(&mut payload,part.as_bytes()).map_err(|_|Issue::Invalid)?;}
                        payload.push(u8::from(node.metadata.size.is_some()));payload.extend(node.metadata.size.unwrap_or(0).to_be_bytes());
                        payload.extend(node.metadata.modified.ok_or(Issue::Invalid)?.to_be_bytes());payload.extend(node.metadata.permissions.ok_or(Issue::Invalid)?.to_be_bytes());
                        output.event(152,&payload).await?;
                    }
                    let mut payload=request.to_vec();payload.extend((manifest.nodes.len()as u32).to_be_bytes());payload.extend((manifest.files as u32).to_be_bytes());
                    payload.extend((manifest.folders as u32).to_be_bytes());payload.extend(manifest.bytes.to_be_bytes());payload.extend((manifest.longest as u32).to_be_bytes());
                    output.event(153,&payload).await?;
                    prepared=Some(Prepared{request,generation:expected,read,revision,manifest,spent:began.elapsed(),reviewed_at:std::time::Instant::now()});
                },
                #[cfg(feature="folder-download-qualification")]
                Command::ReleaseFolder{request}if allows_folders=>{
                    let pending=prepared.take().ok_or(Issue::Phase)?;if request!=pending.request{return Err(Issue::Phase)}
                    output.event(159,&request).await?;
                },
                #[cfg(feature="folder-download-qualification")]
                Command::ReceiveFolder{request}if allows_folders&&complete=>{
                    use crate::folder_download as folder;
                    let pending=prepared.take().ok_or(Issue::Phase)?;let current=snapshot.ok_or(Issue::Phase)?;
                    if request!=pending.request||generation!=Some(pending.generation)||current.read!=pending.read||current.revision!=pending.revision{return Err(Issue::Phase)}
                    let remaining=pending.remaining().map_err(folder_error)?;
                    let receive=async{
                        output.event(154,&request).await?;
                        let progress=FolderProgress{output:&mut output,request,phase:1,last:&mut folder_progress};
                        guarded(&stop,async{folder::revalidate(reader,&pending.manifest,progress).await.map_err(folder_error)}).await?;
                        let mut received=0u64;let mut files=0u32;
                        for(ordinal,node)in pending.manifest.nodes.iter().enumerate().filter(|(_,n)|!n.directory()){
                            let progress=FolderProgress{output:&mut output,request,phase:2,last:&mut folder_progress};
                            guarded(&stop,async{folder::ancestors(reader,&pending.manifest,node,progress).await.map_err(folder_error)}).await?;
                            let path=folder::path(&pending.manifest.root,&node.parts).map_err(folder_error)?;
                            let mut payload=request.to_vec();payload.extend((ordinal as u32).to_be_bytes());output.event(155,&payload).await?;
                            let sink=FolderOutput{output:&mut output,request,ordinal:ordinal as u32,last:&mut folder_progress};
                            let receipt=ssh.receive_file_controlled(&path,node.metadata,crate::download::Limits::default(),Some(stop.catalog.clone()),sink).await.map_err(download_error)?;
                            if !receipt.close_acknowledged||!receipt.stream_shutdown{return Err(Issue::Transport)}
                            let progress=FolderProgress{output:&mut output,request,phase:2,last:&mut folder_progress};
                            guarded(&stop,async{folder::ancestors(reader,&pending.manifest,node,progress).await.map_err(folder_error)}).await?;
                            received=received.checked_add(receipt.bytes).ok_or(Issue::Invalid)?;files+=1;
                            let mut payload=request.to_vec();payload.extend((ordinal as u32).to_be_bytes());payload.extend(receipt.bytes.to_be_bytes());output.event(157,&payload).await?;
                        }
                        let progress=FolderProgress{output:&mut output,request,phase:3,last:&mut folder_progress};
                        guarded(&stop,async{folder::revalidate(reader,&pending.manifest,progress).await.map_err(folder_error)}).await?;
                        if received!=pending.manifest.bytes||files as usize!=pending.manifest.files{return Err(Issue::Invalid)}
                        let mut payload=request.to_vec();payload.extend(received.to_be_bytes());payload.extend(files.to_be_bytes());payload.extend([1,1]);output.event(158,&payload).await
                    };
                    tokio::time::timeout(remaining,receive).await.map_err(|_|Issue::Deadline)??;
                },
                #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
                Command::FolderUpload{request,generation:expected,revision,name,length,digest,files,folders,bytes}if allows_folder_uploads&&generation==Some(expected)&&complete=>{
                    let current=snapshot.ok_or(Issue::Phase)?;
                    if current.revision!=revision||current.state!=catalog::State::Complete{return Err(Issue::Phase)}
                    folder_upload_control::run(ssh,&mut output,&mut input,&stop,&current_path,request,expected,name,length,digest,files,folders,bytes).await?;
                },
                #[cfg(feature="upload-qualification")]
                Command::Upload{request,generation:expected,revision,name,size}if allows_uploads&&generation==Some(expected)&&complete=>{
                    let current=snapshot.ok_or(Issue::Phase)?;
                    if current.revision!=revision||current.state!=catalog::State::Complete{return Err(Issue::Phase)}
                    let target=crate::upload::Target::new(&current_path,&name,request).map_err(|_|Issue::Invalid)?;
                    let(_,final_path)=target.paths_for_intent();
                    let mut payload=request.to_vec();payload.extend(expected);payload.extend(size.to_be_bytes());
                    ipc::field(&mut payload,b"").map_err(|_|Issue::Invalid)?;
                    ipc::field(&mut payload,final_path.as_bytes()).map_err(|_|Issue::Invalid)?;output.event(130,&payload).await?;
                    let source=UploadInput{output:&mut output,input:&mut input,request,size};
                    let result=ssh.send_upload_source(&target,source,crate::upload::Limits::default(),Some(stop.catalog.clone())).await;
                    let receipt=match result{
                        Ok(receipt)=>receipt,
                        Err(error)=>{
                            let(issue,error)=upload_observed_failure(&stop,error);
                            if error.refused_first_open(){
                                // The first exclusive OPEN received its complete,
                                // correlated STATUS(3), and its SFTP channel
                                // shut down. No handle or write was accepted.
                                // Keep the authenticated worker for the next
                                // explicit request; the parent records notStarted.
                                output.event(137,&request).await?;
                                continue
                            }
                            let payload=upload_interruption_bytes(request,&error);
                            let _=output.event(134,&payload).await;return Err(issue)
                        },
                    };
                    let mut payload=request.to_vec();payload.extend(receipt.bytes.to_be_bytes());payload.extend(receipt.digest);
                    payload.extend([u8::from(receipt.sync_acknowledged),u8::from(receipt.exclusive_create_acknowledged),u8::from(receipt.final_close_acknowledged),u8::from(receipt.stream_shutdown)]);
                    output.event(133,&payload).await?;
                },
                #[cfg(feature="download-qualification")]
                Command::Download{request,generation:expected,observation}if allows_downloads&&generation==Some(expected)&&complete=>{
                    let w=writer.as_ref().ok_or(Issue::Phase)?;let current=snapshot.ok_or(Issue::Phase)?;
                    let(path,entry)=guarded(&stop,async{w.selected_file(current,observation).await.map_err(|_|Issue::Storage)}).await?;
                    let metadata=crate::wire::Metadata{size:entry.size,modified:entry.modified,permissions:entry.mode};
                    crate::download::admitted(&path,metadata,crate::download::Limits::default()).map_err(|_|Issue::Invalid)?;
                    let mut payload=request.to_vec();payload.extend(expected);payload.extend((observation as u64).to_be_bytes());
                    payload.extend(metadata.size.unwrap().to_be_bytes());payload.extend(metadata.modified.unwrap().to_be_bytes());payload.extend(metadata.permissions.unwrap().to_be_bytes());
                    ipc::field(&mut payload,entry.name.as_bytes()).map_err(|_|Issue::Invalid)?;output.event(120,&payload).await?;
                    let receipt=ssh.receive_file_controlled(&path,metadata,crate::download::Limits::default(),Some(stop.catalog.clone()),DownloadOutput{output:&mut output,request,checkpoints:allows_folders,last:None}).await.map_err(download_error)?;
                    let mut payload=request.to_vec();payload.extend(receipt.bytes.to_be_bytes());payload.extend([u8::from(receipt.close_acknowledged),u8::from(receipt.stream_shutdown)]);
                    output.event(122,&payload).await?;
                },
                Command::Directory{generation:next,path}=>{
                    active_find=None;
                    directory_attempted=true;
                    guarded(&stop,async{reader.close_directory().await.map_err(read_error)}).await?;
                    if directory_recovery{
                        generation=None;complete=false;
                        #[cfg(feature="upload-qualification")]{current_path.clear();}
                        if let Some(old)=snapshot.take(){
                            let w=writer.as_ref().ok_or(Issue::Storage)?;
                            if old.state==catalog::State::Loading{guarded(&stop,async{w.finish(catalog::State::Partial).await.map_err(|_|Issue::Storage)}).await?;}
                            guarded(&stop,async{w.retire(old.read).await.map_err(|_|Issue::Storage)}).await?;
                        }
                    }
                    let opened=guarded(&stop,async{
                        match reader.open_location(&path).await{
                            Ok(path)=>Ok(Ok(path)),
                            Err(error)=>if directory_recovery{match reader.directory_rejection(error){Some(code)=>Ok(Err(code)),None=>Err(read_error(error))}}else{Err(read_error(error))}
                        }
                    }).await?;
                    let canonical=match opened{Ok(path)=>path,Err(code)=>{
                        let mut payload=next.to_vec();payload.push(code);guarded(&stop,output.event(170,&payload)).await?;continue
                    }};
                    if let Some(w)=writer.as_ref(){
                        if let Some(old)=snapshot.take(){
                            if old.state==catalog::State::Loading{guarded(&stop,async{w.finish(catalog::State::Partial).await.map_err(|_|Issue::Storage)}).await?;}
                            guarded(&stop,async{w.retire(old.read).await.map_err(|_|Issue::Storage)}).await?;
                        }
                        let s=guarded(&stop,async{w.start(next,canonical.clone()).await.map_err(|_|Issue::Storage)}).await?;
                        guarded(&stop,output.snapshot(110,next,s,Some(&canonical))).await?;snapshot=Some(s);
                    }else{
                        let mut bytes=next.to_vec();ipc::field(&mut bytes,canonical.as_bytes()).map_err(|_|Issue::Invalid)?;
                        guarded(&stop,output.event(103,&bytes)).await?;
                    }
                    #[cfg(feature="upload-qualification")]{current_path=canonical;}
                    generation=Some(next);complete=false;
                },
                Command::Next(expected)if generation==Some(expected)&&!complete=>{
                    active_find=None;
                    let batch=guarded(&stop,async{reader.next_batch().await.map_err(read_error)}).await?;
                    let end=batch.is_none();let batch=batch.unwrap_or_default();let count=batch.len();
                    if end{guarded(&stop,async{reader.close_directory().await.map_err(read_error)}).await?;complete=true;}
                    if let Some(w)=writer.as_ref(){
                        let read=snapshot.ok_or(Issue::Storage)?.read;
                        let rows=batch.into_iter().map(|e|catalog::Entry{name:e.name,size:e.metadata.size,modified:e.metadata.modified,mode:e.metadata.permissions}).collect();
                        let mut s=guarded(&stop,async{w.append(rows,read).await.map_err(|_|Issue::Storage)}).await?;
                        if end{s=guarded(&stop,async{w.finish(catalog::State::Complete).await.map_err(|_|Issue::Storage)}).await?;}
                        guarded(&stop,output.snapshot(111,expected,s,None)).await?;snapshot=Some(s);
                    }else{
                        for entry in batch{guarded(&stop,output.row(expected,entry)).await?;}
                        let mut bytes=expected.to_vec();bytes.extend((count as u32).to_be_bytes());bytes.push(u8::from(end));
                        guarded(&stop,output.event(105,&bytes)).await?;
                    }
                },
                Command::Find(request)=>{
                    active_find=None;
                    let Some(s)=snapshot else{guarded(&stop,output.event(119,&request.request)).await?;continue};
                    let expected=match request.state{0=>catalog::State::Loading,1=>catalog::State::Complete,
                        2=>catalog::State::Partial,3=>catalog::State::Stopped,_=>return Err(Issue::Invalid)};
                    if generation!=Some(request.generation)||s.read!=request.read||s.revision!=request.revision||
                        s.count!=request.count||s.folders!=request.folders||s.state!=expected{
                        guarded(&stop,output.event(119,&request.request)).await?;continue
                    }
                    let w=writer.as_ref().ok_or(Issue::Phase)?;
                    let result=guarded(&stop,async{Ok(w.find(s,request.query).await)}).await?;
                    match result{
                        Ok(find)=>{
                            let mut b=request.request.to_vec();b.extend(request.generation);snapshot_bytes(&mut b,find.snapshot);
                            b.extend((find.count as u64).to_be_bytes());b.extend((find.folders as u64).to_be_bytes());
                            guarded(&stop,output.event(118,&b)).await?;
                            active_find=Some((request.request,request.generation,find));
                        },
                        Err(catalog::Error::Stale)=>guarded(&stop,output.event(119,&request.request)).await?,
                        Err(catalog::Error::SQLite(code))if code&255==9&&!stop.catalog.load(Ordering::Acquire)=>{
                            let mut b=request.request.to_vec();b.push(1);guarded(&stop,output.event(124,&b)).await?;
                        },
                        Err(_)=>return Err(Issue::Storage),
                    }
                },
                Command::Page(page)=>{
                    let w=writer.as_ref().ok_or(Issue::Phase)?;
                    let Some(s)=snapshot else{
                        if let Some(id)=page.find{
                            let mut b=page.request.to_vec();b.extend(id);guarded(&stop,output.event(177,&b)).await?;continue
                        }
                        return Err(Issue::Phase)
                    };
                    if let Some(id)=page.find{
                        let Some((selected,g,find))=active_find.as_ref() else{
                            let mut b=page.request.to_vec();b.extend(id);guarded(&stop,output.event(177,&b)).await?;continue
                        };
                        if *selected!=id||*g!=page.generation||generation!=Some(page.generation)||
                            find.snapshot!=s||s.revision!=page.revision{
                            let mut b=page.request.to_vec();b.extend(id);guarded(&stop,output.event(177,&b)).await?;continue
                        }
                        let sort=match page.sort{0=>catalog::Sort::Name,1=>catalog::Sort::Size,2=>catalog::Sort::Modified,_=>return Err(Issue::Invalid)};
                        let result=guarded(&stop,async{Ok(w.find_page(find.clone(),page.offset,page.limit,sort,page.descending).await)}).await?;
                        match result{
                            Ok(rows)=>guarded(&stop,output.filtered_page(page,find,rows)).await?,
                            Err(catalog::Error::Stale)=>{
                                let mut b=page.request.to_vec();b.extend(id);guarded(&stop,output.event(177,&b)).await?;
                            },
                            Err(catalog::Error::SQLite(code))if code&255==9&&!stop.catalog.load(Ordering::Acquire)=>{
                                let mut b=page.request.to_vec();b.extend(id);b.push(1);guarded(&stop,output.event(178,&b)).await?;
                            },
                            Err(_)=>return Err(Issue::Storage),
                        }
                        continue
                    }
                    if generation!=Some(page.generation)||s.revision!=page.revision{guarded(&stop,output.event(117,&page.request)).await?;continue}
                    let sort=match page.sort{0=>catalog::Sort::Name,1=>catalog::Sort::Size,2=>catalog::Sort::Modified,_=>return Err(Issue::Invalid)};
                    let rows=guarded(&stop,async{w.page(s,page.offset,page.limit,sort,page.descending).await.map_err(|_|Issue::Storage)}).await?;
                    guarded(&stop,output.page(page,s,rows)).await?;
                },
                _=>return Err(Issue::Phase),
            }
        }
    };
    let result:Result<(),Issue>=operation.await;
    let reason=stop.first(result.err().unwrap_or(Issue::Stopped));drop(writer);
    // Stop output/input callbacks before disposing the connection runtime.
    input_task.abort();let _=input_task.await;drop(input);
    let close_ack=if let Some(mut reader)=reader{
        let result=tokio::time::timeout(Duration::from_millis(500),reader.close()).await;
        matches!(result,Ok(drain)if drain.directory_close_acknowledged)
    }else{false};
    async fn close(ssh:Option<Verified>)->bool{match ssh{Some(ssh)=>matches!(tokio::time::timeout(Duration::from_millis(500),ssh.close()).await,Ok(Ok(drain))if drain.ssh_task_ended),None=>false}}
    let(ssh_task_ended,jump_task_ended)=tokio::join!(close(verified),close(jump_verified));
    relinquish_output(output);
    Outcome{reason,close_ack,ssh_task_ended,jump_task_ended}
}
#[cfg(feature="original-edit-qualification")]pub fn run_original()->i32{run_mode(Mode::OriginalEditCatalog)}
#[cfg(feature="original-edit-qualification")]pub fn run_routed_original()->i32{run_mode(Mode::RoutedOriginalEditCatalog)}
#[cfg(feature="inplace-edit-v1")]pub fn run_inplace()->i32{run_mode(Mode::InPlaceEditCatalog)}
#[cfg(feature="inplace-edit-v1")]pub fn run_routed_inplace()->i32{run_mode(Mode::RoutedInPlaceEditCatalog)}
#[cfg(feature="remote-action-qualification")]pub fn run_remote_actions()->i32{run_mode(Mode::RemoteActionCatalog)}
#[cfg(feature="remote-action-qualification")]pub fn run_routed_remote_actions()->i32{run_mode(Mode::RoutedRemoteActionCatalog)}
pub fn run()->i32{run_mode(Mode::Batches)}
pub fn run_paged()->i32{run_mode(Mode::Catalog)}
pub fn run_key_paged()->i32{run_mode(Mode::KeyCatalog)}
#[cfg(feature="agent-qualification")]pub fn run_agent_paged()->i32{run_mode(Mode::AgentCatalog)}
pub fn run_interactive_paged()->i32{run_mode(Mode::InteractiveCatalog)}
pub fn run_jump_paged()->i32{run_mode(Mode::JumpCatalog)}
pub fn run_remembered_jump_paged()->i32{run_mode(Mode::RememberedJumpCatalog)}
#[cfg(feature="folder-download-qualification")]
pub fn run_folders()->i32{run_mode(Mode::FolderCatalog)}
#[cfg(feature="folder-download-qualification")]
pub fn run_routed_folders()->i32{run_mode(Mode::RoutedFolderCatalog)}
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
pub fn run_folder_uploads()->i32{run_mode(Mode::FolderUploadCatalog)}
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
pub fn run_exclusive_uploads()->i32{run_mode(Mode::ExclusiveUploadCatalog)}
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
pub fn run_fresh_folder_uploads()->i32{run_mode(Mode::FreshFolderUploadCatalog)}
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
pub fn run_routed_exclusive_uploads()->i32{run_mode(Mode::RoutedExclusiveUploadCatalog)}
#[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
pub fn run_routed_fresh_folder_uploads()->i32{run_mode(Mode::RoutedFreshFolderUploadCatalog)}
#[cfg(feature="download-qualification")]
pub fn run_transfer()->i32{run_mode(Mode::TransferCatalog)}
#[cfg(feature="download-qualification")]
pub fn run_key_transfer()->i32{run_mode(Mode::KeyTransferCatalog)}
#[cfg(feature="download-qualification")]
pub fn run_interactive_transfer()->i32{run_mode(Mode::InteractiveTransferCatalog)}
#[cfg(feature="upload-qualification")]
pub fn run_upload()->i32{run_mode(Mode::UploadCatalog)}
#[cfg(feature="upload-qualification")]
pub fn run_key_upload()->i32{run_mode(Mode::KeyUploadCatalog)}
#[cfg(feature="upload-qualification")]
pub fn run_interactive_upload()->i32{run_mode(Mode::InteractiveUploadCatalog)}
#[cfg(test)]mod stop_tests{
    use super::*;
    #[test]fn first_observed_stop_reason_survives_downstream_channel_completion(){
        let stop=Stop::new();stop.set(Issue::Invalid);assert_eq!(stop.first(Issue::Stopped),Issue::Invalid);
        let stop=Stop::new();stop.set(Issue::Stopped);assert_eq!(stop.first(Issue::Transport),Issue::Stopped);
        let stop=Stop::new();assert_eq!(stop.first(Issue::Deadline),Issue::Deadline);assert_eq!(stop.first(Issue::Stopped),Issue::Deadline);
    }
    #[cfg(feature="upload-qualification")]
    #[test]fn upload_interruption_does_not_call_invalid_input_a_user_stop(){
        use crate::upload::{Failure,Phase,Interrupted};
        for(first,expected)in[(Issue::Invalid,Failure::Protocol),(Issue::InputClosed,Failure::Io),(Issue::Stopped,Failure::Stopped)]{
            let stop=Stop::new();stop.set(first);
            let error=crate::ssh::SendFailure::Body(Interrupted{cause:Failure::Stopped,phase:Phase::Authorization,temporary_may_exist:true,publication_may_have_happened:false});
            let(reason,observation)=upload_observed_failure(&stop,error);assert_eq!(reason,first);assert_eq!(observation.cause,expected);assert!(observation.temporary_may_exist&&!observation.publication_may_have_happened);
        }
    }
}
fn run_mode(mode:Mode)->i32{
    // FD3 is an inherited private socket. No address, credential, filename,
    // catalog path, config file or agent is accepted through argv/environment.
    unsafe extern "C"{fn fcntl(fd:i32,command:i32,...)->i32;}
    if unsafe{fcntl(3,1)}<0{return 2}
    let stream=unsafe{std::os::unix::net::UnixStream::from_raw_fd(3)};
    if stream.peer_addr().is_err()||stream.set_nonblocking(true).is_err(){return 2}
    let mut terminal=match stream.try_clone(){Ok(stream)=>stream,Err(_)=>return 2};
    let runtime=match tokio::runtime::Builder::new_current_thread().enable_all().build(){Ok(runtime)=>runtime,Err(_)=>return 2};
    let metrics=runtime.handle().clone();let state=Arc::new(Mutex::new(WriteState{session:None,sequence:0,valid:true,mode}));
    let writer=Arc::new(Mutex::new(None));
    let outcome=runtime.block_on(async{match UnixStream::from_std(stream){Ok(stream)=>execute(stream,state.clone(),mode,writer.clone()).await,
        Err(_)=>Outcome{reason:Issue::Invalid,close_ack:false,ssh_task_ended:false,jump_task_ended:false}}});
    let before=metrics.metrics().num_alive_tasks();drop(runtime);let after=metrics.metrics().num_alive_tasks();
    let catalog=match writer.lock().unwrap().take(){None=>0,Some(owner)=>if owner.join(){1}else{2}};
    if after!=0{return 3}
    let state=state.lock().unwrap();let Some(session)=state.session else{return 2};if !state.valid{return 3}
    let mut bytes=ipc::header_for(mode,session,state.sequence,107);
    bytes.extend([outcome.reason as u8,u8::from(outcome.close_ack),u8::from(outcome.ssh_task_ended)]);
    bytes.extend((before as u64).to_be_bytes());bytes.extend((after as u64).to_be_bytes());
    if mode.catalog(){bytes.push(catalog)}
    if mode.jump(){bytes.push(u8::from(outcome.jump_task_ended))}
    // Only after runtime disposal: a bounded blocking write on the retained
    // private descriptor. Parent must still prove EOF and actual process exit.
    if terminal.set_nonblocking(false).is_err()||terminal.set_write_timeout(Some(Duration::from_millis(500))).is_err(){return 3}
    if terminal.write_all(&(bytes.len()as u32).to_be_bytes()).is_err()||terminal.write_all(&bytes).is_err(){return 3}0
}

#[cfg(test)]mod tests{
    use super::*;
    use std::io::Read;
    #[cfg(feature="folder-download-qualification")]
    #[test]fn missing_observed_folder_member_is_changed_while_denial_is_distinct(){
        use crate::folder_download::Failure as F;
        assert_eq!(folder_error(F::Metadata(reader::Failure::Status(2))),Issue::SourceChanged);
        assert_eq!(folder_error(F::Metadata(reader::Failure::Status(3))),Issue::Denied);
        assert_eq!(folder_error(F::Metadata(reader::Failure::Timeout)),Issue::Deadline);
    }
    #[test]fn unix_terminal_writer_survives_runtime_disposal(){
        let(stream,mut peer)=std::os::unix::net::UnixStream::pair().unwrap();
        peer.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
        stream.set_nonblocking(true).unwrap();let mut terminal=stream.try_clone().unwrap();
        let runtime=tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async{
            let(read,write)=UnixStream::from_std(stream).unwrap().into_split();drop(read);
            let state=Arc::new(Mutex::new(WriteState{session:Some([1;16]),sequence:0,valid:true,mode:Mode::Batches}));
            relinquish_output(Output{stream:write,state});
        });drop(runtime);
        terminal.set_nonblocking(false).unwrap();terminal.set_write_timeout(Some(Duration::from_millis(500))).unwrap();
        assert!(terminal.write_all(b"closed").is_ok(),"Runtime disposal shut down the retained terminal writer");
        drop(terminal);
        let mut value=Vec::new();peer.read_to_end(&mut value).unwrap();assert_eq!(value,b"closed");
    }
}
