//! K/L only. One existing serial worker owns both body channel and catalog.
//! No new SSH/authentication task, external source callback, retry or cleanup.
use super::*;
use crate::upload::{self,original::{self,Baseline,Observed,Edge,Facts,Control,ReadSink}};
use ring::rand::SecureRandom;
use std::collections::{HashMap,VecDeque};
fn limits()->upload::Limits{upload::Limits{request_deadline:Duration::from_secs(10),total_deadline:Duration::from_secs(120)}}
fn token()->Result<[u8;16],Issue>{let mut bytes=[0;16];ring::rand::SystemRandom::new().fill(&mut bytes).map_err(|_|Issue::Transport)?;if bytes==[0;16]{return Err(Issue::Transport)}Ok(bytes)}
fn attrs(bytes:&mut Vec<u8>,v:Observed){bytes.extend(v.size.to_be_bytes());bytes.extend(v.modified.to_be_bytes());bytes.extend(v.mode.to_be_bytes());bytes.extend(v.uid.to_be_bytes());bytes.extend(v.gid.to_be_bytes());}
#[derive(Default)]pub(super) struct Baselines{values:HashMap<[u8;16],Baseline>,releases:VecDeque<Release>}
#[derive(Clone,Copy)]struct Release{request:[u8;16],token:[u8;16],revision:u64,result:u8}
impl Release{fn bytes(self)->Vec<u8>{let mut out=self.request.to_vec();out.extend(self.token);out.extend(self.revision.to_be_bytes());out.push(self.result);out}}
impl Baselines{
    fn insert(&mut self,baseline:Baseline)->Result<(),Issue>{
        if self.values.len()>=2||self.values.contains_key(&baseline.token){return Err(Issue::Phase)}
        self.values.insert(baseline.token,baseline);Ok(())
    }
    /// Same concrete table used by the actual serial command loop. An ACK is
    /// emitted only after removal; no server request or implicit recovery cleanup.
    pub(super) fn release_request(&mut self,request:[u8;16],token:[u8;16],revision:u64)->Vec<u8>{
        if let Some(prior)=self.releases.iter().find(|v|v.request==request){
            let result=if prior.token==token&&prior.revision==revision{if prior.result==1{2}else{prior.result}}else{3};
            return Release{request,token,revision,result}.bytes()
        }
        let eligible=request!=[0;16]&&token!=[0;16]&&revision>0&&self.values.get(&token).is_some_and(|v|v.revision==revision);
        let result=if eligible{self.values.remove(&token);1}else{3};
        if self.releases.len()==32{self.releases.pop_front();}
        let receipt=Release{request,token,revision,result};self.releases.push_back(receipt);receipt.bytes()
    }
    pub(super) async fn begin(&mut self,ssh:&mut Verified,output:&mut Output,input:&mut mpsc::Receiver<Command>,stop:&Stop,
        request:[u8;16],generation:[u8;16],path:String,expected:crate::wire::Metadata)->Result<(),Issue>{
        if self.values.len()>=2{return Err(Issue::Phase)}
        let sink=ReadOutput{output,request,generation,path:&path};
        let (observed,digest)=ssh.read_original(&path,expected,sink,limits(),Some(stop.catalog.clone())).await.map_err(|_|Issue::SourceChanged)?;
        // No baseline authority exists until the parent has sealed the actual
        // private received spool and explicitly acknowledged this digest.
        let mut payload=request.to_vec();payload.extend(digest);payload.extend(observed.size.to_be_bytes());output.event(182,&payload).await?;
        let accepted=guarded(stop,async{tokio::time::timeout(Duration::from_secs(10),input.recv()).await.map_err(|_|Issue::Deadline)?.ok_or(Issue::InputClosed)}).await?;
        let Command::AcceptBaseline{request:actual,digest:sealed}=accepted else{return Err(Issue::Phase)};
        if actual!=request||sealed!=digest{return Err(Issue::SourceChanged)}
        let id=token()?;let baseline=Baseline::new(id,1,path,observed,digest).map_err(|_|Issue::Invalid)?;
        self.insert(baseline)?;let mut payload=request.to_vec();payload.extend(id);payload.extend(1u64.to_be_bytes());payload.extend(digest);
        output.event(183,&payload).await
    }
    pub(super) async fn save(&mut self,ssh:&mut Verified,output:&mut Output,input:&mut mpsc::Receiver<Command>,stop:&Stop,
        request:[u8;16],id:[u8;16],revision:u64,operation:[u8;16],generation:[u8;16],size:u64,digest:[u8;32])->Result<(),Issue>{
        let baseline=self.values.remove(&id).ok_or(Issue::Phase)?;
        if baseline.revision!=revision||revision==u64::MAX{return Err(Issue::Phase)}
        let target=original::Target::new(&baseline,operation).map_err(|_|Issue::Invalid)?;
        let source=OriginalInput{output,input,request,size,digest};
        // A consumed baseline cannot be replayed after an uncertain attempt.
        let result=ssh.save_original(&baseline,&target,source,limits(),Some(stop.catalog.clone())).await;
        match result{
            Ok(receipt)=>{
                let next=token()?;let next_revision=revision+1;
                self.insert(Baseline::new(next,next_revision,baseline.path,receipt.observed,receipt.digest).map_err(|_|Issue::Invalid)?)?;
                let mut payload=request.to_vec();payload.extend(generation);payload.extend(next);payload.extend(next_revision.to_be_bytes());
                payload.extend(receipt.bytes.to_be_bytes());payload.extend(receipt.digest);attrs(&mut payload,receipt.observed);
                payload.extend([receipt.facts.requested,receipt.facts.acknowledged,1,1,1]);output.event(187,&payload).await
            },
            Err(error)=>{
                let mut payload=request.to_vec();payload.extend([error.phase as u8,error.facts.requested,error.facts.acknowledged]);
                let(cause,wire,status)=match error.cause{
                    original::Cause::Wire(value)=>{let code=match value{upload::Failure::Input=>0,upload::Failure::Io=>1,upload::Failure::Timeout=>2,upload::Failure::Stopped=>3,upload::Failure::Truncated=>4,upload::Failure::Protocol=>5,upload::Failure::Status(_)=>6,upload::Failure::Conflict=>7,upload::Failure::UnsupportedSync=>8,upload::Failure::Verification=>9,upload::Failure::SourceChanged=>10};(0,code,if let upload::Failure::Status(v)=value{v}else{0})},
                    original::Cause::Conflict=>(1,0,0),original::Cause::UnsupportedMetadata=>(2,0,0),original::Cause::LocalBarrier=>(3,0,0),original::Cause::SourceChanged=>(4,0,0)};
                payload.extend([cause,wire]);payload.extend(status.to_be_bytes());
                let _=output.event(188,&payload).await;Err(Issue::SourceChanged)
            }
        }
    }
}
struct ReadOutput<'a>{output:&'a mut Output,request:[u8;16],generation:[u8;16],path:&'a str}
impl ReadSink for ReadOutput<'_>{
    async fn begin(&mut self,observed:Observed)->Result<(),upload::Failure>{
        let mut payload=self.request.to_vec();payload.extend(self.generation);attrs(&mut payload,observed);
        ipc::field(&mut payload,self.path.as_bytes()).map_err(|_|upload::Failure::Protocol)?;
        self.output.event(180,&payload).await.map_err(upload_local_issue)
    }
    async fn chunk(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),upload::Failure>{
        let mut payload=self.request.to_vec();payload.extend(offset.to_be_bytes());ipc::field(&mut payload,&bytes).map_err(|_|upload::Failure::Protocol)?;
        self.output.event(181,&payload).await.map_err(upload_local_issue)
    }
}
struct OriginalInput<'a>{output:&'a mut Output,input:&'a mut mpsc::Receiver<Command>,request:[u8;16],size:u64,digest:[u8;32]}
impl upload::Source for OriginalInput<'_>{
    fn size(&self)->u64{self.size}
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>,upload::Failure>{
        let mut payload=self.request.to_vec();payload.extend(offset.to_be_bytes());payload.extend((count as u32).to_be_bytes());self.output.event(184,&payload).await.map_err(upload_local_issue)?;
        let Some(Command::EditBytes{request,offset:actual,mut bytes})=self.input.recv().await else{return Err(upload::Failure::Protocol)};
        if request!=self.request||offset!=actual||bytes.len()!=count{return Err(upload::Failure::SourceChanged)}Ok(std::mem::take(&mut *bytes))
    }
    async fn permit_publication(&mut self,digest:[u8;32])->Result<(),upload::Failure>{
        if digest!=self.digest{return Err(upload::Failure::SourceChanged)}
        self.permission(0,Facts::default(),[0;32]).await
    }
}
impl Control for OriginalInput<'_>{
    fn expected_digest(&self)->[u8;32]{self.digest}
    async fn permit_edge(&mut self,edge:Edge,facts:Facts,roles:[u8;32])->Result<(),upload::Failure>{self.permission(edge as u8,facts,roles).await}
    async fn edge_observed(&mut self,edge:Edge,facts:Facts)->Result<(),upload::Failure>{
        let mut payload=self.request.to_vec();payload.extend([edge as u8,facts.requested,facts.acknowledged]);self.output.event(186,&payload).await.map_err(upload_local_issue)
    }
}
impl OriginalInput<'_>{
    async fn permission(&mut self,edge:u8,facts:Facts,roles:[u8;32])->Result<(),upload::Failure>{
        let mut payload=self.request.to_vec();payload.extend([edge,facts.requested,facts.acknowledged]);payload.extend(roles);payload.extend(self.digest);
        self.output.event(185,&payload).await.map_err(upload_local_issue)?;
        let Some(Command::EditPermit{request,edge:actual,requested,acknowledged,roles:checked,digest})=self.input.recv().await else{return Err(upload::Failure::Protocol)};
        if request!=self.request||edge!=actual||requested!=facts.requested||acknowledged!=facts.acknowledged||checked!=roles||digest!=self.digest{return Err(upload::Failure::SourceChanged)}Ok(())
    }
}

#[cfg(test)]mod tests{
    use super::*;
    fn baseline(id:u8)->Baseline{Baseline::new([id;16],1,"/generated/file.txt".into(),
        Observed{size:9,modified:77,mode:0o100640,uid:501,gid:20},[1;32]).unwrap()}
    #[test]fn original_release_reuses_two_tokens_over_sixteen_actual_table_cycles(){
        let mut table=Baselines::default();
        for n in 0u8..16{
            table.insert(baseline(1)).unwrap();table.insert(baseline(2)).unwrap();assert!(table.insert(baseline(3)).is_err());
            let receipt=table.release_request([n+10;16],[1;16],1);assert_eq!(receipt.len(),41);assert_eq!(receipt[40],1);
            assert_eq!(&receipt[..16],&[n+10;16]);assert_eq!(&receipt[16..32],&[1;16]);assert_eq!(&receipt[32..40],&1u64.to_be_bytes());
            table.insert(baseline(3)).unwrap();assert_eq!(table.release_request([n+30;16],[2;16],1)[40],1);
            assert_eq!(table.release_request([n+60;16],[3;16],1)[40],1);assert!(table.values.is_empty());
        }
        assert_eq!(table.releases.len(),32);
    }
    #[test]fn original_release_exact_duplicate_and_wrong_revision_are_distinct(){
        let mut table=Baselines::default();table.insert(baseline(1)).unwrap();
        assert_eq!(table.release_request([4;16],[1;16],2)[40],3);assert_eq!(table.values.len(),1);
        assert_eq!(table.release_request([5;16],[1;16],1)[40],1);assert!(table.values.is_empty());
        assert_eq!(table.release_request([5;16],[1;16],1)[40],2);
        assert_eq!(table.release_request([5;16],[2;16],1)[40],3);
        assert_eq!(table.release_request([6;16],[1;16],1)[40],3);
    }
    #[test]fn original_release_receipt_eviction_does_not_invent_a_terminal(){
        let mut table=Baselines::default();
        for n in 1u8..=40{table.insert(baseline(1)).unwrap();assert_eq!(table.release_request([n;16],[1;16],1)[40],1);}
        assert_eq!(table.releases.len(),32);assert_eq!(table.release_request([1;16],[1;16],1)[40],3);
    }
}
