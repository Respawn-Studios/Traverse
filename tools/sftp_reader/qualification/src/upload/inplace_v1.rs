//! M/N v1 only. Retained authenticated nontruncating READ|WRITE handle.
//! No rename/link/remove/chmod/chown, path-based write reopen, retry or rollback.
use super::{Channel,Expected,Failure,Limits,Reply,Source,field,string};
use crate::wire::{self,Metadata,ReplyKind};
use sha2::{Digest,Sha256};
use std::{collections::HashSet,fmt,sync::{Arc,atomic::AtomicBool},time::Duration};
use tokio::{io::{AsyncRead,AsyncWrite},time::Instant};
use zeroize::Zeroizing;
pub(crate) const MAX_BYTES:u64=1<<20;
/// Only these two typed, pre-header outcomes can preserve a connection.
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub(crate) enum EditRejection { SyncUnavailable, ReadWriteDenied }
#[derive(Debug,PartialEq,Eq)]
pub(crate) enum OpenFailure { Rejected(EditRejection), Fatal(Failure) }
impl From<Failure> for OpenFailure { fn from(value:Failure)->Self { Self::Fatal(value) } }
/// The kernel transfers the SAME stream back only at its two proven pre-body
/// rejection edges. Keeping it owned prevents russh's Drop-close from removing
/// the established channel before the peer's actual Close can be observed.
pub(crate) enum PreflightOpenFailure<S> {
    Rejected { reason:EditRejection, stream:S },
    Fatal(Failure),
}
impl<S> From<Failure> for PreflightOpenFailure<S> {
    fn from(value:Failure)->Self { Self::Fatal(value) }
}
impl<S> fmt::Debug for PreflightOpenFailure<S> {
    fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result { write!(f,"<owned in-place preflight outcome>") }
}


#[derive(Clone,Copy,PartialEq,Eq)]
pub(crate) struct Observed{pub size:u64,pub modified:u32,pub mode:u32,pub uid:u32,pub gid:u32}
impl fmt::Debug for Observed{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<in-place portable attributes>")}}
impl Observed{
    pub(crate) fn parse(bytes:&[u8])->Result<Self,Failure>{
        if wire::incoming(bytes).map_err(|_|Failure::Protocol)?.kind!=ReplyKind::Attrs||bytes.len()!=37
            ||u32::from_be_bytes(bytes[5..9].try_into().map_err(|_|Failure::Protocol)?)!=15{return Err(Failure::Protocol)}
        Ok(Self{size:u64::from_be_bytes(bytes[9..17].try_into().map_err(|_|Failure::Protocol)?),
            uid:u32::from_be_bytes(bytes[17..21].try_into().map_err(|_|Failure::Protocol)?),gid:u32::from_be_bytes(bytes[21..25].try_into().map_err(|_|Failure::Protocol)?),
            mode:u32::from_be_bytes(bytes[25..29].try_into().map_err(|_|Failure::Protocol)?),modified:u32::from_be_bytes(bytes[33..37].try_into().map_err(|_|Failure::Protocol)?)})
    }
    fn regular(self)->bool{self.size<=MAX_BYTES&&self.mode&0o170000==0o100000&&self.mode&0o7000==0}
    fn same_security(self,other:Self)->bool{self.regular()&&self.uid==other.uid&&self.gid==other.gid&&self.mode==other.mode}
    fn selected(self,expected:Metadata)->bool{self.regular()&&expected.size==Some(self.size)&&expected.modified==Some(self.modified)&&expected.permissions==Some(self.mode)}
}
pub(crate) fn version(bytes:&[u8])->Result<(),Failure>{
    if wire::incoming(bytes).map_err(|_|Failure::Protocol)?.kind!=ReplyKind::Version{return Err(Failure::Protocol)}
    // incoming already bounds the complete frame to wire::MAX_PACKET; every
    // field is bounded to8192 and parsing advances through the entire list.
    let mut at=5;let mut names=HashSet::new();let mut sync=None;
    while at<bytes.len(){let name=string(bytes,&mut at,8192)?;let value=string(bytes,&mut at,8192)?;
        if !names.insert(name){return Err(Failure::Protocol)}
        if name==b"fsync@openssh.com"{sync=Some(value==b"1");}
    }
    // Unsupported is classified only after ALL pairs/duplicates validate.
    if sync!=Some(true){return Err(Failure::UnsupportedSync)}Ok(())
}
/// The exact permit vocabulary. Every step has one durable intent and one ACK;
/// source-check/readback steps are nonmutating. At most32 WRITE ranges,1MiB.
#[derive(Clone,Copy,Debug,PartialEq,Eq)]#[repr(u8)]pub(crate) enum Kind{Source=0,Write=1,Truncate=2,Sync=3,HandleReadback=4,LocationReadback=5}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]pub(crate) struct Step{pub sequence:u8,pub kind:Kind,pub offset:u64,pub count:u32}
pub(crate) fn plan(old:u64,new:u64)->Result<Vec<Step>,Failure>{
    if old>MAX_BYTES||new>MAX_BYTES{return Err(Failure::Input)}
    let mut values=vec![Step{sequence:1,kind:Kind::Source,offset:0,count:0}];
    let mut offset=0;
    while offset<new{let count=(new-offset).min(super::MAX_CHUNK as u64)as u32;
        values.push(Step{sequence:values.len()as u8+1,kind:Kind::Write,offset,count});offset+=count as u64;}
    if new<old{values.push(Step{sequence:values.len()as u8+1,kind:Kind::Truncate,offset:new,count:0});}
    for kind in [Kind::Sync,Kind::HandleReadback,Kind::LocationReadback]{values.push(Step{sequence:values.len()as u8+1,kind,offset:new,count:0});}
    Ok(values)
}
#[derive(Clone,Copy,Debug,Default,PartialEq,Eq)]pub(crate) struct Facts{pub requested:u8,pub acknowledged:u8}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]#[repr(u8)]pub(crate) enum Phase{Admission=0,Source=1,Baseline=2,Writing=3,Truncating=4,Syncing=5,HandleReadback=6,LocationReadback=7,Release=8}
#[derive(Debug,PartialEq,Eq)]pub(crate) struct Interrupted{pub cause:Failure,pub phase:Phase,pub facts:Facts}
#[derive(Debug,PartialEq,Eq)]pub(crate) struct Receipt{pub bytes:u64,pub digest:[u8;32],pub observed:Observed,pub facts:Facts}
pub(crate) trait ReadSink{
    async fn begin(&mut self,observed:Observed)->Result<(),Failure>;
    async fn chunk(&mut self,offset:u64,bytes:Vec<u8>)->Result<(),Failure>;
}
pub(crate) trait Control:Source{
    fn expected_digest(&self)->[u8;32];
    async fn permit(&mut self,step:Step,digest:[u8;32])->Result<(),Failure>;
    async fn observed(&mut self,step:Step)->Result<(),Failure>;
}
/// Private linear handle owner. It is moved out of the table before Save and
/// reinserted only after all verification. Dropping it never creates authority.
pub(crate) struct Session<S>{c:Channel<S>,handle:Vec<u8>,pub path:String,pub observed:Observed,pub digest:[u8;32]}
impl<S> fmt::Debug for Session<S>{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<retained authenticated in-place handle>")}}
fn limits_ok(limits:Limits)->Result<(),Failure>{
    super::admitted_source(0,limits)?;
    if limits.total_deadline>Duration::from_secs(120){return Err(Failure::Input)}Ok(())
}
fn path_ok(path:&str)->bool{path.starts_with('/')&&!path.ends_with('/')&&!path.contains('\0')&&path.len()<=8192
    &&path.split('/').skip(1).all(|p|!p.is_empty()&&p!="."&&p!="..")&&path.split('/').count()<=128}
async fn attrs<S:AsyncRead+AsyncWrite+Unpin>(c:&mut Channel<S>,kind:u8,value:&[u8])->Result<Observed,Failure>{
    let mut payload=Vec::new();field(&mut payload,value);
    match c.request(kind,payload,Expected::InPlaceAttributes).await?{Reply::InPlaceAttributes(value)=>Ok(value),_=>Err(Failure::Protocol)}
}
/// A READ-only current-location observation, never a write reopen. SFTPv3 has
/// no portable inode identity/CAS: identical-byte/attribute ABA is not proved.
async fn checked_location<S:AsyncRead+AsyncWrite+Unpin>(c:&mut Channel<S>,path:&str,expected:Observed,digest:[u8;32])->Result<(),Failure>{
    if attrs(c,7,path.as_bytes()).await?!=expected{return Err(Failure::Conflict)}
    let mut open=Vec::new();field(&mut open,path.as_bytes());open.extend(1u32.to_be_bytes());open.extend(0u32.to_be_bytes());
    let Reply::Handle(handle)=c.request(3,open,Expected::Handle).await?else{return Err(Failure::Protocol)};
    if attrs(c,8,&handle).await?!=expected||c.digest(&handle,expected.size).await?!=digest||attrs(c,8,&handle).await?!=expected{return Err(Failure::Conflict)}
    c.handle(4,&handle,Expected::Ok).await?;
    if attrs(c,7,path.as_bytes()).await?!=expected{return Err(Failure::Conflict)}Ok(())
}
impl<S:AsyncRead+AsyncWrite+Unpin> Session<S>{
    pub(crate) async fn open<T:ReadSink>(stream:S,path:String,expected:Metadata,mut sink:T,limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Self,Failure>{
        Self::open_checked(stream,path,expected,sink,limits,stop,false).await.map_err(|e|match e {
            PreflightOpenFailure::Fatal(value)=>value,
            PreflightOpenFailure::Rejected{reason:EditRejection::SyncUnavailable,stream:_}=>Failure::UnsupportedSync,
            PreflightOpenFailure::Rejected{reason:EditRejection::ReadWriteDenied,stream:_}=>Failure::Status(3),
        })
    }
    pub(crate) async fn open_preflight<T:ReadSink>(stream:S,path:String,expected:Metadata,sink:T,limits:Limits,
        stop:Option<Arc<AtomicBool>>)->Result<Self,PreflightOpenFailure<S>> {
        Self::open_checked(stream,path,expected,sink,limits,stop,true).await
    }
    async fn open_checked<T:ReadSink>(stream:S,path:String,expected:Metadata,mut sink:T,limits:Limits,
        stop:Option<Arc<AtomicBool>>,reject_prebody:bool)->Result<Self,PreflightOpenFailure<S>> {
        limits_ok(limits)?;if !path_ok(&path){return Err(Failure::Input.into())}
        let mut c=Channel{stream,next:1,deadline:limits.request_deadline,end:Instant::now()+limits.total_deadline,stop};
        match c.exchange(vec![1,0,0,0,3],None,Expected::InPlaceVersion).await {
            Err(Failure::UnsupportedSync) if reject_prebody=>return Err(PreflightOpenFailure::Rejected{reason:EditRejection::SyncUnavailable,stream:c.stream}),
            value=>{value?;},
        }
        let before=attrs(&mut c,7,path.as_bytes()).await?;if !before.selected(expected){return Err(Failure::Conflict.into())}
        let mut open=Vec::new();field(&mut open,path.as_bytes());
        // READ|WRITE only. No CREATE/TRUNC/APPEND and no fallback to a new name.
        open.extend(3u32.to_be_bytes());open.extend(0u32.to_be_bytes());
        let opened=match c.request(3,open,Expected::Handle).await {
            Err(Failure::Status(3)) if reject_prebody=>return Err(PreflightOpenFailure::Rejected{reason:EditRejection::ReadWriteDenied,stream:c.stream}),
            value=>value?,
        };
        let Reply::Handle(handle)=opened else{return Err(Failure::Protocol.into())};
        if attrs(&mut c,8,&handle).await?!=before{return Err(Failure::Conflict.into())}
        c.source(sink.begin(before)).await?;
        let mut offset=0;let mut hash=Sha256::new();
        loop{let count=if offset==before.size{1}else{(before.size-offset).min(super::MAX_CHUNK as u64)as usize};
            let mut payload=Vec::new();field(&mut payload,&handle);payload.extend(offset.to_be_bytes());payload.extend((count as u32).to_be_bytes());
            match c.request(5,payload,Expected::Data(count)).await?{
                Reply::Data(bytes)if offset<before.size=>{hash.update(&bytes);let amount=bytes.len()as u64;c.source(sink.chunk(offset,bytes)).await?;offset+=amount;},
                Reply::End if offset==before.size=>break,_=>return Err(Failure::Verification.into())}
        }
        let digest=hash.finalize().into();
        if attrs(&mut c,8,&handle).await?!=before{return Err(Failure::Conflict.into())}
        checked_location(&mut c,&path,before,digest).await?;
        Ok(Self{c,handle,path,observed:before,digest})
    }
    fn renew(&mut self,limits:Limits)->Result<(),Failure>{limits_ok(limits)?;self.c.deadline=limits.request_deadline;self.c.end=Instant::now()+limits.total_deadline;self.c.check()}
    pub(crate) async fn save<T:Control>(&mut self,mut source:T,limits:Limits)->Result<Receipt,Interrupted>{
        let mut phase=Phase::Admission;let mut facts=Facts::default();
        let work=async{
            self.renew(limits)?;let size=source.size();let steps=plan(self.observed.size,size)?;let mut verified=None;
            phase=Phase::Source;
            // Fetch+hash ALL edited bytes before mutation; bounded, zeroized.
            let mut bytes=Zeroizing::new(Vec::with_capacity(size as usize));let mut hash=Sha256::new();
            while (bytes.len()as u64)<size{let offset=bytes.len()as u64;let count=(size-offset).min(super::MAX_CHUNK as u64)as usize;
                let part=Zeroizing::new(self.c.source(source.next(offset,count)).await?);if part.len()!=count{return Err(Failure::SourceChanged)}hash.update(part.as_slice());bytes.extend_from_slice(&part);}
            let digest:[u8;32]=hash.finalize().into();if digest!=source.expected_digest(){return Err(Failure::SourceChanged)}
            for step in steps{
                if step.kind==Kind::Write&&facts.acknowledged==1{
                    phase=Phase::Baseline;
                    if attrs(&mut self.c,8,&self.handle).await?!=self.observed||self.c.digest(&self.handle,self.observed.size).await?!=self.digest
                        ||attrs(&mut self.c,8,&self.handle).await?!=self.observed{return Err(Failure::Conflict)}
                    checked_location(&mut self.c,&self.path,self.observed,self.digest).await?;
                }else if step.kind==Kind::Truncate&&facts.acknowledged==1||step.kind==Kind::Sync&&facts.acknowledged==1{
                    // Empty edit has no WRITE; still fresh-check before mutation.
                    phase=Phase::Baseline;
                    if attrs(&mut self.c,8,&self.handle).await?!=self.observed||self.c.digest(&self.handle,self.observed.size).await?!=self.digest{return Err(Failure::Conflict)}
                    checked_location(&mut self.c,&self.path,self.observed,self.digest).await?;
                }
                self.c.source(source.permit(step,digest)).await?;facts.requested=step.sequence;
                match step.kind{
                    Kind::Source=>{},
                    Kind::Write=>{phase=Phase::Writing;let mut payload=Vec::new();field(&mut payload,&self.handle);payload.extend(step.offset.to_be_bytes());
                        field(&mut payload,&bytes[step.offset as usize..step.offset as usize+step.count as usize]);self.c.request(6,payload,Expected::Ok).await?;},
                    Kind::Truncate=>{phase=Phase::Truncating;
                        let current=attrs(&mut self.c,8,&self.handle).await?;
                        if !current.same_security(self.observed)||current.size!=self.observed.size.max(size){return Err(Failure::Conflict)}
                        let mut payload=Vec::new();field(&mut payload,&self.handle);payload.extend(1u32.to_be_bytes());payload.extend(size.to_be_bytes());self.c.request(10,payload,Expected::Ok).await?;},
                    Kind::Sync=>{phase=Phase::Syncing;let mut payload=Vec::new();field(&mut payload,b"fsync@openssh.com");field(&mut payload,&self.handle);self.c.request(200,payload,Expected::Ok).await?;},
                    Kind::HandleReadback=>{phase=Phase::HandleReadback;let current=attrs(&mut self.c,8,&self.handle).await?;
                        if !current.same_security(self.observed)||current.size!=size||self.c.digest(&self.handle,size).await?!=digest||attrs(&mut self.c,8,&self.handle).await?!=current{return Err(Failure::Verification)}},
                    Kind::LocationReadback=>{phase=Phase::LocationReadback;let current=attrs(&mut self.c,8,&self.handle).await?;
                        if !current.same_security(self.observed)||current.size!=size||self.c.digest(&self.handle,size).await?!=digest{return Err(Failure::Verification)}
                        checked_location(&mut self.c,&self.path,current,digest).await?;
                        if attrs(&mut self.c,8,&self.handle).await?!=current{return Err(Failure::Conflict)}verified=Some(current);},
                }
                facts.acknowledged=step.sequence;self.c.source(source.observed(step)).await?;
            }
            let observed=verified.ok_or(Failure::Verification)?;
            self.observed=observed;self.digest=digest;Ok(Receipt{bytes:size,digest,observed,facts})
        }.await;
        work.map_err(|cause|Interrupted{cause,phase,facts})
    }
    /// CLOSE ACK and channel write shutdown are both required before199. An
    /// error discards this live authority and forces actual session drain.
    pub(crate) async fn release(mut self,limits:Limits)->Result<(),Failure>{
        self.renew(limits)?;self.c.handle(4,&self.handle,Expected::Ok).await?;self.c.shutdown().await
    }
}
#[cfg(test)]mod tests;
