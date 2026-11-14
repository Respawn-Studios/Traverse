//! Experimental recoverable original Save. This child uses the ACTUAL serial
//! upload Channel. No generic extension/path callback, cache URL or CAS promise.
use super::{Channel,Expected,Failure,Limits,Reply,Source,field,string};
use crate::wire::{self,ReplyKind};
use sha2::{Digest,Sha256};
use std::{collections::HashSet,fmt,sync::{Arc,atomic::AtomicBool},time::Duration};
use tokio::{io::{AsyncRead,AsyncWrite},time::Instant};
pub(crate) const MAX_BYTES:u64=1<<20;

pub(crate) fn version(bytes:&[u8])->Result<(),Failure>{
    if wire::incoming(bytes).map_err(|_|Failure::Protocol)?.kind!=ReplyKind::Version{return Err(Failure::Protocol)}
    let mut at=5;let mut seen=HashSet::new();let mut required=0u8;
    while at<bytes.len(){
        let name=string(bytes,&mut at,8192)?;let value=string(bytes,&mut at,8192)?;
        if !seen.insert(name){return Err(Failure::Protocol)}
        let bit=match name{b"posix-rename@openssh.com"=>1,b"hardlink@openssh.com"=>2,b"fsync@openssh.com"=>4,_=>0};
        if bit!=0{if value!=b"1"{return Err(Failure::UnsupportedSync)}required|=bit;}
    }
    if required!=7{return Err(Failure::UnsupportedSync)}Ok(())
}

#[derive(Clone,Copy,PartialEq,Eq)]
pub(crate) struct Observed{pub size:u64,pub modified:u32,pub mode:u32,pub uid:u32,pub gid:u32}
impl fmt::Debug for Observed{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP edit attributes>")}}
impl Observed{
    pub(crate) fn parse(bytes:&[u8])->Result<Self,Failure>{
        if wire::incoming(bytes).map_err(|_|Failure::Protocol)?.kind!=ReplyKind::Attrs{return Err(Failure::Protocol)}
        // New edit-only codec requires size, uid/gid, permissions and times.
        // Existing metadata/fresh-upload parsers and G-J semantics stay exact.
        if bytes.len()!=37||u32::from_be_bytes(bytes[5..9].try_into().map_err(|_|Failure::Protocol)?)!=15{return Err(Failure::Protocol)}
        Ok(Self{size:u64::from_be_bytes(bytes[9..17].try_into().map_err(|_|Failure::Protocol)?),
            uid:u32::from_be_bytes(bytes[17..21].try_into().map_err(|_|Failure::Protocol)?),
            gid:u32::from_be_bytes(bytes[21..25].try_into().map_err(|_|Failure::Protocol)?),
            mode:u32::from_be_bytes(bytes[25..29].try_into().map_err(|_|Failure::Protocol)?),
            modified:u32::from_be_bytes(bytes[33..37].try_into().map_err(|_|Failure::Protocol)?)})
    }
    pub(crate) fn regular(self)->bool{self.mode&0o170000==0o100000&&self.mode&0o7000==0&&self.size<=MAX_BYTES}
    fn private_directory(self)->bool{self.mode&0o177777==0o040700}
}

#[derive(Clone)]pub(crate) struct Baseline{
    pub token:[u8;16],pub revision:u64,pub path:String,pub observed:Observed,pub digest:[u8;32],
}
impl fmt::Debug for Baseline{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP live edit baseline>")}}
fn admitted_path(path:&str)->bool{
    path.starts_with('/')&&!path.ends_with('/')&&path.len()<=8192&&!path.contains('\0')
        &&path.split('/').skip(1).all(|p|!p.is_empty()&&p!="."&&p!="..")&&path.split('/').count()<=128
}
impl Baseline{
    pub(crate) fn new(token:[u8;16],revision:u64,path:String,observed:Observed,digest:[u8;32])->Result<Self,Failure>{
        if token==[0;16]||revision==0||!observed.regular()||!admitted_path(&path){return Err(Failure::Input)}
        Ok(Self{token,revision,path,observed,digest})
    }
}
pub(crate) struct Target{pub operation:[u8;16],pub original:String,pub directory:String,pub candidate:String,pub probe:String,pub previous:String}
impl fmt::Debug for Target{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP original Save roles>")}}
impl Target{
    pub(crate) fn new(baseline:&Baseline,operation:[u8;16])->Result<Self,Failure>{
        if operation==[0;16]{return Err(Failure::Input)}
        let(parent,leaf)=baseline.path.rsplit_once('/').ok_or(Failure::Input)?;
        if leaf.is_empty()||leaf.len()>255||parent.split('/').filter(|p|!p.is_empty()).count()>126{return Err(Failure::Input)}
        let token=operation.iter().map(|v|format!("{v:02X}")).collect::<String>();
        let directory=format!("{parent}/Traverse-Recovery-{token}");
        let target=Self{operation,original:baseline.path.clone(),candidate:format!("{directory}/candidate"),probe:format!("{directory}/link-check"),previous:format!("{directory}/previous"),directory};
        if [&target.original,&target.directory,&target.candidate,&target.probe,&target.previous].iter().any(|p|p.len()>8192){return Err(Failure::Input)}Ok(target)
    }
    pub(crate) fn role_digest(&self)->[u8;32]{
        let mut hash=Sha256::new();
        for path in [&self.original,&self.directory,&self.candidate,&self.probe,&self.previous]{hash.update((path.len()as u32).to_be_bytes());hash.update(path.as_bytes())}hash.finalize().into()
    }
}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]#[repr(u8)]pub(crate) enum Edge{Container=1,Stage=2,LinkCheck=3,Preserve=4,Publish=5,Restore=6}
impl Edge{pub(crate) fn bit(self)->u8{1<<(self as u8-1)}}
#[derive(Clone,Copy,Debug,Default,PartialEq,Eq)]pub(crate) struct Facts{pub requested:u8,pub acknowledged:u8}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]pub(crate) enum Phase{Admission,Negotiation,BaselineCheck,Container,Stage,Attributes,LinkCheck,FreshCheck,Preserve,MovedCheck,Publish,FinalReadback,Shutdown}
#[derive(Debug,PartialEq,Eq)]pub(crate) enum Cause{Wire(Failure),Conflict,UnsupportedMetadata,LocalBarrier,SourceChanged}
#[derive(Debug,PartialEq,Eq)]pub(crate) struct Interrupted{pub cause:Cause,pub phase:Phase,pub facts:Facts}
#[derive(Debug,PartialEq,Eq)]pub(crate) struct Receipt{pub bytes:u64,pub digest:[u8;32],pub facts:Facts,pub stream_shutdown:bool,pub aliases_retained:bool,pub previous_entry_retained:bool,pub observed:Observed}

/// Implemented by the existing private worker source channel. Native views
/// cannot supply this trait. Permits bind the actual durable local edit record.
pub(crate) trait Control:Source{
    fn expected_digest(&self)->[u8;32];
    async fn permit_edge(&mut self,edge:Edge,facts:Facts,roles:[u8;32])->Result<(),Failure>;
    async fn edge_observed(&mut self,edge:Edge,facts:Facts)->Result<(),Failure>;
}
type Result<T,E=Cause>=std::result::Result<T,E>;
async fn attributes<S:AsyncRead+AsyncWrite+Unpin>(c:&mut Channel<S>,kind:u8,path:&[u8])->Result<Observed>{
    let mut body=Vec::new();field(&mut body,path);
    match c.request(kind,body,Expected::EditAttributes).await.map_err(Cause::Wire)?{Reply::EditAttributes(v)=>Ok(v),_=>Err(Cause::Wire(Failure::Protocol))}
}
async fn checked<S:AsyncRead+AsyncWrite+Unpin>(c:&mut Channel<S>,path:&str,expected:Observed)->Result<[u8;32]>{
    if !expected.regular(){return Err(Cause::UnsupportedMetadata)}
    if attributes(c,7,path.as_bytes()).await?!=expected{return Err(Cause::Conflict)}
    let mut open=Vec::new();field(&mut open,path.as_bytes());open.extend(1u32.to_be_bytes());open.extend(0u32.to_be_bytes());
    let Reply::Handle(handle)=c.request(3,open,Expected::Handle).await.map_err(Cause::Wire)?else{return Err(Cause::Wire(Failure::Protocol))};
    if attributes(c,8,&handle).await?!=expected{return Err(Cause::Conflict)}
    let digest=c.digest(&handle,expected.size).await.map_err(Cause::Wire)?;
    if attributes(c,8,&handle).await?!=expected{return Err(Cause::Conflict)}
    c.handle(4,&handle,Expected::Ok).await.map_err(Cause::Wire)?;
    if attributes(c,7,path.as_bytes()).await?!=expected{return Err(Cause::Conflict)}Ok(digest)
}
async fn permission<S:AsyncRead+AsyncWrite+Unpin,T:Control>(c:&Channel<S>,source:&mut T,target:&Target,edge:Edge,facts:&mut Facts)->Result<()>{
    c.source(source.permit_edge(edge,*facts,target.role_digest())).await.map_err(|_|Cause::LocalBarrier)?;
    facts.requested|=edge.bit();Ok(())
}
async fn acknowledged<S:AsyncRead+AsyncWrite+Unpin,T:Control>(c:&Channel<S>,source:&mut T,edge:Edge,facts:&mut Facts)->Result<()>{
    facts.acknowledged|=edge.bit();c.source(source.edge_observed(edge,*facts)).await.map_err(|_|Cause::LocalBarrier)
}
async fn link<S:AsyncRead+AsyncWrite+Unpin>(c:&mut Channel<S>,source:&str,destination:&str)->Result<()>{
    let mut payload=Vec::new();field(&mut payload,b"hardlink@openssh.com");field(&mut payload,source.as_bytes());field(&mut payload,destination.as_bytes());
    c.request(200,payload,Expected::Ok).await.map_err(Cause::Wire)?;Ok(())
}

pub(crate) async fn send<S:AsyncRead+AsyncWrite+Unpin,T:Control>(stream:S,baseline:&Baseline,target:&Target,mut source:T,
    limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Receipt,Interrupted>{
    let mut phase=Phase::Admission;let mut facts=Facts::default();
    let work=async{
        if source.size()>MAX_BYTES||limits.total_deadline.is_zero()||limits.total_deadline>Duration::from_secs(120){return Err(Cause::UnsupportedMetadata)}
        super::admitted_source(source.size(),limits).map_err(Cause::Wire)?;
        let mut c=Channel{stream,next:1,deadline:limits.request_deadline,end:Instant::now()+limits.total_deadline,stop};
        phase=Phase::Negotiation;c.exchange(vec![1,0,0,0,3],None,Expected::EditVersion).await.map_err(Cause::Wire)?;
        phase=Phase::BaselineCheck;
        if checked(&mut c,&target.original,baseline.observed).await?!=baseline.digest{return Err(Cause::Conflict)}
        phase=Phase::Container;permission(&c,&mut source,target,Edge::Container,&mut facts).await?;
        let mut mkdir=Vec::new();field(&mut mkdir,target.directory.as_bytes());mkdir.extend(4u32.to_be_bytes());mkdir.extend(0o700u32.to_be_bytes());
        c.request(14,mkdir,Expected::Ok).await.map_err(Cause::Wire)?;acknowledged(&c,&mut source,Edge::Container,&mut facts).await?;
        let container=attributes(&mut c,7,target.directory.as_bytes()).await?;
        if !container.private_directory()||container.uid!=baseline.observed.uid{return Err(Cause::UnsupportedMetadata)}
        phase=Phase::Stage;permission(&c,&mut source,target,Edge::Stage,&mut facts).await?;
        let mut open=Vec::new();field(&mut open,target.candidate.as_bytes());open.extend(0x2bu32.to_be_bytes());open.extend(4u32.to_be_bytes());open.extend(0o600u32.to_be_bytes());
        let Reply::Handle(handle)=c.request(3,open,Expected::Handle).await.map_err(Cause::Wire)?else{return Err(Cause::Wire(Failure::Protocol))};
        acknowledged(&c,&mut source,Edge::Stage,&mut facts).await?;
        let(mut offset,mut hash)=(0,Sha256::new());
        while offset<source.size(){
            let count=(source.size()-offset).min(super::MAX_CHUNK as u64)as usize;
            let bytes=c.source(source.next(offset,count)).await.map_err(Cause::Wire)?;
            if bytes.len()!=count{return Err(Cause::SourceChanged)}hash.update(&bytes);
            let mut write=Vec::new();field(&mut write,&handle);write.extend(offset.to_be_bytes());field(&mut write,&bytes);
            c.request(6,write,Expected::Ok).await.map_err(Cause::Wire)?;offset+=count as u64;
        }
        let digest:[u8;32]=hash.finalize().into();
        if digest!=source.expected_digest(){return Err(Cause::SourceChanged)}
        c.source(source.permit_publication(digest)).await.map_err(Cause::Wire)?;
        let created=attributes(&mut c,8,&handle).await?;
        if !created.regular()||created.size!=source.size()||created.mode&0o177777!=0o100600||created.uid!=baseline.observed.uid||created.gid!=baseline.observed.gid{return Err(Cause::UnsupportedMetadata)}
        if c.digest(&handle,source.size()).await.map_err(Cause::Wire)?!=digest{return Err(Cause::SourceChanged)}
        if attributes(&mut c,8,&handle).await?!=created{return Err(Cause::Conflict)}
        phase=Phase::Attributes;let mut mode=Vec::new();field(&mut mode,&handle);mode.extend(4u32.to_be_bytes());mode.extend((baseline.observed.mode&0o777).to_be_bytes());
        c.request(10,mode,Expected::Ok).await.map_err(Cause::Wire)?;
        let staged=attributes(&mut c,8,&handle).await?;
        if staged.size!=created.size||staged.uid!=created.uid||staged.gid!=created.gid||staged.mode!=baseline.observed.mode{return Err(Cause::UnsupportedMetadata)}
        let mut sync=Vec::new();field(&mut sync,b"fsync@openssh.com");field(&mut sync,&handle);c.request(200,sync,Expected::Ok).await.map_err(Cause::Wire)?;
        c.handle(4,&handle,Expected::Ok).await.map_err(Cause::Wire)?;
        phase=Phase::LinkCheck;permission(&c,&mut source,target,Edge::LinkCheck,&mut facts).await?;
        link(&mut c,&target.candidate,&target.probe).await?;acknowledged(&c,&mut source,Edge::LinkCheck,&mut facts).await?;
        phase=Phase::FreshCheck;
        if checked(&mut c,&target.original,baseline.observed).await?!=baseline.digest{return Err(Cause::Conflict)}
        c.named(7,&target.previous,Expected::Absent).await.map_err(Cause::Wire)?;
        phase=Phase::Preserve;permission(&c,&mut source,target,Edge::Preserve,&mut facts).await?;
        let mut rename=Vec::new();field(&mut rename,b"posix-rename@openssh.com");field(&mut rename,target.original.as_bytes());field(&mut rename,target.previous.as_bytes());
        c.request(200,rename,Expected::Ok).await.map_err(Cause::Wire)?;acknowledged(&c,&mut source,Edge::Preserve,&mut facts).await?;
        phase=Phase::MovedCheck;
        if checked(&mut c,&target.previous,baseline.observed).await?!=baseline.digest{return Err(Cause::Conflict)}
        if checked(&mut c,&target.candidate,staged).await?!=digest{return Err(Cause::SourceChanged)}
        let current_container=attributes(&mut c,7,target.directory.as_bytes()).await?;
        if !current_container.private_directory()||current_container.uid!=baseline.observed.uid{return Err(Cause::Conflict)}
        phase=Phase::Publish;permission(&c,&mut source,target,Edge::Publish,&mut facts).await?;
        // This is the ONLY original-name publication. Never rename fallback.
        link(&mut c,&target.candidate,&target.original).await?;acknowledged(&c,&mut source,Edge::Publish,&mut facts).await?;
        phase=Phase::FinalReadback;
        if checked(&mut c,&target.original,staged).await?!=digest{return Err(Cause::SourceChanged)}
        if checked(&mut c,&target.previous,baseline.observed).await?!=baseline.digest{return Err(Cause::Conflict)}
        phase=Phase::Shutdown;c.shutdown().await.map_err(Cause::Wire)?;
        Ok(Receipt{bytes:source.size(),digest,facts,stream_shutdown:true,aliases_retained:true,previous_entry_retained:true,observed:staged})
    }.await;
    work.map_err(|cause|Interrupted{cause,phase,facts})
}

/// Explicit selected read only; never called by catalog listing or search.
/// Shares the same strict serial Channel and validates the actual opened file.
pub(crate) trait ReadSink {
    async fn begin(&mut self,observed:Observed)->Result<(),Failure>;
    async fn chunk(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),Failure>;
}
pub(crate) async fn read<S:AsyncRead+AsyncWrite+Unpin,T:ReadSink>(stream:S,path:&str,
    expected:crate::wire::Metadata,mut sink:T,limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<(Observed,[u8;32]),Cause>{
    if !admitted_path(path)||expected.size.is_none_or(|n|n>MAX_BYTES)||expected.modified.is_none()||expected.permissions.is_none()
        ||limits.total_deadline>Duration::from_secs(120)||limits.total_deadline.is_zero(){return Err(Cause::UnsupportedMetadata)}
    super::admitted_source(expected.size.unwrap(),limits).map_err(Cause::Wire)?;
    let mut c=Channel{stream,next:1,deadline:limits.request_deadline,end:Instant::now()+limits.total_deadline,stop};
    c.exchange(vec![1,0,0,0,3],None,Expected::EditVersion).await.map_err(Cause::Wire)?;
    let observed=attributes(&mut c,7,path.as_bytes()).await?;
    if !observed.regular()||Some(observed.size)!=expected.size||Some(observed.modified)!=expected.modified
        ||Some(observed.mode)!=expected.permissions{return Err(Cause::Conflict)}
    c.source(sink.begin(observed)).await.map_err(Cause::Wire)?;
    let mut open=Vec::new();field(&mut open,path.as_bytes());open.extend(1u32.to_be_bytes());open.extend(0u32.to_be_bytes());
    let Reply::Handle(handle)=c.request(3,open,Expected::Handle).await.map_err(Cause::Wire)?else{return Err(Cause::Wire(Failure::Protocol))};
    if attributes(&mut c,8,&handle).await?!=observed{return Err(Cause::Conflict)}
    let(mut offset,mut hash)=(0,Sha256::new());
    while offset<observed.size{
        let count=(observed.size-offset).min(super::MAX_CHUNK as u64)as usize;
        let mut payload=Vec::new();field(&mut payload,&handle);payload.extend(offset.to_be_bytes());payload.extend((count as u32).to_be_bytes());
        let Reply::Data(bytes)=c.request(5,payload,Expected::Data(count)).await.map_err(Cause::Wire)?else{return Err(Cause::Conflict)};
        if bytes.is_empty()||bytes.len()>count{return Err(Cause::Conflict)}
        hash.update(&bytes);let found=bytes.len();c.source(sink.chunk(offset,bytes)).await.map_err(Cause::Wire)?;offset+=found as u64;
    }
    let mut eof=Vec::new();field(&mut eof,&handle);eof.extend(offset.to_be_bytes());eof.extend(1u32.to_be_bytes());
    if !matches!(c.request(5,eof,Expected::Data(1)).await.map_err(Cause::Wire)?,Reply::End){return Err(Cause::Conflict)}
    if attributes(&mut c,8,&handle).await?!=observed{return Err(Cause::Conflict)}
    c.handle(4,&handle,Expected::Ok).await.map_err(Cause::Wire)?;
    if attributes(&mut c,7,path.as_bytes()).await?!=observed{return Err(Cause::Conflict)}
    c.shutdown().await.map_err(Cause::Wire)?;Ok((observed,hash.finalize().into()))
}

#[cfg(test)]mod tests;
