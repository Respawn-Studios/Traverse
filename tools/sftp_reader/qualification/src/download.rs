//! Explicit one-file body transfer, isolated from the metadata reader.
//! No caller-supplied packet/opcode, file write, shell, task or authentication.
use crate::wire::{self,Metadata,ReplyKind};
use std::{future::Future,time::Duration,sync::{Arc,atomic::{AtomicBool,Ordering}}};
use tokio::io::{AsyncRead,AsyncReadExt,AsyncWrite,AsyncWriteExt};

pub const MAX_CHUNK:usize=32*1024;
pub const MAX_OBJECT:u64=1024*1024*1024;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Failure{Input,Io,Timeout,Truncated,Protocol,Status(u32),Changed,Sink,Stopped}
type Result<T>=std::result::Result<T,Failure>;
#[derive(Clone,Copy)]
pub struct Limits{pub maximum_bytes:u64,pub request_deadline:Duration,pub total_deadline:Duration}
impl Default for Limits{
    fn default()->Self{Self{maximum_bytes:MAX_OBJECT,request_deadline:Duration::from_secs(30),total_deadline:Duration::from_secs(600)}}
}
#[derive(Debug,PartialEq,Eq)]
pub struct Receipt{pub bytes:u64,pub observed:Metadata,pub close_acknowledged:bool,pub stream_shutdown:bool}
pub trait Sink{
    fn consume(&mut self,offset:u64,bytes:Vec<u8>)->impl Future<Output=std::result::Result<(),()>>;
    /// A bounded progress opportunity after metadata/handle observations. It
    /// grants no body authority and legacy sinks intentionally do nothing.
    fn checkpoint(&mut self)->impl Future<Output=std::result::Result<(),()>>{async{Ok(())}}
}
impl<F,Fut> Sink for F where F:FnMut(u64,Vec<u8>)->Fut,Fut:Future<Output=std::result::Result<(),()>>{
    async fn consume(&mut self,offset:u64,bytes:Vec<u8>)->std::result::Result<(),()>{self(offset,bytes).await}
}

pub(crate) fn admitted(path:&str,expected:Metadata,limits:Limits)->Result<u64>{
    if !path.starts_with('/')||path.len()>8192||path.contains('\0')||path.split('/').skip(1).count()>128
        ||path.split('/').skip(1).any(|p|p.is_empty()||p=="."||p==".."){
        return Err(Failure::Input)
    }
    let size=expected.size.ok_or(Failure::Input)?;
    if expected.modified.is_none()||expected.permissions.is_none_or(|m|m&0o170000!=0o100000)
        ||limits.maximum_bytes==0||limits.maximum_bytes>MAX_OBJECT||size>limits.maximum_bytes
        ||limits.request_deadline.is_zero()||limits.request_deadline>Duration::from_secs(30)
        ||limits.total_deadline.is_zero()||limits.total_deadline>Duration::from_secs(1800){return Err(Failure::Input)}
    Ok(size)
}
fn field(bytes:&mut Vec<u8>,value:&[u8]){bytes.extend((value.len()as u32).to_be_bytes());bytes.extend(value);}
#[derive(Clone,Copy)]enum Expected{Version,Handle,Attributes,Close,Data(usize)}
enum Reply{Version,Handle(Vec<u8>),Attributes(Metadata),Close,Data(Vec<u8>),End}
pub(crate) async fn wait_for_stop(stop:Option<Arc<AtomicBool>>){
    let Some(stop)=stop else{std::future::pending::<()>().await;return};
    while !stop.load(Ordering::Acquire){tokio::time::sleep(Duration::from_millis(20)).await;}
}
fn check_stop(stop:&Option<Arc<AtomicBool>>)->Result<()>{if stop.as_ref().is_some_and(|s|s.load(Ordering::Acquire)){Err(Failure::Stopped)}else{Ok(())}}
pub(crate) async fn notify_checkpoint<T:Sink>(sink:&mut T,stop:&Option<Arc<AtomicBool>>,deadline:Duration)->Result<()>{
    check_stop(stop)?;
    // Like body frames, an admitted bounded parent frame drains before Stop;
    // cancellation must not leave a partial private IPC frame reusable.
    tokio::time::timeout(deadline,sink.checkpoint()).await.map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Sink)?;
    check_stop(stop)
}
struct Channel<S>{stream:S,next_id:u32,deadline:Duration,stop:Option<Arc<AtomicBool>>}
impl<S:AsyncRead+AsyncWrite+Unpin> Channel<S>{
    async fn exchange(&mut self,body:Vec<u8>,id:Option<u32>,expected:Expected)->Result<Reply>{
        check_stop(&self.stop)?;let stop=self.stop.clone();let deadline=self.deadline;
        let operation=async{
            self.stream.write_u32(body.len()as u32).await.map_err(|_|Failure::Io)?;
            self.stream.write_all(&body).await.map_err(|_|Failure::Io)?;
            let length=self.stream.read_u32().await.map_err(|e|if e.kind()==std::io::ErrorKind::UnexpectedEof{Failure::Truncated}else{Failure::Io})?;
            let length=wire::frame_length(length).map_err(|_|Failure::Protocol)?;
            // DATA is bounded by this one request, before allocation. Other
            // replies retain the strict metadata parser's overall256KiB bound.
            if matches!(expected,Expected::Data(max)if length>max+9)&&length>8192*2+13{return Err(Failure::Protocol)}
            let mut reply=vec![0u8;length];
            self.stream.read_exact(&mut reply).await.map_err(|e|if e.kind()==std::io::ErrorKind::UnexpectedEof{Failure::Truncated}else{Failure::Io})?;
            if reply[0]==103{
                let Expected::Data(max)=expected else{return Err(Failure::Protocol)};
                if reply.len()<9||Some(u32::from_be_bytes(reply[1..5].try_into().unwrap()))!=id{return Err(Failure::Protocol)}
                let size=u32::from_be_bytes(reply[5..9].try_into().unwrap())as usize;
                if size==0||size>max||size.checked_add(9)!=Some(reply.len()){return Err(Failure::Protocol)}
                return Ok(Reply::Data(reply.split_off(9)))
            }
            let parsed=wire::incoming(&reply).map_err(|_|Failure::Protocol)?;
            if parsed.id!=id{return Err(Failure::Protocol)}
            if let ReplyKind::Status(code)=parsed.kind{
                return match(expected,code){(Expected::Close,0)=>Ok(Reply::Close),(Expected::Data(_),1)=>Ok(Reply::End),
                    (_,0|1)=>Err(Failure::Protocol),_=>Err(Failure::Status(code))}
            }
            match(expected,parsed.kind){
                (Expected::Version,ReplyKind::Version)=>Ok(Reply::Version),
                (Expected::Handle,ReplyKind::Handle)=>{
                    let value=wire::decode_handle(&reply).map_err(|_|Failure::Protocol)?;
                    if value.is_empty(){return Err(Failure::Protocol)}Ok(Reply::Handle(value))
                },
                (Expected::Attributes,ReplyKind::Attrs)=>Ok(Reply::Attributes(wire::decode_attrs(&reply).map_err(|_|Failure::Protocol)?)),
                _=>Err(Failure::Protocol),
            }
        };
        tokio::select!{biased;_=wait_for_stop(stop)=>Err(Failure::Stopped),result=tokio::time::timeout(deadline,operation)=>result.map_err(|_|Failure::Timeout)?}
    }
    async fn request(&mut self,kind:u8,payload:Vec<u8>,expected:Expected)->Result<Reply>{
        // Only private construction sites can choose these exact operations.
        if ![3,4,5,7,8].contains(&kind)||payload.len()>8192+16{return Err(Failure::Input)}
        let id=self.next_id;self.next_id=id.checked_add(1).ok_or(Failure::Input)?;
        let mut body=vec![kind];body.extend(id.to_be_bytes());body.extend(payload);
        self.exchange(body,Some(id),expected).await
    }
    async fn attributes(&mut self,kind:u8,value:&[u8],expected:Metadata)->Result<()>{
        let mut payload=Vec::new();field(&mut payload,value);
        let Reply::Attributes(found)=self.request(kind,payload,Expected::Attributes).await?else{return Err(Failure::Protocol)};
        if found!=expected{return Err(Failure::Changed)}Ok(())
    }
    async fn read(&mut self,handle:&[u8],offset:u64,size:usize)->Result<Option<Vec<u8>>>{
        if size==0||size>MAX_CHUNK{return Err(Failure::Input)}
        let mut payload=Vec::new();field(&mut payload,handle);payload.extend(offset.to_be_bytes());payload.extend((size as u32).to_be_bytes());
        match self.request(5,payload,Expected::Data(size)).await?{Reply::Data(bytes)=>Ok(Some(bytes)),Reply::End=>Ok(None),_=>Err(Failure::Protocol)}
    }
}

/// Consumes the channel. Cancellation, sink errors and every uncertain reply
/// drop it; a partially consumed frame is never returned for reuse. The sink is
/// awaited serially under the same deadline and receives only bounded chunks.
/// This checks available attributes, not an immutable remote snapshot.
pub async fn receive<S,T>(stream:S,path:&str,expected:Metadata,limits:Limits,sink:T)->Result<Receipt>
where S:AsyncRead+AsyncWrite+Unpin,T:Sink{
    receive_controlled(stream,path,expected,limits,None,sink).await
}
pub async fn receive_controlled<S,T>(stream:S,path:&str,expected:Metadata,limits:Limits,stop:Option<Arc<AtomicBool>>,mut sink:T)->Result<Receipt>
where S:AsyncRead+AsyncWrite+Unpin,T:Sink{
    let size=admitted(path,expected,limits)?;
    let operation=async{
        let mut channel=Channel{stream,next_id:1,deadline:limits.request_deadline,stop:stop.clone()};
        channel.exchange(vec![1,0,0,0,3],None,Expected::Version).await?;
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        channel.attributes(7,path.as_bytes(),expected).await?;
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        let mut open=Vec::new();field(&mut open,path.as_bytes());open.extend(1u32.to_be_bytes());open.extend(0u32.to_be_bytes());
        let Reply::Handle(handle)=channel.request(3,open,Expected::Handle).await?else{return Err(Failure::Protocol)};
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        channel.attributes(8,&handle,expected).await?;
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        let mut received=0;
        while received<size{
            let amount=(size-received).min(MAX_CHUNK as u64)as usize;
            let bytes=channel.read(&handle,received,amount).await?.ok_or(Failure::Changed)?;
            let count=bytes.len()as u64;
            check_stop(&stop)?;
            // Stop may interrupt network IO, but does not drop a parent IPC
            // sink halfway through its bounded frame. Drain that frame first.
            tokio::time::timeout(limits.request_deadline,sink.consume(received,bytes)).await.map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Sink)?;
            check_stop(&stop)?;
            received=received.checked_add(count).ok_or(Failure::Protocol)?;
        }
        if channel.read(&handle,size,1).await?.is_some(){return Err(Failure::Changed)}
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        channel.attributes(8,&handle,expected).await?;
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        channel.attributes(7,path.as_bytes(),expected).await?;
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        let mut close=Vec::new();field(&mut close,&handle);channel.request(4,close,Expected::Close).await?;
        notify_checkpoint(&mut sink,&stop,limits.request_deadline).await?;
        tokio::time::timeout(limits.request_deadline,channel.stream.shutdown()).await.map_err(|_|Failure::Timeout)?.map_err(|_|Failure::Io)?;
        Ok(Receipt{bytes:received,observed:expected,close_acknowledged:true,stream_shutdown:true})
    };
    tokio::time::timeout(limits.total_deadline,operation).await.map_err(|_|Failure::Timeout)?
}

#[cfg(test)]mod tests;
