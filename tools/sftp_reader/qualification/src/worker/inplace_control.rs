//! Serial M/N owner. Each live token owns its ORIGINAL RW channel/handle.
//! Never reconstruct a handle/token from a journal, path or reconnect.
use super::*;
use crate::upload::{self,inplace_v1::{self,Observed,Step,Control,ReadSink}};
use ring::rand::SecureRandom;
use std::collections::{HashMap,VecDeque};
type Held=inplace_v1::Session<russh::ChannelStream<russh::client::Msg>>;
fn limits()->upload::Limits{upload::Limits{request_deadline:Duration::from_secs(10),total_deadline:Duration::from_secs(120)}}
fn token()->Result<[u8;16],Issue>{let mut bytes=[0;16];ring::rand::SystemRandom::new().fill(&mut bytes).map_err(|_|Issue::Transport)?;if bytes==[0;16]{return Err(Issue::Transport)}Ok(bytes)}
fn attrs(bytes:&mut Vec<u8>,v:Observed){bytes.extend(v.size.to_be_bytes());bytes.extend(v.modified.to_be_bytes());bytes.extend(v.mode.to_be_bytes());bytes.extend(v.uid.to_be_bytes());bytes.extend(v.gid.to_be_bytes());}
fn step_bytes(bytes:&mut Vec<u8>,step:Step){bytes.extend([step.sequence,step.kind as u8]);bytes.extend(step.offset.to_be_bytes());bytes.extend(step.count.to_be_bytes());}
struct Live{revision:u64,held:Held}
#[derive(Default)]pub(super) struct Baselines{values:HashMap<[u8;16],Live>,releases:VecDeque<Release>}
#[derive(Clone,Copy)]struct Release{request:[u8;16],token:[u8;16],revision:u64,result:u8}
impl Release{fn bytes(self)->Vec<u8>{let mut out=self.request.to_vec();out.extend(self.token);out.extend(self.revision.to_be_bytes());out.extend([self.result,u8::from(self.result==1||self.result==2),u8::from(self.result==1||self.result==2)]);out}}
impl Baselines{
    pub(super) fn conflicts(&self,path:&str)->bool{self.values.values().any(|live|live.held.path==path)}
    pub(super) fn conflicts_within(&self,directory:&str)->bool{
        self.values.values().any(|live|same_or_descendant(&live.held.path,directory))
    }
    fn insert(&mut self,id:[u8;16],revision:u64,held:Held)->Result<(),Issue>{
        if id==[0;16]||revision==0||self.values.len()>=2||self.values.contains_key(&id){return Err(Issue::Phase)}
        self.values.insert(id,Live{revision,held});Ok(())
    }
    pub(super) async fn begin(&mut self,ssh:&mut Verified,output:&mut Output,input:&mut mpsc::Receiver<Command>,stop:&Stop,
        request:[u8;16],generation:[u8;16],revision:u64,observation:u64,path:String,expected:crate::wire::Metadata)->Result<(),Issue>{
        if self.values.len()>=2{return Err(Issue::Phase)}
        let sink=ReadOutput{output,request,generation,path:&path};
        let held=match ssh.open_inplace_v3(path.clone(),expected,sink,limits(),Some(stop.catalog.clone())).await {
            Ok(held)=>held,
            Err(inplace_v1::OpenFailure::Rejected(reason))=>{
                // open_inplace_v3 joined this exact subsystem's real Close ACK.
                // No header/body/baseline or mutation exists for this request.
                let(code,status)=match reason {
                    inplace_v1::EditRejection::SyncUnavailable=>(1u8,0u32),
                    inplace_v1::EditRejection::ReadWriteDenied=>(2u8,3u32),
                };
                let mut payload=request.to_vec();payload.extend(generation);payload.extend(revision.to_be_bytes());
                payload.extend(observation.to_be_bytes());payload.push(code);payload.extend(status.to_be_bytes());
                return guarded(stop,output.event(201,&payload)).await;
            },
            Err(inplace_v1::OpenFailure::Fatal(cause))=>return Err(issue_for(cause)),
        };
        let mut payload=request.to_vec();payload.extend(held.digest);payload.extend(held.observed.size.to_be_bytes());output.event(192,&payload).await?;
        let accepted=guarded(stop,async{tokio::time::timeout(Duration::from_secs(10),input.recv()).await.map_err(|_|Issue::Deadline)?.ok_or(Issue::InputClosed)}).await?;
        let Command::AcceptInPlace{request:actual,digest:sealed}=accepted else{return Err(Issue::Phase)};
        if actual!=request||sealed!=held.digest{return Err(Issue::SourceChanged)}
        let id=token()?;let digest=held.digest;self.insert(id,1,held)?;
        let mut payload=request.to_vec();payload.extend(id);payload.extend(1u64.to_be_bytes());payload.extend(digest);payload.extend([1,1,1]);
        output.event(193,&payload).await
    }
    pub(super) async fn save(&mut self,output:&mut Output,input:&mut mpsc::Receiver<Command>,
        request:[u8;16],id:[u8;16],revision:u64,generation:[u8;16],size:u64,digest:[u8;32])->Result<(),Issue>{
        let Live{revision:actual,mut held}=self.values.remove(&id).ok_or(Issue::Phase)?;
        if actual!=revision||revision==u64::MAX{return Err(Issue::Phase)}
        let source=InPlaceInput{output,input,request,size,digest};
        // Consumed before any source/permission await. No failed Save can be
        // retried from this token even if no WRITE ACK reached the parent.
        match held.save(source,limits()).await{
            Ok(receipt)=>{let next=token()?;self.insert(next,revision+1,held)?;
                let mut payload=request.to_vec();payload.extend(generation);payload.extend(next);payload.extend((revision+1).to_be_bytes());
                payload.extend(receipt.bytes.to_be_bytes());payload.extend(receipt.digest);attrs(&mut payload,receipt.observed);
                payload.extend([receipt.facts.requested,receipt.facts.acknowledged,1,1,1,1]);output.event(197,&payload).await},
            Err(error)=>{let mut payload=request.to_vec();payload.extend([error.phase as u8,error.facts.requested,error.facts.acknowledged]);
                let(code,status)=failure(error.cause);payload.push(code);payload.extend(status.to_be_bytes());let _=output.event(198,&payload).await;
                // The held channel drops; all remaining authorities invalidate
                // with the enclosing actual SSH/session drain. No rollback.
                Err(Issue::SourceChanged)}
        }
    }
    pub(super) async fn release(&mut self,output:&mut Output,request:[u8;16],id:[u8;16],revision:u64)->Result<(),Issue>{
        if let Some(prior)=self.releases.iter().find(|v|v.request==request){
            let result=if prior.token==id&&prior.revision==revision&&(prior.result==1||prior.result==2){2}else{3};
            return output.event(199,&Release{request,token:id,revision,result}.bytes()).await
        }
        if !self.values.get(&id).is_some_and(|v|v.revision==revision){
            return output.event(199,&Release{request,token:id,revision,result:3}.bytes()).await
        }
        let live=self.values.remove(&id).ok_or(Issue::Phase)?;
        live.held.release(limits()).await.map_err(|_|Issue::Transport)?;
        let receipt=Release{request,token:id,revision,result:1};
        if self.releases.len()==32{self.releases.pop_front();}self.releases.push_back(receipt);
        output.event(199,&receipt.bytes()).await
    }
}
fn same_or_descendant(path:&str,directory:&str)->bool{
    path==directory||path.strip_prefix(directory).is_some_and(|tail|tail.starts_with('/'))
}
#[cfg(test)]mod subtree_tests{
    use super::same_or_descendant;
    #[test]fn editor_path_requires_a_component_boundary(){
        assert!(same_or_descendant("/generated/Empty/file.txt","/generated/Empty"));
        assert!(same_or_descendant("/generated/Empty","/generated/Empty"));
        assert!(!same_or_descendant("/generated/Empty2/file.txt","/generated/Empty"));
        assert!(!same_or_descendant("/generated/Other/file.txt","/generated/Empty"));
    }
}
fn issue_for(cause:upload::Failure)->Issue{use upload::Failure as F;
    match cause{F::Stopped=>Issue::Stopped,F::Timeout=>Issue::Deadline,F::Status(3)=>Issue::Denied,
        F::Input|F::Protocol=>Issue::Invalid,F::Conflict|F::SourceChanged=>Issue::SourceChanged,F::UnsupportedSync=>Issue::Denied,_=>Issue::Transport}}
fn failure(cause:upload::Failure)->(u8,u32){use upload::Failure as F;
    (match cause{F::Input=>0,F::Io=>1,F::Timeout=>2,F::Stopped=>3,F::Truncated=>4,F::Protocol=>5,F::Status(_)=>6,F::Conflict=>7,F::UnsupportedSync=>8,F::Verification=>9,F::SourceChanged=>10},if let F::Status(v)=cause{v}else{0})}
struct ReadOutput<'a>{output:&'a mut Output,request:[u8;16],generation:[u8;16],path:&'a str}
impl ReadSink for ReadOutput<'_>{
    async fn begin(&mut self,observed:Observed)->Result<(),upload::Failure>{let mut payload=self.request.to_vec();payload.extend(self.generation);attrs(&mut payload,observed);
        ipc::field(&mut payload,self.path.as_bytes()).map_err(|_|upload::Failure::Protocol)?;self.output.event(190,&payload).await.map_err(upload_local_issue)}
    async fn chunk(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),upload::Failure>{let mut payload=self.request.to_vec();payload.extend(offset.to_be_bytes());ipc::field(&mut payload,&bytes).map_err(|_|upload::Failure::Protocol)?;
        self.output.event(191,&payload).await.map_err(upload_local_issue)}
}
struct InPlaceInput<'a>{output:&'a mut Output,input:&'a mut mpsc::Receiver<Command>,request:[u8;16],size:u64,digest:[u8;32]}
impl upload::Source for InPlaceInput<'_>{
    fn size(&self)->u64{self.size}
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>,upload::Failure>{
        let mut payload=self.request.to_vec();payload.extend(offset.to_be_bytes());payload.extend((count as u32).to_be_bytes());self.output.event(194,&payload).await.map_err(upload_local_issue)?;
        let Some(Command::InPlaceBytes{request,offset:actual,mut bytes})=self.input.recv().await else{return Err(upload::Failure::Protocol)};
        if request!=self.request||offset!=actual||bytes.len()!=count{return Err(upload::Failure::SourceChanged)}Ok(std::mem::take(&mut *bytes))}
    async fn permit_publication(&mut self,_:[u8;32])->Result<(),upload::Failure>{Err(upload::Failure::Protocol)}
}
impl Control for InPlaceInput<'_>{
    fn expected_digest(&self)->[u8;32]{self.digest}
    async fn permit(&mut self,step:Step,digest:[u8;32])->Result<(),upload::Failure>{
        if digest!=self.digest{return Err(upload::Failure::SourceChanged)}
        let mut payload=self.request.to_vec();step_bytes(&mut payload,step);payload.extend(digest);self.output.event(195,&payload).await.map_err(upload_local_issue)?;
        let Some(Command::InPlacePermit{request,sequence,kind,offset,count,digest:actual})=self.input.recv().await else{return Err(upload::Failure::Protocol)};
        if request!=self.request||sequence!=step.sequence||kind!=step.kind as u8||offset!=step.offset||count!=step.count||actual!=digest{return Err(upload::Failure::SourceChanged)}Ok(())}
    async fn observed(&mut self,step:Step)->Result<(),upload::Failure>{let mut payload=self.request.to_vec();step_bytes(&mut payload,step);self.output.event(196,&payload).await.map_err(upload_local_issue)}
}
