//! Experimental generated-byte upload. No native file source, ordinary worker
//! route, deletion, overwrite extension, task, authentication or shell access.
//! This1MiB immutable-source harness qualifies wire/outcome rules first; native
//! streaming/access/durable intent remains a separate mandatory integration.
use crate::wire::{self,Metadata,ReplyKind};
#[cfg(feature="original-edit-qualification")]pub(crate) mod original;
#[cfg(feature="inplace-edit-v1")]pub(crate) mod inplace_v1;
#[cfg(feature="remote-action-qualification")]pub(crate) mod server_copy;
use sha2::{Digest,Sha256};
use std::{fmt,sync::{Arc,atomic::{AtomicBool,Ordering}},time::Duration};
use tokio::{io::{AsyncRead,AsyncReadExt,AsyncWrite,AsyncWriteExt},time::Instant};
pub const MAX_CHUNK:usize=32768;
pub const MAX_GENERATED_BYTES:usize=1024*1024;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Failure{Input,Io,Timeout,Stopped,Truncated,Protocol,Status(u32),Conflict,UnsupportedSync,Verification,SourceChanged}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Phase{Admission,Negotiation,Destination,OpeningTemporary,Writing,Readback,Permissions,Syncing,Closing,TemporaryCheck,Authorization,Publishing,FinalReadback,Shutdown,OpeningFinal}
#[derive(Debug,PartialEq,Eq)]
pub struct Interrupted{pub cause:Failure,pub phase:Phase,pub temporary_may_exist:bool,pub publication_may_have_happened:bool}
impl Interrupted{
    /// A complete, correlated negative first OPEN reply and a cleanly ended
    /// SFTP channel are the only recoverable upload refusal. A missing reply,
    /// another status, or a failed channel close retains publication doubt.
    pub fn refused_first_open(&self)->bool{
        self.cause==Failure::Status(3)&&self.phase==Phase::OpeningFinal
            &&!self.temporary_may_exist&&!self.publication_may_have_happened
    }
}
#[derive(PartialEq,Eq)]
pub struct Receipt{pub bytes:u64,pub digest:[u8;32],pub sync_acknowledged:bool,pub rename_acknowledged:bool,pub exclusive_create_acknowledged:bool,pub final_close_acknowledged:bool,pub stream_shutdown:bool}
impl fmt::Debug for Receipt{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP verified upload receipt>")}}
pub struct Target{final_path:String,temporary_path:String}
impl fmt::Debug for Target{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP fresh upload target>")}}
impl Target{
    pub fn new(directory:&str,name:&str,nonce:[u8;16])->Result<Self,Failure>{
        if !directory.starts_with('/')||directory.len()>8192||directory.contains('\0')||nonce==[0;16]
            ||directory!="/"&&(directory.ends_with('/')||directory.split('/').skip(1).any(|p|p.is_empty()||p=="."||p==".."))
            ||directory.split('/').skip(1).count()>127||name.is_empty()||name.len()>255||name=="."||name==".."||name.contains('\0')||name.contains('/'){
            return Err(Failure::Input)
        }
        let prefix=if directory=="/"{""}else{directory};
        let token=nonce.iter().map(|b|format!("{b:02X}")).collect::<String>();
        let temporary_path=format!("{prefix}/.mac-explorer-upload-{token}.part");let final_path=format!("{prefix}/{name}");
        if temporary_path.len()>8192||final_path.len()>8192||temporary_path==final_path{return Err(Failure::Input)}
        Ok(Self{final_path,temporary_path})
    }
    /// Explicit private-intent input, never automatic diagnostic formatting.
    pub fn paths_for_intent(&self)->(&str,&str){(&self.temporary_path,&self.final_path)}
}
#[derive(Clone,Copy)]pub struct Limits{pub request_deadline:Duration,pub total_deadline:Duration}
impl Default for Limits{fn default()->Self{Self{request_deadline:Duration::from_secs(30),total_deadline:Duration::from_secs(600)}}}
type Result<T,E=Failure>=std::result::Result<T,E>;
fn field(body:&mut Vec<u8>,value:&[u8]){body.extend((value.len()as u32).to_be_bytes());body.extend(value)}
fn string<'a>(bytes:&'a[u8],at:&mut usize,limit:usize)->Result<&'a[u8]>{
    let end=at.checked_add(4).ok_or(Failure::Protocol)?;
    let size=u32::from_be_bytes(bytes.get(*at..end).ok_or(Failure::Protocol)?.try_into().map_err(|_|Failure::Protocol)?)as usize;*at=end;
    if size>limit{return Err(Failure::Protocol)}
    let end=at.checked_add(size).ok_or(Failure::Protocol)?;let value=bytes.get(*at..end).ok_or(Failure::Protocol)?;*at=end;Ok(value)
}
fn version(bytes:&[u8])->Result<()>{
    if wire::incoming(bytes).map_err(|_|Failure::Protocol)?.kind!=ReplyKind::Version{return Err(Failure::Protocol)}
    let mut at=5;let mut fsync=None;
    while at<bytes.len(){
        let name=string(bytes,&mut at,8192)?;let value=string(bytes,&mut at,8192)?;
        if name==b"fsync@openssh.com"{if fsync.is_some(){return Err(Failure::Protocol)}fsync=Some(value==b"1");}
    }
    if fsync!=Some(true){return Err(Failure::UnsupportedSync)}Ok(())
}
#[derive(Clone,Copy)]enum Expected{
    #[cfg(feature="inplace-edit-v1")]InPlaceVersion,
    #[cfg(feature="inplace-edit-v1")]InPlaceAttributes,
    #[cfg(feature="remote-action-qualification")]ServerCopyVersion,
    #[cfg(feature="remote-action-qualification")]ServerCopyAttributes,
    #[cfg(feature="remote-action-qualification")]ServerCopyCanonical,
    Version,Handle,Attributes,Absent,Ok,Data(usize),Names,
    #[cfg(feature="original-edit-qualification")]EditVersion,
    #[cfg(feature="original-edit-qualification")]EditAttributes}
enum Reply{
    #[cfg(feature="inplace-edit-v1")]InPlaceAttributes(inplace_v1::Observed),
    #[cfg(feature="remote-action-qualification")]ServerCopyAttributes(server_copy::Observed),
    #[cfg(feature="remote-action-qualification")]ServerCopyCanonical(String),
    Empty,Handle(Vec<u8>),Attributes(Metadata),Data(Vec<u8>),Names(Vec<wire::Entry>),End,
    #[cfg(feature="original-edit-qualification")]EditAttributes(original::Observed)}
struct Channel<S>{stream:S,next:u32,deadline:Duration,end:Instant,stop:Option<Arc<AtomicBool>>}
impl<S:AsyncRead+AsyncWrite+Unpin> Channel<S>{
    fn check(&self)->Result<()>{
        if self.stop.as_ref().is_some_and(|v|v.load(Ordering::Acquire)){return Err(Failure::Stopped)}
        if Instant::now()>=self.end{return Err(Failure::Timeout)}Ok(())
    }
    async fn exchange(&mut self,body:Vec<u8>,id:Option<u32>,expected:Expected)->Result<Reply>{
        self.check()?;let stop=self.stop.clone();let duration=self.deadline.min(self.end.saturating_duration_since(Instant::now()));
        let work=async{
            self.stream.write_u32(body.len()as u32).await.map_err(|_|Failure::Io)?;
            self.stream.write_all(&body).await.map_err(|_|Failure::Io)?;
            let length=self.stream.read_u32().await.map_err(|e|if e.kind()==std::io::ErrorKind::UnexpectedEof{Failure::Truncated}else{Failure::Io})?;
            let length=wire::frame_length(length).map_err(|_|Failure::Protocol)?;
            if matches!(expected,Expected::Data(max)if length>max+9)&&length>16400{return Err(Failure::Protocol)}
            let mut bytes=vec![0;length];self.stream.read_exact(&mut bytes).await.map_err(|_|Failure::Truncated)?;
            #[cfg(feature="inplace-edit-v1")]
            if let Expected::InPlaceVersion=expected{inplace_v1::version(&bytes)?;return Ok(Reply::Empty)}
            #[cfg(feature="remote-action-qualification")]
            if let Expected::ServerCopyVersion=expected{
                if !wire::server_copy_capability(&bytes).map_err(|_|Failure::Protocol)? {return Err(Failure::UnsupportedSync)}
                return Ok(Reply::Empty)
            }
            if let Expected::Version=expected{version(&bytes)?;return Ok(Reply::Empty)}
            #[cfg(feature="original-edit-qualification")]
            if let Expected::EditVersion=expected{original::version(&bytes)?;return Ok(Reply::Empty)}
            if bytes[0]==103{
                let Expected::Data(max)=expected else{return Err(Failure::Protocol)};
                if bytes.len()<9||Some(u32::from_be_bytes(bytes[1..5].try_into().unwrap()))!=id{return Err(Failure::Protocol)}
                let amount=u32::from_be_bytes(bytes[5..9].try_into().unwrap())as usize;
                if amount==0||amount>max||amount.checked_add(9)!=Some(bytes.len()){return Err(Failure::Protocol)}
                return Ok(Reply::Data(bytes.split_off(9)))
            }
            let parsed=wire::incoming(&bytes).map_err(|_|Failure::Protocol)?;
            if parsed.id!=id{return Err(Failure::Protocol)}
            match(expected,parsed.kind){
                (Expected::Ok,ReplyKind::Status(0))|(Expected::Absent,ReplyKind::Status(2))=>Ok(Reply::Empty),
                (Expected::Data(_)|Expected::Names,ReplyKind::Status(1))=>Ok(Reply::End),
                (Expected::Names,ReplyKind::Names(_))=>Ok(Reply::Names(wire::decode_names(&bytes,false).map_err(|_|Failure::Protocol)?)),
                #[cfg(feature="remote-action-qualification")]
                (Expected::ServerCopyCanonical,ReplyKind::Names(1))=>{
                    let mut names=wire::decode_names(&bytes,true).map_err(|_|Failure::Protocol)?;
                    Ok(Reply::ServerCopyCanonical(names.remove(0).name))
                },
                (Expected::Absent,ReplyKind::Attrs)=>Err(Failure::Conflict),
                (Expected::Handle,ReplyKind::Handle)=>{let handle=wire::decode_handle(&bytes).map_err(|_|Failure::Protocol)?;if handle.is_empty(){Err(Failure::Protocol)}else{Ok(Reply::Handle(handle))}},
                #[cfg(feature="inplace-edit-v1")]
                (Expected::InPlaceAttributes,ReplyKind::Attrs)=>Ok(Reply::InPlaceAttributes(inplace_v1::Observed::parse(&bytes)?)),
                #[cfg(feature="remote-action-qualification")]
                (Expected::ServerCopyAttributes,ReplyKind::Attrs)=>Ok(Reply::ServerCopyAttributes(server_copy::Observed::parse(&bytes)?)),
                (Expected::Attributes,ReplyKind::Attrs)=>Ok(Reply::Attributes(wire::decode_attrs(&bytes).map_err(|_|Failure::Protocol)?)),
                #[cfg(feature="original-edit-qualification")]
                (Expected::EditAttributes,ReplyKind::Attrs)=>Ok(Reply::EditAttributes(original::Observed::parse(&bytes)?)),
                (_,ReplyKind::Status(0|1))=>Err(Failure::Protocol),(_,ReplyKind::Status(code))=>Err(Failure::Status(code)),_=>Err(Failure::Protocol)
            }
        };
        let result=tokio::select!{biased;_=wait_stop(stop)=>Err(Failure::Stopped),value=tokio::time::timeout(duration,work)=>value.map_err(|_|Failure::Timeout)?};
        self.check()?;result
    }
    async fn request(&mut self,kind:u8,payload:Vec<u8>,expected:Expected)->Result<Reply>{
        let id=self.next;self.next=self.next.checked_add(1).ok_or(Failure::Protocol)?;
        let mut body=vec![kind];body.extend(id.to_be_bytes());body.extend(payload);self.exchange(body,Some(id),expected).await
    }
    async fn source<T>(&self,operation:impl std::future::Future<Output=Result<T>>)->Result<T>{
        self.check()?;let duration=self.deadline.min(self.end.saturating_duration_since(Instant::now()));
        let result=tokio::select!{biased;_=wait_stop(self.stop.clone())=>Err(Failure::Stopped),value=tokio::time::timeout(duration,operation)=>value.map_err(|_|Failure::Timeout)?};
        self.check()?;result
    }
    async fn named(&mut self,kind:u8,name:&str,expected:Expected)->Result<Reply>{let mut value=Vec::new();field(&mut value,name.as_bytes());self.request(kind,value,expected).await}
    async fn handle(&mut self,kind:u8,handle:&[u8],expected:Expected)->Result<Reply>{let mut value=Vec::new();field(&mut value,handle);self.request(kind,value,expected).await}
    async fn shutdown(&mut self)->Result<()>{
        self.check()?;let stop=self.stop.clone();let remaining=self.deadline.min(self.end.saturating_duration_since(Instant::now()));
        tokio::select!{biased;_=wait_stop(stop)=>return Err(Failure::Stopped),value=tokio::time::timeout(remaining,self.stream.shutdown())=>value.map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Io)?};
        self.check()
    }
    async fn check_file(&mut self,kind:u8,value:&[u8],size:u64,mode:u32)->Result<()>{
        let mut body=Vec::new();field(&mut body,value);
        let Reply::Attributes(attrs)=self.request(kind,body,Expected::Attributes).await?else{return Err(Failure::Protocol)};
        if attrs.size!=Some(size)||attrs.permissions.is_none_or(|v|v&0o177777!=mode){return Err(Failure::Verification)}Ok(())
    }
    async fn digest(&mut self,handle:&[u8],size:u64)->Result<[u8;32]>{
        let mut offset=0;let mut hash=Sha256::new();
        loop{
            let maximum=if offset==size{1}else{(size-offset).min(MAX_CHUNK as u64)as usize};
            let mut body=Vec::new();field(&mut body,handle);body.extend(offset.to_be_bytes());body.extend((maximum as u32).to_be_bytes());
            match self.request(5,body,Expected::Data(maximum)).await?{
                Reply::Data(bytes)if offset<size=>{offset+=bytes.len()as u64;hash.update(&bytes)},
                Reply::End if offset==size=>return Ok(hash.finalize().into()),_=>return Err(Failure::Verification)
            }
        }
    }
}
pub(crate) async fn wait_stop(stop:Option<Arc<AtomicBool>>){let Some(stop)=stop else{std::future::pending::<()>().await;return};while !stop.load(Ordering::Acquire){tokio::time::sleep(Duration::from_millis(20)).await}}
pub(crate) fn admitted_generated(size:usize,limits:Limits)->Result<()>{
    if size>MAX_GENERATED_BYTES{return Err(Failure::Input)}admitted_source(size as u64,limits)
}
pub(crate) fn admitted_source(size:u64,limits:Limits)->Result<()>{
    if size>1<<30||limits.request_deadline.is_zero()||limits.request_deadline>Duration::from_secs(30)
        ||limits.total_deadline.is_zero()||limits.total_deadline>Duration::from_secs(1800){return Err(Failure::Input)}Ok(())
}

/// Private concrete-source seam for the generated harness and bounded worker
/// channel. It is never a public native callback or arbitrary file accessor.
pub(crate) trait Source{
    fn size(&self)->u64;
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>>;
    async fn permit_publication(&mut self,digest:[u8;32])->Result<()>;
}
struct Generated<'a>(&'a[u8]);
impl Source for Generated<'_>{
    fn size(&self)->u64{self.0.len()as u64}
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>>{
        let offset=usize::try_from(offset).map_err(|_|Failure::Input)?;
        Ok(self.0.get(offset..offset.checked_add(count).ok_or(Failure::Input)?).ok_or(Failure::SourceChanged)?.to_vec())
    }
    async fn permit_publication(&mut self,digest:[u8;32])->Result<()>{
        if <[u8;32]>::from(Sha256::digest(self.0))!=digest{return Err(Failure::SourceChanged)}Ok(())
    }
}

/// Immutable generated bytes only. Native source streaming/durable intents are
/// deliberately not represented by a speculative production-source callback.
pub async fn send_generated<S:AsyncRead+AsyncWrite+Unpin>(stream:S,target:&Target,source:&[u8],limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Receipt,Interrupted>{
    admitted_generated(source.len(),limits).map_err(|cause|Interrupted{cause,phase:Phase::Admission,temporary_may_exist:false,publication_may_have_happened:false})?;
    send_source(stream,target,Generated(source),limits,stop).await
}
// The legacy path remains only for frozen regression comparisons. Ordinary
// worker admission uses G and the exclusive path; no RENAME fallback is safe.
#[derive(Clone,Copy,PartialEq,Eq)]enum Publication{LegacyStagedRename,ExclusiveFinal}
pub(crate) async fn send_source<S:AsyncRead+AsyncWrite+Unpin,T:Source>(stream:S,target:&Target,source:T,limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Receipt,Interrupted>{
    send_with_publication(stream,target,source,limits,stop,Publication::LegacyStagedRename).await
}
pub(crate) async fn send_source_exclusive<S:AsyncRead+AsyncWrite+Unpin,T:Source>(stream:S,target:&Target,source:T,limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Receipt,Interrupted>{
    // The owner must durably mark creation intent BEFORE supplying this stream.
    send_with_publication(stream,target,source,limits,stop,Publication::ExclusiveFinal).await
}
async fn transfer_on_channel<S:AsyncRead+AsyncWrite+Unpin,T:Source>(channel:&mut Channel<S>,target:&Target,mut source:T,publication:Publication,
    phase:&mut Phase,temporary:&mut bool,publishing:&mut bool)->Result<Receipt>{
    let size=source.size();let mut hash=Sha256::new();
        *phase=Phase::Destination;channel.named(7,&target.final_path,Expected::Absent).await?;
        let exclusive=publication==Publication::ExclusiveFinal;
        let opened_path=if exclusive{*phase=Phase::OpeningFinal;*publishing=true;&target.final_path}
            else{*phase=Phase::OpeningTemporary;*temporary=true;&target.temporary_path};
        // READ|WRITE|CREATE|EXCL. Never TRUNCATE. Conservatively record possible
        // final creation before sending OPEN, including a lost HANDLE reply.
        let mut body=Vec::new();field(&mut body,opened_path.as_bytes());body.extend(0x2bu32.to_be_bytes());body.extend(4u32.to_be_bytes());body.extend(0o600u32.to_be_bytes());
        let opened=channel.request(3,body,Expected::Handle).await;
        if exclusive&&opened.as_ref().err()==Some(&Failure::Status(3)){
            // STATUS(3) is a complete, request-matched refusal from OPEN. Do
            // not clear the conservative publication flag until this channel
            // has also shut down without a timeout, stop, or transport error.
            channel.shutdown().await?;
            *publishing=false;
            return Err(Failure::Status(3))
        }
        let Reply::Handle(handle)=opened? else{return Err(Failure::Protocol)};
        *phase=Phase::Writing;
        let mut offset=0;
        while offset<size{
            let count=(size-offset).min(MAX_CHUNK as u64)as usize;
            let bytes=channel.source(source.next(offset,count)).await?;
            if bytes.len()!=count{return Err(Failure::SourceChanged)}hash.update(&bytes);
            let mut body=Vec::new();field(&mut body,&handle);body.extend(offset.to_be_bytes());field(&mut body,&bytes);
            channel.request(6,body,Expected::Ok).await?;
            offset+=bytes.len()as u64;
        }
        let digest:[u8;32]=hash.finalize().into();
        *phase=Phase::Readback;channel.check_file(8,&handle,size,0o100600).await?;
        if channel.digest(&handle,size).await?!=digest{return Err(Failure::Verification)}
        channel.check_file(8,&handle,size,0o100600).await?;
        *phase=Phase::Permissions;
        let mut mode=Vec::new();field(&mut mode,&handle);mode.extend(4u32.to_be_bytes());mode.extend(0o644u32.to_be_bytes());channel.request(10,mode,Expected::Ok).await?;
        channel.check_file(8,&handle,size,0o100644).await?;
        *phase=Phase::Syncing;
        let mut sync=Vec::new();field(&mut sync,b"fsync@openssh.com");field(&mut sync,&handle);channel.request(200,sync,Expected::Ok).await?;
        *phase=Phase::Closing;channel.handle(4,&handle,Expected::Ok).await?;
        if !exclusive{
            *phase=Phase::TemporaryCheck;channel.check_file(7,target.temporary_path.as_bytes(),size,0o100644).await?;
            channel.named(7,&target.final_path,Expected::Absent).await?;
        }
        *phase=Phase::Authorization;channel.source(source.permit_publication(digest)).await?;
        if !exclusive{
            *phase=Phase::Publishing;*publishing=true;
            let mut rename=Vec::new();field(&mut rename,target.temporary_path.as_bytes());field(&mut rename,target.final_path.as_bytes());channel.request(18,rename,Expected::Ok).await?;
        }
        *phase=Phase::FinalReadback;channel.check_file(7,target.final_path.as_bytes(),size,0o100644).await?;
        let mut open=Vec::new();field(&mut open,target.final_path.as_bytes());open.extend(1u32.to_be_bytes());open.extend(0u32.to_be_bytes());
        let Reply::Handle(final_handle)=channel.request(3,open,Expected::Handle).await?else{return Err(Failure::Protocol)};
        channel.check_file(8,&final_handle,size,0o100644).await?;
        if channel.digest(&final_handle,size).await?!=digest{return Err(Failure::Verification)}
        channel.check_file(8,&final_handle,size,0o100644).await?;
        channel.check_file(7,target.final_path.as_bytes(),size,0o100644).await?;
        channel.handle(4,&final_handle,Expected::Ok).await?;
    Ok(Receipt{bytes:size,digest,sync_acknowledged:true,rename_acknowledged:!exclusive,exclusive_create_acknowledged:exclusive,final_close_acknowledged:true,stream_shutdown:false})
}
async fn send_with_publication<S:AsyncRead+AsyncWrite+Unpin,T:Source>(stream:S,target:&Target,source:T,limits:Limits,stop:Option<Arc<AtomicBool>>,publication:Publication)->Result<Receipt,Interrupted>{
    let mut phase=Phase::Admission;let mut temporary=false;let mut publishing=false;
    let result=async{
        admitted_source(source.size(),limits)?;
        let mut channel=Channel{stream,next:1,deadline:limits.request_deadline,end:Instant::now()+limits.total_deadline,stop};
        phase=Phase::Negotiation;channel.exchange(vec![1,0,0,0,3],None,Expected::Version).await?;
        let receipt=transfer_on_channel(&mut channel,target,source,publication,&mut phase,&mut temporary,&mut publishing).await?;
        phase=Phase::Shutdown;channel.shutdown().await?;
        Ok(Receipt{stream_shutdown:true,..receipt})
    }.await;
    result.map_err(|cause|Interrupted{cause,phase,temporary_may_exist:temporary,publication_may_have_happened:publishing})
}

/// One negotiated SFTP stream owned by H. G uses the same concrete file kernel,
/// preserving its wire ordering and proof, while H closes the stream once after
/// the full tree. No authentication, shell, deletion or overwrite authority.
pub(crate) struct TreeWriter<S>{channel:Channel<S>}
impl<S:AsyncRead+AsyncWrite+Unpin> TreeWriter<S>{
    pub(crate) async fn new(stream:S,limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Self>{
        admitted_source(0,limits)?;
        let mut channel=Channel{stream,next:1,deadline:limits.request_deadline,end:Instant::now()+limits.total_deadline,stop};
        channel.exchange(vec![1,0,0,0,3],None,Expected::Version).await?;Ok(Self{channel})
    }
    pub(crate) async fn create_directory(&mut self,path:&str,creation_sent:&mut bool)->Result<()>{
        self.channel.named(7,path,Expected::Absent).await?;
        let mut value=Vec::new();field(&mut value,path.as_bytes());value.extend(4u32.to_be_bytes());value.extend(0o755u32.to_be_bytes());
        *creation_sent=true;self.channel.request(14,value,Expected::Ok).await?;
        self.check_directory(path).await
    }
    pub(crate) async fn check_directory(&mut self,path:&str)->Result<()>{
        let Reply::Attributes(attrs)=self.channel.named(7,path,Expected::Attributes).await?else{return Err(Failure::Protocol)};
        if attrs.permissions.is_none_or(|v|v&0o177777!=0o040755){return Err(Failure::Verification)}Ok(())
    }
    pub(crate) async fn file<T:Source>(&mut self,target:&Target,source:T)->Result<Receipt,Interrupted>{
        let(mut phase,mut temporary,mut publishing)=(Phase::Admission,false,false);
        transfer_on_channel(&mut self.channel,target,source,Publication::ExclusiveFinal,&mut phase,&mut temporary,&mut publishing).await
            .map_err(|cause|Interrupted{cause,phase,temporary_may_exist:temporary,publication_may_have_happened:publishing})
    }
    pub(crate) async fn verify_file(&mut self,path:&str,size:u64,digest:[u8;32])->Result<()>{
        self.channel.check_file(7,path.as_bytes(),size,0o100644).await?;
        let mut value=Vec::new();field(&mut value,path.as_bytes());value.extend(1u32.to_be_bytes());value.extend(0u32.to_be_bytes());
        let Reply::Handle(handle)=self.channel.request(3,value,Expected::Handle).await?else{return Err(Failure::Protocol)};
        self.channel.check_file(8,&handle,size,0o100644).await?;
        if self.channel.digest(&handle,size).await?!=digest{return Err(Failure::Verification)}
        self.channel.check_file(8,&handle,size,0o100644).await?;
        self.channel.check_file(7,path.as_bytes(),size,0o100644).await?;
        self.channel.handle(4,&handle,Expected::Ok).await?;Ok(())
    }
    pub(crate) async fn entries(&mut self,path:&str)->Result<Vec<wire::Entry>>{
        self.check_directory(path).await?;
        let Reply::Handle(handle)=self.channel.named(11,path,Expected::Handle).await?else{return Err(Failure::Protocol)};
        let mut entries=Vec::new();let mut names=std::collections::HashSet::new();let mut ended=false;
        for _ in 0..=2048{
            match self.channel.handle(12,&handle,Expected::Names).await?{
                Reply::Names(values)=>{
                    if entries.len()+values.len()>2048{return Err(Failure::Verification)}
                    for value in values{if !names.insert(value.name.clone()){return Err(Failure::Protocol)}entries.push(value)}
                },
                Reply::End=>{ended=true;break},_=>return Err(Failure::Protocol),
            }
        }
        if !ended{return Err(Failure::Verification)}
        self.channel.handle(4,&handle,Expected::Ok).await?;self.check_directory(path).await?;
        entries.sort_by(|a,b|a.name.as_bytes().cmp(b.name.as_bytes()));Ok(entries)
    }
    pub(crate) async fn finish(&mut self)->Result<()>{self.channel.shutdown().await}
    pub(crate) async fn source<T>(&self,operation:impl std::future::Future<Output=Result<T>>)->Result<T>{self.channel.source(operation).await}
}
#[cfg(test)]mod tests;
