//! Conditional same-session regular-file Copy. The only publication request
//! is OpenSSH hardlink v1, whose new name is created without replacement.
//! No local relay, ordinary rename, source deletion, or automatic retry.
//! The result proves correlated server acknowledgements and observed size,
//! ordinary mode, and mtime. No file-body READ is sent to the Mac; byte equality,
//! hidden ACL/xattr preservation, and same-metadata source races are unproved.
use super::{Channel,Expected,Failure,Limits,Reply,field};
use crate::wire::{self,Metadata,ReplyKind};
use std::{fmt,sync::{Arc,atomic::AtomicBool}};
use tokio::{io::{AsyncRead,AsyncWrite},time::Instant};

const RANGE:u64=4<<20;
const MAX_BYTES:u64=64<<30;
const MAX_RANGES:u64=16_384;

#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub(crate) struct Observed {
    pub size:u64,pub uid:u32,pub gid:u32,pub mode:u32,pub atime:u32,pub mtime:u32,
}
impl Observed {
    pub(crate) fn parse(bytes:&[u8])->Result<Self,Failure>{
        if wire::incoming(bytes).map_err(|_|Failure::Protocol)?.kind!=ReplyKind::Attrs
            ||bytes.len()!=37||bytes.get(5..9)!=Some(&15u32.to_be_bytes()) {return Err(Failure::Protocol)}
        let number=|at|->Result<u32,Failure>{Ok(u32::from_be_bytes(bytes.get(at..at+4).ok_or(Failure::Protocol)?
            .try_into().map_err(|_|Failure::Protocol)?))};
        Ok(Self{size:u64::from_be_bytes(bytes[9..17].try_into().map_err(|_|Failure::Protocol)?),
            uid:number(17)?,gid:number(21)?,mode:number(25)?,atime:number(29)?,mtime:number(33)?})
    }
    fn ordinary(self)->bool{self.size<=MAX_BYTES&&self.mode&0o170000==0o100000&&self.mode&0o7000==0}
    fn selected(self,expected:Metadata)->bool{
        self.ordinary()&&expected.size==Some(self.size)&&expected.modified==Some(self.mtime)
            &&expected.permissions==Some(self.mode)
    }
    fn same_file(self,other:Self)->bool{
        self.size==other.size&&self.uid==other.uid&&self.gid==other.gid
            &&self.mode==other.mode&&self.mtime==other.mtime
    }
    fn copied(self,source:Self)->bool{
        self.size==source.size&&self.mode==source.mode&&self.mtime==source.mtime
    }
}

pub(crate) struct Target{source:String,final_path:String,stage:String}
impl fmt::Debug for Target{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP server-copy target>")}}
impl Target{
    pub(crate) fn new(source:&str,final_path:&str,request:[u8;16])->Result<Self,Failure>{
        let valid=|path:&str|path.starts_with('/')&&path.len()<=8192&&!path.ends_with('/')
            &&!path.contains('\0')&&path.split('/').skip(1).all(|part|!part.is_empty()&&part!="."&&part!="..");
        if !valid(source)||!valid(final_path)||source==final_path||request==[0;16]{return Err(Failure::Input)}
        let parent=final_path.rsplit_once('/').ok_or(Failure::Input)?.0;
        let token=request.iter().map(|byte|format!("{byte:02X}")).collect::<String>();
        let stage=format!("{parent}/.mac-explorer-copy-{token}.part");
        if !valid(&stage)||stage==source||stage==final_path{return Err(Failure::Input)}
        Ok(Self{source:source.to_owned(),final_path:final_path.to_owned(),stage})
    }
    pub(crate) fn stage_path(&self)->&str{&self.stage}
}

#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub(crate) enum Phase{Admission,Negotiation,Source,Destination,OpeningStage,Copying,VerifyingStage,
    Metadata,Syncing,Closing,Publishing,VerifyingFinal,RemovingStage,Shutdown}
#[derive(Debug,PartialEq,Eq)]
pub(crate) struct Interrupted{pub cause:Failure,pub phase:Phase,pub stage_may_exist:bool,
    pub publication_may_have_happened:bool}
#[derive(Debug,PartialEq,Eq)]
pub(crate) struct Receipt{pub bytes:u64}

fn admit(size:u64,limits:Limits)->Result<(),Failure>{
    if size>MAX_BYTES||(size.saturating_add(RANGE-1)/RANGE)>MAX_RANGES
        ||limits.request_deadline.is_zero()||limits.request_deadline>std::time::Duration::from_secs(30)
        ||limits.total_deadline.is_zero()||limits.total_deadline>std::time::Duration::from_secs(600){Err(Failure::Input)}
    else{Ok(())}
}

async fn attrs<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,kind:u8,value:&[u8])->Result<Observed,Failure>{
    let mut payload=Vec::new();field(&mut payload,value);
    match channel.request(kind,payload,Expected::ServerCopyAttributes).await?{
        Reply::ServerCopyAttributes(value)=>Ok(value),_=>Err(Failure::Protocol)
    }
}
async fn absent<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,path:&str)->Result<(),Failure>{
    channel.named(7,path,Expected::Absent).await.map(|_|())
}
async fn canonical_parent<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,path:&str)->Result<(),Failure>{
    let parent=path.rsplit_once('/').ok_or(Failure::Input)?.0;
    let parent=if parent.is_empty(){"/"}else{parent};
    match channel.named(16,parent,Expected::ServerCopyCanonical).await?{
        Reply::ServerCopyCanonical(actual) if actual==parent=>{},_=>return Err(Failure::SourceChanged),
    }
    let observed=attrs(channel,7,parent.as_bytes()).await?;
    if observed.mode&0o170000!=0o040000{return Err(Failure::SourceChanged)}
    Ok(())
}
async fn open<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,path:&str,flags:u32,mode:u32)->Result<Vec<u8>,Failure>{
    let mut payload=Vec::new();field(&mut payload,path.as_bytes());payload.extend(flags.to_be_bytes());
    if flags&8!=0{payload.extend(4u32.to_be_bytes());payload.extend(mode.to_be_bytes());}
    else{payload.extend(0u32.to_be_bytes());}
    match channel.request(3,payload,Expected::Handle).await?{Reply::Handle(handle)=>Ok(handle),_=>Err(Failure::Protocol)}
}
async fn checked_path<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,path:&str,
    expected:Observed,source:bool)->Result<(),Failure>{
    let actual=attrs(channel,7,path.as_bytes()).await?;
    if (source&&actual.same_file(expected))||(!source&&actual.copied(expected)){Ok(())}
    else{Err(Failure::SourceChanged)}
}
async fn extension<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,name:&[u8],payload:&[u8])->Result<(),Failure>{
    let mut request=Vec::new();field(&mut request,name);request.extend(payload);
    channel.request(200,request,Expected::Ok).await.map(|_|())
}
async fn copy_on_channel<S:AsyncRead+AsyncWrite+Unpin>(channel:&mut Channel<S>,target:&Target,selected:Metadata,
    phase:&mut Phase,stage_may_exist:&mut bool,publication_may_have_happened:&mut bool)->Result<Receipt,Failure>{
    *phase=Phase::Negotiation;channel.exchange(vec![1,0,0,0,3],None,Expected::ServerCopyVersion).await?;
    *phase=Phase::Source;
    canonical_parent(channel,&target.source).await?;
    let before=attrs(channel,7,target.source.as_bytes()).await?;
    if !before.selected(selected){return Err(Failure::SourceChanged)}
    let source=open(channel,&target.source,1,0).await?;
    if !attrs(channel,8,&source).await?.same_file(before){return Err(Failure::SourceChanged)}
    *phase=Phase::Destination;
    canonical_parent(channel,&target.final_path).await?;
    absent(channel,&target.final_path).await?;absent(channel,&target.stage).await?;
    // OPEN may have created the stage even when its HANDLE reply is lost.
    *phase=Phase::OpeningStage;*stage_may_exist=true;
    let stage=open(channel,&target.stage,0x2a,0o600).await?;
    *phase=Phase::Copying;
    let mut offset=0;
    while offset<before.size{
        let amount=(before.size-offset).min(RANGE);
        let mut payload=Vec::new();field(&mut payload,&source);payload.extend(offset.to_be_bytes());
        payload.extend(amount.to_be_bytes());field(&mut payload,&stage);payload.extend(offset.to_be_bytes());
        extension(channel,b"copy-data",&payload).await?;
        offset+=amount;
    }
    *phase=Phase::VerifyingStage;
    let staged=attrs(channel,8,&stage).await?;
    if staged.size!=before.size||staged.mode&0o170000!=0o100000{return Err(Failure::Verification)}
    *phase=Phase::Metadata;
    let mut payload=Vec::new();field(&mut payload,&stage);payload.extend(12u32.to_be_bytes());
    payload.extend((before.mode&0o777).to_be_bytes());payload.extend(before.atime.to_be_bytes());
    payload.extend(before.mtime.to_be_bytes());channel.request(10,payload,Expected::Ok).await?;
    let staged=attrs(channel,8,&stage).await?;
    if !staged.copied(before){return Err(Failure::Verification)}
    *phase=Phase::Syncing;
    let mut payload=Vec::new();field(&mut payload,&stage);extension(channel,b"fsync@openssh.com",&payload).await?;
    *phase=Phase::Closing;
    channel.handle(4,&stage,Expected::Ok).await?;
    if !attrs(channel,8,&source).await?.same_file(before){return Err(Failure::SourceChanged)}
    channel.handle(4,&source,Expected::Ok).await?;
    checked_path(channel,&target.source,before,true).await?;
    checked_path(channel,&target.stage,before,false).await?;
    canonical_parent(channel,&target.source).await?;
    canonical_parent(channel,&target.final_path).await?;
    absent(channel,&target.final_path).await?;
    // The OpenSSH v1 extension invokes link(old,new), creating a distinct name
    // only if the destination is absent. No standard or posix rename is sent.
    *phase=Phase::Publishing;*publication_may_have_happened=true;
    let mut payload=Vec::new();field(&mut payload,target.stage.as_bytes());field(&mut payload,target.final_path.as_bytes());
    extension(channel,b"hardlink@openssh.com",&payload).await?;
    *phase=Phase::VerifyingFinal;
    checked_path(channel,&target.final_path,before,false).await?;
    checked_path(channel,&target.source,before,true).await?;
    checked_path(channel,&target.stage,before,false).await?;
    *phase=Phase::RemovingStage;
    channel.named(13,&target.stage,Expected::Ok).await?;
    absent(channel,&target.stage).await?;
    checked_path(channel,&target.final_path,before,false).await?;
    checked_path(channel,&target.source,before,true).await?;
    *phase=Phase::Shutdown;channel.shutdown().await?;
    Ok(Receipt{bytes:before.size})
}

pub(crate) async fn send<S:AsyncRead+AsyncWrite+Unpin>(stream:S,target:&Target,selected:Metadata,
    limits:Limits,stop:Option<Arc<AtomicBool>>)->Result<Receipt,Interrupted>{
    let mut phase=Phase::Admission;let mut stage_may_exist=false;let mut publication_may_have_happened=false;
    let size=selected.size.unwrap_or(u64::MAX);
    if let Err(cause)=admit(size,limits){return Err(Interrupted{cause,phase,stage_may_exist,publication_may_have_happened})}
    let mut channel=Channel{stream,next:1,deadline:limits.request_deadline,end:Instant::now()+limits.total_deadline,stop};
    let result=copy_on_channel(&mut channel,target,selected,&mut phase,&mut stage_may_exist,&mut publication_may_have_happened).await;
    result.map_err(|cause|Interrupted{cause,phase,stage_may_exist,publication_may_have_happened})
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt,AsyncWriteExt,DuplexStream};
    #[test]fn exact_64_gib_uses_16384_ranges_and_rejects_larger_input(){
        assert_eq!(MAX_BYTES/RANGE,MAX_RANGES);
        assert_eq!(admit(MAX_BYTES,Limits::default()),Ok(()));
        assert_eq!(admit(MAX_BYTES+1,Limits::default()),Err(Failure::Input));
        assert_eq!(admit(0,Limits::default()),Ok(()));
        let slow=Limits{request_deadline:std::time::Duration::from_secs(31),..Limits::default()};
        assert_eq!(admit(1,slow),Err(Failure::Input));
    }
    struct Peer{source:Vec<u8>,stage:Vec<u8>,stage_exists:bool,final_exists:bool,
        mode:u32,mtime:u32,copy_calls:usize,lost_link_reply:bool,
        lost_stage_open_reply:bool,pause_copy:bool,race_final_on_link:bool}
    impl Peer {
        fn new(source:&[u8])->Self{Self{source:source.to_vec(),stage:Vec::new(),stage_exists:false,
            final_exists:false,mode:0o100600,mtime:1,copy_calls:0,lost_link_reply:false,
            lost_stage_open_reply:false,pause_copy:false,race_final_on_link:false}}
        fn attrs(&self,path:&[u8])->Option<Vec<u8>>{
            let (size,mode,mtime)=match path{
                b"/src/file"=>(self.source.len() as u64,0o100751,4),
                b"/dst/final" if self.final_exists=>(self.stage.len() as u64,self.mode,self.mtime),
                _ if path.starts_with(b"/dst/.mac-explorer-copy-")&&self.stage_exists=>(self.stage.len() as u64,self.mode,self.mtime),
                _=>return None,
            };
            let mut out=vec![105];out.extend(0u32.to_be_bytes());out.extend(15u32.to_be_bytes());
            out.extend(size.to_be_bytes());out.extend(1u32.to_be_bytes());out.extend(2u32.to_be_bytes());
            out.extend(mode.to_be_bytes());out.extend(3u32.to_be_bytes());out.extend(mtime.to_be_bytes());Some(out)
        }
    }
    fn field_at<'a>(bytes:&'a[u8],at:&mut usize)->&'a[u8]{
        let len=u32::from_be_bytes(bytes[*at..*at+4].try_into().unwrap())as usize;*at+=4;
        let field=&bytes[*at..*at+len];*at+=len;field
    }
    fn status(id:u32,code:u32)->Vec<u8>{
        let mut out=vec![101];out.extend(id.to_be_bytes());out.extend(code.to_be_bytes());
        out.extend(0u32.to_be_bytes());out.extend(0u32.to_be_bytes());out
    }
    fn handle(id:u32,value:u8)->Vec<u8>{let mut out=vec![102];out.extend(id.to_be_bytes());
        out.extend(1u32.to_be_bytes());out.push(value);out}
    fn version()->Vec<u8>{
        let mut out=vec![2,0,0,0,3];for name in [b"copy-data".as_slice(),b"hardlink@openssh.com",b"fsync@openssh.com"]{
            field(&mut out,name);field(&mut out,b"1");}out
    }
    async fn serve(mut stream:DuplexStream,mut peer:Peer)->Peer{
        while let Ok(length)=stream.read_u32().await{
            let mut request=vec![0;length as usize];if stream.read_exact(&mut request).await.is_err(){break}
            let kind=request[0];let id=if kind==1{0}else{u32::from_be_bytes(request[1..5].try_into().unwrap())};
            let mut at=5;
            let mut reply=match kind{
                1=>version(),
                7=>{let path=field_at(&request,&mut at);peer.attrs(path).map(|mut value|{value[1..5].copy_from_slice(&id.to_be_bytes());value})
                    .or_else(||if path==b"/src"||path==b"/dst"{
                        let mut out=vec![105];out.extend(id.to_be_bytes());out.extend(15u32.to_be_bytes());
                        out.extend(0u64.to_be_bytes());out.extend(1u32.to_be_bytes());out.extend(2u32.to_be_bytes());
                        out.extend(0o040755u32.to_be_bytes());out.extend(3u32.to_be_bytes());out.extend(4u32.to_be_bytes());Some(out)
                    }else{None}).unwrap_or_else(||status(id,2))},
                16=>{let path=field_at(&request,&mut at);let mut out=vec![104];out.extend(id.to_be_bytes());
                    out.extend(1u32.to_be_bytes());field(&mut out,path);field(&mut out,b"");out.extend(0u32.to_be_bytes());out},
                8=>{let handle=field_at(&request,&mut at);let path=match handle{b"s"=>b"/src/file".as_slice(),
                    b"t"=>b"/dst/.mac-explorer-copy-stage".as_slice(),b"f"=>b"/dst/final".as_slice(),_=>b"/missing".as_slice()};
                    peer.attrs(path).map(|mut value|{value[1..5].copy_from_slice(&id.to_be_bytes());value})
                        .unwrap_or_else(||status(id,2))},
                3=>{let path=field_at(&request,&mut at);let flags=u32::from_be_bytes(request[at..at+4].try_into().unwrap());at+=4;
                    let attrs=u32::from_be_bytes(request[at..at+4].try_into().unwrap());
                    assert_eq!(attrs,if flags&8!=0{4}else{0});
                    if path==b"/src/file"&&flags==1{handle(id,b's')}
                    else if path==b"/dst/final"&&peer.final_exists&&flags==1{handle(id,b'f')}
                    else if path.starts_with(b"/dst/.mac-explorer-copy-")&&flags==0x2a&&!peer.stage_exists{
                        peer.stage_exists=true;if peer.lost_stage_open_reply{break}handle(id,b't')}
                    else if path.starts_with(b"/dst/.mac-explorer-copy-")&&peer.stage_exists&&flags==1{handle(id,b't')}
                    else{status(id,4)}},
                5=>panic!("server Copy must not read file bodies to the client"),
                10=>{assert_eq!(field_at(&request,&mut at),b"t");
                    assert_eq!(u32::from_be_bytes(request[at..at+4].try_into().unwrap()),12);at+=4;
                    let mode=u32::from_be_bytes(request[at..at+4].try_into().unwrap());at+=8;
                    peer.mode=0o100000|mode;peer.mtime=u32::from_be_bytes(request[at..at+4].try_into().unwrap());status(id,0)},
                200=>{let name=field_at(&request,&mut at);match name{
                    b"copy-data"=>{assert_eq!(field_at(&request,&mut at),b"s");
                        let offset=u64::from_be_bytes(request[at..at+8].try_into().unwrap())as usize;at+=8;
                        let count=u64::from_be_bytes(request[at..at+8].try_into().unwrap())as usize;at+=8;
                        assert!(count>0&&count<=RANGE as usize);assert_eq!(field_at(&request,&mut at),b"t");
                        let destination=u64::from_be_bytes(request[at..at+8].try_into().unwrap())as usize;
                        assert_eq!(destination,offset);assert_eq!(peer.stage.len(),offset);
                        peer.stage.extend(&peer.source[offset..offset+count]);peer.copy_calls+=1;
                        if peer.pause_copy{tokio::time::sleep(std::time::Duration::from_millis(150)).await;}
                        status(id,0)},
                    b"fsync@openssh.com"=>{assert_eq!(field_at(&request,&mut at),b"t");status(id,0)},
                    b"hardlink@openssh.com"=>{let old=field_at(&request,&mut at);let new=field_at(&request,&mut at);
                        assert!(old.starts_with(b"/dst/.mac-explorer-copy-"));assert_eq!(new,b"/dst/final");
                        if peer.race_final_on_link{peer.final_exists=true;}
                        if peer.final_exists{status(id,4)}else{peer.final_exists=true;
                            if peer.lost_link_reply{break}status(id,0)}},_=>status(id,4)}},
                13=>{let path=field_at(&request,&mut at);assert!(path.starts_with(b"/dst/.mac-explorer-copy-"));
                    peer.stage_exists=false;status(id,0)},
                4=>status(id,0),_=>status(id,4),
            };
            if stream.write_u32(reply.len()as u32).await.is_err()||stream.write_all(&reply).await.is_err(){break}
            reply.clear();
        }
        peer
    }
    async fn run(source:&[u8],peer:Peer)->(Result<Receipt,Interrupted>,Peer){
        let (client,server)=tokio::io::duplex(512<<10);let task=tokio::spawn(serve(server,peer));
        let target=Target::new("/src/file","/dst/final",[7;16]).unwrap();
        let selected=Metadata{size:Some(source.len() as u64),modified:Some(4),permissions:Some(0o100751)};
        let result=send(client,&target,selected,Limits::default(),None).await;
        (result,task.await.unwrap())
    }
    #[tokio::test]async fn nonempty_and_empty_copy_preserve_mode_mtime_and_source(){
        for body in [b"copy me".as_slice(),b"".as_slice()]{
            let(result,peer)=run(body,Peer::new(body)).await;
            assert_eq!(result.unwrap().bytes,body.len()as u64);
            assert_eq!(peer.source,body);assert_eq!(peer.stage,body);
            assert!(!peer.stage_exists&&peer.final_exists);
            assert_eq!(peer.mode,0o100751);assert_eq!(peer.mtime,4);
            assert_eq!(peer.copy_calls,usize::from(!body.is_empty()));
        }
    }
    #[tokio::test]async fn collision_before_stage_is_safe_and_lost_link_reply_is_uncertain(){
        let mut collision=Peer::new(b"file");collision.final_exists=true;
        let(result,peer)=run(b"file",collision).await;
        let error=result.unwrap_err();assert_eq!(error.cause,Failure::Conflict);
        assert!(!error.stage_may_exist&&!error.publication_may_have_happened);
        assert!(!peer.stage_exists);assert_eq!(peer.source,b"file");
        let mut lost=Peer::new(b"file");lost.lost_link_reply=true;
        let(result,peer)=run(b"file",lost).await;
        let error=result.unwrap_err();assert_eq!(error.phase,Phase::Publishing);
        assert!(error.stage_may_exist&&error.publication_may_have_happened);
        assert!(peer.stage_exists&&peer.final_exists);assert_eq!(peer.source,b"file");
    }
    #[tokio::test]async fn lost_stage_open_and_late_collision_retain_reviewable_stage(){
        let mut lost=Peer::new(b"file");lost.lost_stage_open_reply=true;
        let(result,peer)=run(b"file",lost).await;let error=result.unwrap_err();
        assert_eq!(error.phase,Phase::OpeningStage);
        assert!(error.stage_may_exist&&!error.publication_may_have_happened);
        assert!(peer.stage_exists&&!peer.final_exists);
        let mut race=Peer::new(b"file");race.race_final_on_link=true;
        let(result,peer)=run(b"file",race).await;let error=result.unwrap_err();
        assert_eq!(error.phase,Phase::Publishing);
        assert!(error.stage_may_exist&&error.publication_may_have_happened);
        assert!(peer.stage_exists&&peer.final_exists);
        assert_eq!(peer.source,b"file");
    }
    #[tokio::test]async fn stop_during_copy_range_keeps_stage_and_no_confirmed_final(){
        use std::sync::atomic::Ordering;
        let body=b"file";let mut peer=Peer::new(body);peer.pause_copy=true;
        let (client,server)=tokio::io::duplex(512<<10);let task=tokio::spawn(serve(server,peer));
        let target=Target::new("/src/file","/dst/final",[7;16]).unwrap();
        let selected=Metadata{size:Some(body.len()as u64),modified:Some(4),permissions:Some(0o100751)};
        let stop=Arc::new(AtomicBool::new(false));let cancel=stop.clone();
        tokio::spawn(async move{tokio::time::sleep(std::time::Duration::from_millis(40)).await;
            cancel.store(true,Ordering::Release);});
        let error=send(client,&target,selected,Limits::default(),Some(stop)).await.unwrap_err();
        assert_eq!(error.cause,Failure::Stopped);assert!(error.stage_may_exist);
        assert!(!error.publication_may_have_happened);
        let peer=task.await.unwrap();assert!(peer.stage_exists&&!peer.final_exists);
        assert_eq!(peer.source,body);
    }
}
