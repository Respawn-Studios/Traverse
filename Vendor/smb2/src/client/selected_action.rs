//! Explicit selected-file Rename/Delete/Move/Copy on U1's encrypted connection.
use std::sync::{Arc,Mutex};
use tokio::sync::mpsc;
use crate::{Error,Result,client::{Connection,selected_download as d1,selected_folder_download::safe_remote_component},
    msg::{create::{CreateAction,CreateDisposition,CreateRequest,CreateResponse,ImpersonationLevel,ShareAccess},
        close::CloseRequest,flush::FlushRequest,ioctl::{IoctlRequest,SMB2_0_IOCTL_IS_FSCTL,
            FSCTL_SRV_COPYCHUNK,FSCTL_SRV_REQUEST_RESUME_KEY},
        query_info::{InfoType,QueryInfoRequest},set_info::SetInfoRequest},
    pack::{ReadCursor,Unpack},types::{Command,FileId,OplockLevel,TreeId,flags::FileAccessMask,status::NtStatus}};

const MAX_DEPTH:usize=32;
const MAX_HELD_HANDLES:usize=2*MAX_DEPTH+6;
const DIRECTORY_ACCESS:u32=0x0010_0081;
const DIRECTORY_ACTION_ACCESS:u32=DIRECTORY_ACCESS|FileAccessMask::DELETE;
const FILE_ACCESS:u32=FileAccessMask::FILE_READ_ATTRIBUTES|FileAccessMask::DELETE|FileAccessMask::SYNCHRONIZE;
const COPY_SOURCE_ACCESS:u32=FileAccessMask::FILE_READ_DATA|FileAccessMask::FILE_READ_ATTRIBUTES|FileAccessMask::SYNCHRONIZE;
const COPY_STAGE_ACCESS:u32=FileAccessMask::FILE_READ_DATA|FileAccessMask::FILE_WRITE_DATA|
    FileAccessMask::FILE_READ_ATTRIBUTES|FileAccessMask::DELETE|FileAccessMask::SYNCHRONIZE;
const MAX_COPY:u64=64<<30;
const COPY_CHUNK:u32=256*1024;
const MAX_COPY_CHUNKS:u32=16;
const PROBE_ACCESS:u32=FileAccessMask::FILE_READ_ATTRIBUTES|FileAccessMask::SYNCHRONIZE;
const DIRECTORY_OPTIONS:u32=0x0020_0001;
const FILE_OPTIONS:u32=0x0020_0040;
const PROBE_OPTIONS:u32=0x0020_0000;
fn invalid()->Error{Error::invalid_data("Selected SMB action refused")}
// Fixed categories only. Neither a path nor a server-provided metadata value
// is included in the worker's pre-BEGIN refusal diagnostic.
#[repr(u8)]
enum PreflightCheck{
    // Code 8 is reserved for the historical cross-object timestamp refusal.
    Directory=1,Attributes,Size,Modified,Object,Links,Volume,CreateAttributes=9,CreateModified,
}
const PREFLIGHT_MESSAGES:[&str;10]=[
    "Selected SMB action preflight 1","Selected SMB action preflight 2","Selected SMB action preflight 3",
    "Selected SMB action preflight 4","Selected SMB action preflight 5","Selected SMB action preflight 6",
    "Selected SMB action preflight 7","Selected SMB action preflight 8","Selected SMB action preflight 9",
    "Selected SMB action preflight 10",
];
fn preflight_refusal(check:PreflightCheck)->Error{Error::invalid_data(PREFLIGHT_MESSAGES[check as usize-1])}
pub fn preflight_code(error:&Error)->Option<u8>{
    match error{Error::InvalidData{message}=>PREFLIGHT_MESSAGES.iter().position(|value|*value==message.as_str()).map(|at|(at+1)as u8),_=>None}
}
fn u16_at(v:&[u8],n:usize)->u16{u16::from_le_bytes(v[n..n+2].try_into().unwrap())}
fn u32_at(v:&[u8],n:usize)->u32{u32::from_le_bytes(v[n..n+4].try_into().unwrap())}
fn u64_at(v:&[u8],n:usize)->u64{u64::from_le_bytes(v[n..n+8].try_into().unwrap())}
fn same_id(v:&[u8],n:usize,id:FileId)->bool{u64_at(v,n)==id.persistent&&u64_at(v,n+8)==id.volatile}
fn empty_error_response(raw:&[u8])->bool{
    (raw.len()==72||raw.len()==73)&&u16_at(raw,64)==9&&raw[66..72]==[0;6]
        &&(raw.len()==72||raw[72]==0)
}
fn valid_id(id:FileId)->bool{id!=FileId::default()&&id.persistent!=u64::MAX&&id.volatile!=u64::MAX}
fn valid_path(path:&[u16],root:bool)->bool{
    (root||!path.is_empty())&&path.len()<=2048&&
        (path.is_empty()||path.split(|v|*v==92).all(safe_remote_component))
}
fn joined(parent:&[u16],name:&[u16])->Vec<u16>{
    let mut out=parent.to_vec();if !out.is_empty(){out.push(92);}out.extend_from_slice(name);out
}
fn bytes(path:&[u16])->Vec<u8>{path.iter().flat_map(|v|v.to_le_bytes()).collect()}
#[derive(Clone,Copy,PartialEq,Eq)]
enum OpenKind{Directory,DestinationDirectory,ActionDirectory,File,CopySource,CopyStage,Probe,Post,PostDirectory}
#[derive(Clone,Copy,PartialEq,Eq)]
enum SetResult{Applied,Collision,NotEmpty}
impl OpenKind{
    fn access(self)->u32{match self{Self::Directory|Self::DestinationDirectory=>DIRECTORY_ACCESS,Self::ActionDirectory=>DIRECTORY_ACTION_ACCESS,
        Self::File=>FILE_ACCESS,Self::CopySource=>COPY_SOURCE_ACCESS,Self::CopyStage=>COPY_STAGE_ACCESS,
        Self::Probe|Self::Post|Self::PostDirectory=>PROBE_ACCESS}}
    fn options(self)->u32{match self{Self::Directory|Self::DestinationDirectory|Self::ActionDirectory|Self::PostDirectory=>DIRECTORY_OPTIONS,
        Self::File|Self::CopySource|Self::CopyStage=>FILE_OPTIONS,Self::Probe|Self::Post=>PROBE_OPTIONS}}
    fn share(self)->u32{if self==Self::CopyStage{0}else if matches!(self,Self::Post|Self::PostDirectory){5}else{1}}
}
#[derive(Clone)]
enum Expected{Held,Open(Vec<u8>,OpenKind),Query(FileId,u8,u8,u32),Set(FileId,u8,Vec<u8>),
    Ioctl(FileId,u32,Vec<u8>,u32),Flush(FileId),Close(FileId)}
enum State{Idle,Active{tree:u32,session:u64,handles:Vec<FileId>,expected:Expected},Poisoned}
pub struct SelectedActionPolicy{state:Mutex<State>}
impl SelectedActionPolicy{
    pub fn new()->Arc<Self>{Arc::new(Self{state:Mutex::new(State::Idle)})}
    pub(crate) fn idle(&self)->bool{matches!(*self.state.lock().unwrap(),State::Idle)}
    pub(crate) fn begin(&self,tree:TreeId,session:u64)->Result<()>{
        let mut state=self.state.lock().unwrap();
        if tree.0==0||session==0||!matches!(*state,State::Idle){return Err(invalid());}
        *state=State::Active{tree:tree.0,session,handles:Vec::new(),expected:Expected::Held};Ok(())
    }
    pub(crate) fn allows_command(&self,code:usize)->bool{
        match &*self.state.lock().unwrap(){
            State::Idle|State::Poisoned=>false,
            State::Active{expected,..}=>matches!(code,12|13)||match expected{
                Expected::Held=>false,Expected::Open(..)=>code==5,Expected::Query(..)=>code==16,
                Expected::Set(..)=>code==17,Expected::Ioctl(..)=>code==11,
                Expected::Flush(..)=>code==7,Expected::Close(..)=>code==6,
            }
        }
    }
    pub fn permits_frame(&self,raw:&[u8])->bool{
        if !(64..=256*1024).contains(&raw.len())||!raw.starts_with(b"\xfeSMB")||u16_at(raw,4)!=64||u32_at(raw,20)!=0{return false;}
        let held=self.state.lock().unwrap();let(tree,session,expected)=match &*held{
            State::Active{tree,session,expected,..}=>(*tree,*session,expected),_=>return false,
        };
        let code=u16_at(raw,12);
        if u32_at(raw,16)&!8!=0||u64_at(raw,40)!=session{return false;}
        if matches!(code,12|13){return raw.len()==68&&u16_at(raw,64)==4&&raw[66..68]==[0,0];}
        if u32_at(raw,36)!=tree{return false;}
        let body=&raw[64..];
        match(code,expected){
            (5,Expected::Open(path,kind))=>body.len()==56+path.len()+usize::from(path.is_empty())&&u16_at(body,0)==57&&body[2..4]==[0;2]
                &&u32_at(body,4)==2&&body[8..24]==[0;16]&&u32_at(body,24)==kind.access()
                &&u32_at(body,28)==if *kind==OpenKind::CopyStage{0x80}else{0}
                &&u32_at(body,32)==kind.share()&&u32_at(body,36)==if *kind==OpenKind::CopyStage{2}else{1}
                &&u32_at(body,40)==kind.options()&&u16_at(body,44)==120
                &&usize::from(u16_at(body,46))==path.len()&&body[48..56]==[0;8]
                &&(if path.is_empty(){body[56..]==[0]}else{body[56..]==*path}),
            (16,Expected::Query(id,info,class,cap))=>body.len()==40&&u16_at(body,0)==41
                &&body[2]==*info&&body[3]==*class&&u32_at(body,4)==*cap&&body[8..24]==[0;16]
                &&same_id(body,24,*id),
            (17,Expected::Set(id,class,buffer))=>body.len()==32+buffer.len()&&u16_at(body,0)==33
                &&body[2]==1&&body[3]==*class&&u32_at(body,4)==buffer.len() as u32
                &&u16_at(body,8)==96&&body[10..16]==[0;6]&&same_id(body,16,*id)
                &&body[32..]==*buffer,
            (11,Expected::Ioctl(id,ctl,input,max_output))=>body.len()==56+input.len()&&u16_at(body,0)==57
                &&body[2..4]==[0;2]&&u32_at(body,4)==*ctl&&same_id(body,8,*id)
                &&u32_at(body,24)==if input.is_empty(){0}else{120}
                &&u32_at(body,28)==input.len() as u32&&u32_at(body,32)==0
                &&body[36..44]==[0;8]&&u32_at(body,44)==*max_output
                &&u32_at(body,48)==1&&u32_at(body,52)==0&&body[56..]==*input,
            (7,Expected::Flush(id))=>body.len()==24&&u16_at(body,0)==24&&body[2..8]==[0;6]
                &&same_id(body,8,*id),
            (6,Expected::Close(id))=>body.len()==24&&u16_at(body,0)==24&&body[2..8]==[0;6]&&same_id(body,8,*id),
            _=>false,
        }
    }
    fn expect(&self,next:Expected)->Result<()>{
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{handles,expected,..}if matches!(expected,Expected::Held)=>{
                let allowed=match &next{
                    Expected::Open(..)=>handles.len()<MAX_HELD_HANDLES,
                    Expected::Query(id,..)|Expected::Set(id,..)|Expected::Ioctl(id,..)|Expected::Flush(id)|Expected::Close(id)=>handles.contains(id),
                    Expected::Held=>false,
                };
                if !allowed{return Err(invalid());}*expected=next;Ok(())
            },_=>Err(invalid()),
        }
    }
    fn opened(&self,id:FileId)->Result<()>{
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{handles,expected:Expected::Open(..),..}
                if valid_id(id)&&!handles.contains(&id)&&handles.len()<MAX_HELD_HANDLES=>{
                    handles.push(id);if let State::Active{expected,..}=&mut *state{*expected=Expected::Held;}Ok(())
                },_=>Err(invalid()),
        }
    }
    fn missing(&self)->Result<()>{
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{expected:Expected::Open(..),..}=>{if let State::Active{expected,..}=&mut *state{*expected=Expected::Held;}Ok(())},
            _=>Err(invalid()),
        }
    }
    fn acknowledged(&self)->Result<()>{
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{expected,..}if matches!(expected,Expected::Query(..)|Expected::Set(..)|Expected::Ioctl(..)|Expected::Flush(..))=>{*expected=Expected::Held;Ok(())},
            _=>Err(invalid()),
        }
    }
    fn closed(&self,id:FileId)->Result<()>{
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{handles,expected,..}if matches!(&*expected,Expected::Close(wanted)if *wanted==id)=>{
                let at=handles.iter().position(|v|*v==id).ok_or_else(invalid)?;
                handles.remove(at);*expected=Expected::Held;Ok(())
            },_=>Err(invalid()),
        }
    }
    fn finish(&self)->Result<()>{
        let mut state=self.state.lock().unwrap();match &*state{
            State::Active{handles,expected:Expected::Held,..}if handles.is_empty()=>{*state=State::Idle;Ok(())},
            _=>Err(invalid()),
        }
    }
    fn poison(&self){*self.state.lock().unwrap()=State::Poisoned;}
}

#[derive(Clone,PartialEq,Eq)]
struct Facts{size:u64,modified:u64,attributes:u32,index:u64,volume_created:u64,volume:u32,links:u32,directory:bool}
impl Facts{
    // Samba 4.20.6 fills FileFsVolumeInformation.VolumeCreationTime from the
    // queried path's birth time. Compare it only for observations of the same
    // object. The serial is the cross-object volume report; held ancestry and
    // parent indexes provide the stronger path/identity witness.
    fn same_reported_volume(&self,other:&Self)->bool{self.volume==other.volume}
    fn same_object_identity(&self,other:&Self)->bool{
        self.index==other.index&&self.same_reported_volume(other)&&self.volume_created==other.volume_created
    }
}
pub struct ListedFile{pub name:Vec<u16>,pub attributes:u32,pub size:u64,pub modified:u64,pub object:u64,pub parent:u64}
#[derive(Clone,Copy,PartialEq,Eq)]
pub enum ItemKind{File,Directory}
impl ItemKind{fn directory(self)->bool{self==Self::Directory}}
pub enum Action{Rename(Vec<u16>),Delete,RenameDirectory(Vec<u16>),DeleteEmptyDirectory,
    Move(Vec<u16>),MoveDirectory(Vec<u16>)}
impl Action{fn kind(&self)->ItemKind{match self{Self::Rename(_)|Self::Delete=>ItemKind::File,
    Self::RenameDirectory(_)|Self::DeleteEmptyDirectory=>ItemKind::Directory,
    Self::Move(_)=>ItemKind::File,Self::MoveDirectory(_)=>ItemKind::Directory}}}
pub enum Outcome{Confirmed,Collision,NotEmpty,StageCollision,FinalCollision}
/// The source and every root-to-parent directory remain open through mutation.
/// Share-delete is omitted, but some servers can force it; this is not a
/// universal race-freedom guarantee.
pub struct CheckedSelectedAction{
    conn:Connection,policy:Arc<SelectedActionPolicy>,tree:TreeId,session:u64,
    parent:Vec<u16>,source:Vec<u16>,kind:ItemKind,source_facts:Facts,chain:Vec<(Vec<u16>,FileId,Facts)>,
    destination_parent:Option<Vec<u16>>,destination_chain:Vec<(Vec<u16>,FileId,Facts)>,
    source_id:Option<FileId>,ended:bool,
    copy:bool,
}
impl CheckedSelectedAction{
    pub async fn prepare(conn:Connection,tree:TreeId,parent:&[u16],listed:ListedFile,kind:ItemKind)->Result<Self>{
        Self::prepare_for_action(conn,tree,parent,listed,kind,None,false).await?.ok_or_else(invalid)
    }
    /// Resolve a second parent on the same tree before a Move can receive BEGIN.
    pub async fn prepare_move(conn:Connection,tree:TreeId,parent:&[u16],listed:ListedFile,
        kind:ItemKind,destination_parent:&[u16])->Result<Option<Self>>{
        Self::prepare_for_action(conn,tree,parent,listed,kind,Some(destination_parent),false).await
    }
    pub async fn prepare_copy(conn:Connection,tree:TreeId,parent:&[u16],listed:ListedFile,
        destination_parent:&[u16])->Result<Option<Self>>{
        if listed.size>MAX_COPY{return Err(invalid());}
        Self::prepare_for_action(conn,tree,parent,listed,ItemKind::File,Some(destination_parent),true).await
    }
    async fn prepare_for_action(conn:Connection,tree:TreeId,parent:&[u16],listed:ListedFile,
        kind:ItemKind,destination_parent:Option<&[u16]>,copy:bool)->Result<Option<Self>>{
        if !valid_path(parent,true)||(!parent.is_empty()&&parent.split(|v|*v==92).count()>MAX_DEPTH)
            ||!safe_remote_component(&listed.name)||listed.attributes&0x450!=if kind.directory(){0x10}else{0}
            ||listed.object==0||listed.object==u64::MAX||listed.parent==0||listed.parent==u64::MAX
            ||listed.object==listed.parent{return Err(invalid());}
        let source=joined(parent,&listed.name);if !valid_path(&source,false){return Err(invalid());}
        if let Some(destination)=destination_parent{
            if !valid_path(destination,true)||destination.len()>1792
                ||(!destination.is_empty()&&destination.split(|v|*v==92).count()>MAX_DEPTH)
                ||!valid_path(&joined(destination,&listed.name),false)||(!copy&&destination==parent)
                ||kind.directory()&&(destination==source.as_slice()
                    ||destination.starts_with(&source)&&destination.get(source.len())==Some(&92)){
                return Err(invalid());
            }
        }
        let outer=conn.selected_upload_policy()?;let session=conn.session_id().0;
        let policy=outer.begin_action(tree,session)?;
        let mut out=Self{conn,policy,tree,session,parent:parent.to_vec(),source,kind,source_facts:Facts{
            size:0,modified:0,attributes:0,index:0,volume_created:0,volume:0,links:0,directory:false,
        },chain:Vec::new(),destination_parent:destination_parent.map(|path|path.to_vec()),
            destination_chain:Vec::new(),source_id:None,ended:false,copy};
        out.open_chain().await?;
        let parent_facts=&out.chain.last().ok_or_else(invalid)?.2;
        if parent_facts.index!=listed.parent{return Err(invalid());}
        let source_open=if kind.directory(){OpenKind::ActionDirectory}else if copy{OpenKind::CopySource}else{OpenKind::File};
        let (id,response)=out.open(&out.source.clone(),source_open).await?.ok_or_else(invalid)?;
        out.source_id=Some(id);let facts=out.observe(id).await?;
        if facts.directory!=kind.directory(){return Err(preflight_refusal(PreflightCheck::Directory));}
        if facts.attributes!=listed.attributes{return Err(preflight_refusal(PreflightCheck::Attributes));}
        if facts.size!=listed.size{return Err(preflight_refusal(PreflightCheck::Size));}
        if facts.modified!=listed.modified{return Err(preflight_refusal(PreflightCheck::Modified));}
        if facts.index!=listed.object{return Err(preflight_refusal(PreflightCheck::Object));}
        if (kind.directory()&&facts.links==0)||(!kind.directory()&&facts.links!=1){return Err(preflight_refusal(PreflightCheck::Links));}
        if !facts.same_reported_volume(parent_facts){return Err(preflight_refusal(PreflightCheck::Volume));}
        if response.file_attributes!=facts.attributes{return Err(preflight_refusal(PreflightCheck::CreateAttributes));}
        if response.last_write_time.0!=facts.modified{return Err(preflight_refusal(PreflightCheck::CreateModified));}
        out.source_facts=facts;out.revalidate_chain().await?;
        if out.destination_parent.is_some(){
            if !out.open_destination_chain().await?{
                out.revalidate_chain().await?;
                let source=out.source_handle()?;
                if out.observe(source).await?!=out.source_facts{return Err(invalid());}
                out.finish_known_refusal(source).await?;
                return Ok(None);
            }
            out.revalidate_chain().await?;
        }
        Ok(Some(out))
    }
    async fn open_chain(&mut self)->Result<()>{
        let mut path=Vec::<u16>::new();
        let components=if self.parent.is_empty(){Vec::new()}else{self.parent.split(|v|*v==92).map(|v|v.to_vec()).collect()};
        for part in std::iter::once(None).chain(components.iter().map(Some)){
            if let Some(part)=part{if !path.is_empty(){path.push(92);}path.extend(part);}
            let (id,response)=self.open(&path,OpenKind::Directory).await?.ok_or_else(invalid)?;
            let facts=self.observe(id).await?;
            if !facts.directory||response.file_attributes!=facts.attributes
                ||response.last_write_time.0!=facts.modified
                ||self.chain.first().is_some_and(|v|!v.2.same_reported_volume(&facts)){
                return Err(invalid());
            }
            self.chain.push((path.clone(),id,facts));
        }
        Ok(())
    }
    async fn open_destination_chain(&mut self)->Result<bool>{
        let parent=self.destination_parent.as_ref().ok_or_else(invalid)?;
        let components=if parent.is_empty(){Vec::new()}else{
            parent.split(|unit|*unit==92).map(|part|part.to_vec()).collect::<Vec<_>>()};
        let root=self.chain.first().ok_or_else(invalid)?.2.clone();
        let source_parent=self.chain.last().ok_or_else(invalid)?.2.clone();
        let mut path=Vec::<u16>::new();
        for (index,part) in components.iter().enumerate(){
            if !path.is_empty(){path.push(92);}path.extend(part);
            if self.chain.get(index+1).is_some_and(|held|held.0.as_slice()==path.as_slice()){continue;}
            let Some((id,response))=self.open(&path,OpenKind::DestinationDirectory).await? else{return Ok(false)};
            let facts=self.observe(id).await?;
            if !facts.directory||response.file_attributes!=facts.attributes
                ||response.last_write_time.0!=facts.modified||!facts.same_reported_volume(&root)
                ||self.kind.directory()&&facts.same_object_identity(&self.source_facts){return Err(invalid());}
            self.destination_chain.push((path.clone(),id,facts));
        }
        let destination=self.destination_parent_facts()?;
        if (destination.same_object_identity(&source_parent)
                &&(!self.copy||self.destination_parent.as_deref()!=Some(self.parent.as_slice())))
            ||!destination.same_reported_volume(&self.source_facts){return Err(invalid());}
        Ok(true)
    }
    fn destination_parent_facts(&self)->Result<&Facts>{
        let parent=self.destination_parent.as_ref().ok_or_else(invalid)?;
        self.destination_chain.last().map(|held|&held.2)
            .or_else(||self.chain.iter().find(|held|held.0.as_slice()==parent.as_slice()).map(|held|&held.2))
            .ok_or_else(invalid)
    }
    fn destination_target(&self)->Result<Vec<u16>>{
        let parent=self.destination_parent.as_ref().ok_or_else(invalid)?;
        let name=self.source.rsplit(|unit|*unit==92).next().ok_or_else(invalid)?;
        let target=joined(parent,name);
        if !valid_path(&target,false){return Err(invalid());}Ok(target)
    }
    async fn open(&self,path:&[u16],kind:OpenKind)->Result<Option<(FileId,CreateResponse)>>{
        if !valid_path(path,kind==OpenKind::Directory){return Err(invalid());}
        let name=bytes(path);self.policy.expect(Expected::Open(name,kind))?;
        let request=CreateRequest{requested_oplock_level:OplockLevel::None,impersonation_level:ImpersonationLevel::Impersonation,
            desired_access:FileAccessMask::new(kind.access()),
            file_attributes:if kind==OpenKind::CopyStage{0x80}else{0},share_access:ShareAccess(kind.share()),
            create_disposition:if kind==OpenKind::CopyStage{CreateDisposition::FileCreate}else{CreateDisposition::FileOpen},
            create_options:kind.options(),
            name:String::from_utf16(path).map_err(|_|invalid())?,create_contexts:vec![]};
        let frame=self.conn.execute(Command::Create,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Create,self.tree,self.session)?;
        if kind==OpenKind::Probe&&frame.header.status==NtStatus::OBJECT_NAME_NOT_FOUND{
            self.policy.missing()?;return Ok(None);
        }
        if kind==OpenKind::CopyStage&&frame.header.status==NtStatus::OBJECT_NAME_COLLISION{
            if !empty_error_response(raw){return Err(invalid());}
            self.policy.missing()?;return Ok(None);
        }
        if kind==OpenKind::DestinationDirectory&&matches!(frame.header.status,
            NtStatus::OBJECT_NAME_NOT_FOUND|NtStatus::OBJECT_PATH_NOT_FOUND|NtStatus::ACCESS_DENIED){
            if !empty_error_response(raw){return Err(invalid());}
            self.policy.missing()?;return Ok(None);
        }
        d1::success(&frame)?;
        if raw.len()!=152||u16_at(raw,64)!=89||raw[66..68]!=[0;2]||u32_at(raw,144)!=0||u32_at(raw,148)!=0{return Err(invalid());}
        let response=CreateResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        if response.create_action!=if kind==OpenKind::CopyStage{CreateAction::FileCreated}else{CreateAction::FileOpened}
            ||!valid_id(response.file_id){return Err(invalid());}
        self.policy.opened(response.file_id)?;Ok(Some((response.file_id,response)))
    }
    async fn query(&self,id:FileId,info:u8,class:u8,cap:u32)->Result<Vec<u8>>{
        self.policy.expect(Expected::Query(id,info,class,cap))?;
        let request=QueryInfoRequest{info_type:if info==1{InfoType::File}else{InfoType::Filesystem},
            file_info_class:class,output_buffer_length:cap,additional_information:0,flags:0,file_id:id,input_buffer:vec![]};
        let frame=self.conn.execute(Command::QueryInfo,&request,Some(self.tree)).await?;
        let data=d1::query_bytes(&frame,cap,self.tree,self.session)?.to_vec();self.policy.acknowledged()?;Ok(data)
    }
    async fn observe(&self,id:FileId)->Result<Facts>{
        let basic=self.query(id,1,4,40).await?;let standard=self.query(id,1,5,24).await?;
        let internal=self.query(id,1,6,8).await?;let volume=self.query(id,2,1,1042).await?;
        if basic.len()!=40||standard.len()!=24||internal.len()!=8||volume.len()<18{return Err(invalid());}
        let index=u64_at(&internal,0);let serial=u32_at(&volume,8);let label=u32_at(&volume,12)as usize;
        if index==0||index==u64::MAX||serial==0||standard[20]>1||standard[21]>1
            ||standard[22..24]!=[0;2]||volume[16]>1||label%2!=0||label>1024
            ||18usize.checked_add(label)!=Some(volume.len()){return Err(invalid());}
        let attributes=u32_at(&basic,32);let directory=standard[21]==1;
        if attributes&0x440!=0||((attributes&0x10!=0)!=directory)||standard[20]!=0{return Err(invalid());}
        Ok(Facts{size:u64_at(&standard,8),modified:u64_at(&basic,16),attributes,index,
            volume_created:u64_at(&volume,0),volume:serial,links:u32_at(&standard,16),directory})
    }
    async fn close(&self,id:FileId)->Result<()>{
        self.policy.expect(Expected::Close(id))?;
        let frame=self.conn.execute(Command::Close,&CloseRequest{flags:0,file_id:id},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Close,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=124||u16_at(raw,64)!=60||u16_at(raw,66)!=0{return Err(invalid());}
        self.policy.closed(id)
    }
    async fn flush(&self,id:FileId)->Result<()>{
        self.policy.expect(Expected::Flush(id))?;
        let frame=self.conn.execute(Command::Flush,&FlushRequest{file_id:id},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Flush,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=68||u16_at(raw,64)!=4||raw[66..68]!=[0;2]{return Err(invalid());}
        self.policy.acknowledged()
    }
    async fn copy_ioctl(&self,id:FileId,ctl:u32,input:Vec<u8>,max_output:u32)->Result<Vec<u8>>{
        if !matches!(ctl,FSCTL_SRV_REQUEST_RESUME_KEY|FSCTL_SRV_COPYCHUNK)
            ||(ctl==FSCTL_SRV_REQUEST_RESUME_KEY&&(id!=self.source_handle()?||!input.is_empty()||max_output!=32))
            ||(ctl==FSCTL_SRV_COPYCHUNK&&(input.len()<56||input.len()>32+24*MAX_COPY_CHUNKS as usize
                ||(input.len()-32)%24!=0||u32_at(&input,24)as usize!=(input.len()-32)/24
                ||max_output!=12)){
            return Err(invalid());
        }
        self.policy.expect(Expected::Ioctl(id,ctl,input.clone(),max_output))?;
        let request=IoctlRequest{ctl_code:ctl,file_id:id,max_input_response:0,max_output_response:max_output,
            flags:SMB2_0_IOCTL_IS_FSCTL,input_data:input};
        let frame=self.conn.execute(Command::Ioctl,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Ioctl,self.tree,self.session)?;d1::success(&frame)?;
        let size=if ctl==FSCTL_SRV_REQUEST_RESUME_KEY{32}else{12};
        if raw.len()!=112+size||u16_at(raw,64)!=49||u32_at(raw,68)!=ctl
            ||!(same_id(raw,72,id)||raw[72..88]==[255;16])
            ||![0,112].contains(&u32_at(raw,88))||u32_at(raw,92)!=0
            ||u32_at(raw,96)!=112||u32_at(raw,100)!=size as u32{return Err(invalid());}
        let output=raw[112..].to_vec();
        // Response reserved fields, flags and context length are ignored by
        // SMB2 clients; only the opaque first 24 key bytes are used for CopyChunk.
        self.policy.acknowledged()?;Ok(output)
    }
    async fn close_chain(&mut self)->Result<()>{
        while let Some((_,id,_))=self.destination_chain.pop(){self.close(id).await?;}
        while let Some((_,id,_))=self.chain.pop(){self.close(id).await?;}Ok(())
    }
    async fn revalidate_chain(&self)->Result<()>{
        for (path,_,old) in self.chain.iter().chain(self.destination_chain.iter()){
            let (id,_)=self.open(path,OpenKind::Directory).await?.ok_or_else(invalid)?;
            let fresh=self.observe(id).await?;self.close(id).await?;
            if !fresh.same_object_identity(old)
                ||fresh.attributes!=old.attributes{return Err(invalid());}
        }
        Ok(())
    }
    async fn revalidate_source_path(&self)->Result<()>{
        let (id,_)=self.open(&self.source,OpenKind::Probe).await?.ok_or_else(invalid)?;
        let fresh=self.observe(id).await?;self.close(id).await?;
        if fresh!=self.source_facts{return Err(invalid());}Ok(())
    }
    /// A Move or Copy changes a parent. Samba may derive the path-specific
    /// volume creation field from directory metadata, so compare the current
    /// path with its still-held original handle. The held handle must retain
    /// its original index, volume, type and attributes; a replaced path cannot
    /// borrow that index while the original object is held open.
    async fn revalidate_held_chain_after_mutation(&self)->Result<()>{
        for (path,held_id,old) in self.chain.iter().chain(self.destination_chain.iter()){
            let held=self.observe(*held_id).await?;
            if held.index!=old.index||!held.same_reported_volume(old)
                ||held.directory!=old.directory||held.attributes!=old.attributes{return Err(invalid());}
            let (fresh_id,_)=self.open(path,OpenKind::Directory).await?.ok_or_else(invalid)?;
            let fresh=self.observe(fresh_id).await?;self.close(fresh_id).await?;
            if !fresh.same_object_identity(&held)||fresh.directory!=held.directory
                ||fresh.attributes!=held.attributes{return Err(invalid());}
        }
        Ok(())
    }
    async fn set(&self,id:FileId,class:u8,buffer:Vec<u8>)->Result<SetResult>{
        if !matches!(class,10|13)||buffer.is_empty(){return Err(invalid());}
        self.policy.expect(Expected::Set(id,class,buffer.clone()))?;
        let request=SetInfoRequest{info_type:InfoType::File,file_info_class:class,additional_information:0,file_id:id,buffer};
        let frame=self.conn.execute(Command::SetInfo,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::SetInfo,self.tree,self.session)?;
        // Only these exact negative replies settle a known refusal. Every
        // held handle must still CLOSE cleanly before a caller reports it.
        if self.kind.directory()&&class==13&&frame.header.status==NtStatus::DIRECTORY_NOT_EMPTY{
            if !empty_error_response(raw){return Err(invalid());}
            self.policy.acknowledged()?;return Ok(SetResult::NotEmpty);
        }
        if class==10&&frame.header.status==NtStatus::OBJECT_NAME_COLLISION{
            if !empty_error_response(raw){return Err(invalid());}
            self.policy.acknowledged()?;return Ok(SetResult::Collision);
        }
        d1::success(&frame)?;
        if raw.len()!=66||u16_at(raw,64)!=2{return Err(invalid());}
        self.policy.acknowledged()?;Ok(SetResult::Applied)
    }
    fn matches_post(&self,after:&Facts)->bool{
        after.same_object_identity(&self.source_facts)&&self.matches_held_post(after,&self.source_facts)
    }
    fn matches_held_post(&self,after:&Facts,before:&Facts)->bool{
        after.index==before.index&&after.same_reported_volume(before)
            &&after.directory==self.kind.directory()&&after.links==before.links
            &&if self.kind.directory(){after.attributes==before.attributes}
                else{after.size==before.size&&after.modified==before.modified}
    }
    fn source_handle(&self)->Result<FileId>{self.source_id.ok_or_else(invalid)}
    async fn finish_known_refusal(&mut self,source:FileId)->Result<()>{
        self.close(source).await?;self.source_id=None;
        self.close_chain().await?;self.policy.finish()?;self.ended=true;Ok(())
    }
    pub async fn commit(self,action:Action)->Result<Outcome>{
        let mut checkpoint=0;
        self.commit_with_checkpoint(action,&mut checkpoint).await
    }
    /// Fixed, content-free checkpoint for a caller that will close the whole
    /// connection on failure. It is not a mutation outcome or retry authority.
    pub async fn commit_with_checkpoint(mut self,action:Action,checkpoint:&mut u8)->Result<Outcome>{
        *checkpoint=1;
        if action.kind()!=self.kind{return Err(invalid());}
        let move_parent=match &action{Action::Move(parent)|Action::MoveDirectory(parent)=>Some(parent.as_slice()),_=>None};
        if move_parent!=self.destination_parent.as_deref(){return Err(invalid());}
        let source=self.source_handle()?;
        self.revalidate_chain().await?;
        let before=self.observe(source).await?;
        if before!=self.source_facts{return Err(invalid());}
        let target=match action{
            Action::Rename(name)|Action::RenameDirectory(name)=>{
                if !safe_remote_component(&name)||name==self.source.rsplit(|v|*v==92).next().unwrap_or(&[])
                    ||String::from_utf16(&name).ok().zip(String::from_utf16(self.source.rsplit(|v|*v==92).next().unwrap_or(&[])).ok())
                        .is_some_and(|(a,b)|a.eq_ignore_ascii_case(&b)){return Err(invalid());}
                let path=joined(&self.parent,&name);if !valid_path(&path,false){return Err(invalid());}
                Some(path)
            },
            Action::Move(_)|Action::MoveDirectory(_)=>Some(self.destination_target()?),
            Action::Delete=>{
                if self.set(source,13,vec![1]).await?!=SetResult::Applied{return Err(invalid());}None
            },
            Action::DeleteEmptyDirectory=>{
                match self.set(source,13,vec![1]).await?{
                    SetResult::Applied=>{},
                    SetResult::NotEmpty=>{
                        self.finish_known_refusal(source).await?;return Ok(Outcome::NotEmpty);
                    },
                    SetResult::Collision=>return Err(invalid()),
                }
                None
            },
        };
        if let Some(path)=target.as_ref(){
            *checkpoint=2;
            if let Some((id,_))=self.open(path,OpenKind::Probe).await?{
                self.close(id).await?;self.finish_known_refusal(source).await?;
                return Ok(Outcome::Collision);
            }
            let dest=String::from_utf16(path).map_err(|_|invalid())?;
            let buffer=super::tree::build_rename_info_buffer(&dest,false);
            *checkpoint=3;
            match self.set(source,10,buffer).await?{
                SetResult::Applied=>{},
                SetResult::Collision=>{
                    self.finish_known_refusal(source).await?;return Ok(Outcome::Collision);
                },
                SetResult::NotEmpty=>return Err(invalid()),
            }
        }
        // Pin the renamed object at its new name before releasing the original
        // handle, so its filesystem ID cannot simply be reused during review.
        *checkpoint=4;
        let pinned=if let Some(target)=target.as_ref(){
            let post=if self.kind.directory(){OpenKind::PostDirectory}else{OpenKind::Post};
            let (id,_)=self.open(target,post).await?.ok_or_else(invalid)?;
            let after=self.observe(id).await?;
            if !self.matches_post(&after){return Err(invalid());}
            Some((id,after))
        }else{None};
        // Disposition is committed on CLOSE. An unanswered CLOSE needs review.
        *checkpoint=5;
        self.close(source).await?;self.source_id=None;
        let old=self.open(&self.source.clone(),OpenKind::Probe).await?;
        if let Some((id,_))=old{self.close(id).await?;return Err(invalid());}
        *checkpoint=6;
        if let Some((id,pinned_before))=pinned{
            let after=self.observe(id).await?;self.close(id).await?;
            // The exact target handle stayed open across source CLOSE. Keep
            // its stable object/metadata witness for Move, where source and
            // destination parent metadata can change. Ordinary Rename keeps
            // its original full post-mutation comparison.
            let valid=if self.destination_parent.is_some(){self.matches_held_post(&after,&pinned_before)}
                else{self.matches_post(&after)};
            if !valid{return Err(invalid());}
        }
        if self.destination_parent.is_some(){self.revalidate_held_chain_after_mutation().await?;}
        self.close_chain().await?;self.policy.finish()?;self.ended=true;Ok(Outcome::Confirmed)
    }
    /// Server-side CopyChunk copies only the default data stream. Every
    /// acknowledged chunk advances exactly once. A failed or ambiguous reply
    /// leaves the private stage for explicit review and kills this connection.
    pub async fn commit_copy_with_checkpoint(mut self,parent:Vec<u16>,name:Vec<u16>,stage:Vec<u16>,
        checkpoint:&mut u8,progress:&mpsc::Sender<(u64,u64)>)->Result<Outcome>{
        *checkpoint=1;
        if !self.copy||self.kind!=ItemKind::File||self.destination_parent.as_deref()!=Some(parent.as_slice())
            ||!safe_remote_component(&name)||!safe_remote_component(&stage)
            ||self.source_facts.size>MAX_COPY{return Err(invalid());}
        let stage_text=String::from_utf16(&stage).map_err(|_|invalid())?;
        if !stage_text.starts_with(".traverse-smb-copy-")||!stage_text.ends_with(".part")
            ||stage_text.len()!=".traverse-smb-copy-".len()+36+".part".len()
            ||!stage_text[".traverse-smb-copy-".len()..stage_text.len()-".part".len()]
                .bytes().enumerate().all(|(at,b)|if [8,13,18,23].contains(&at){b==b'-'}else{b.is_ascii_hexdigit()}){
            return Err(invalid());
        }
        let source_name=self.source.rsplit(|u|*u==92).next().ok_or_else(invalid)?;
        if parent==self.parent && String::from_utf16(&name).map_err(|_|invalid())?.eq_ignore_ascii_case(
            &String::from_utf16(source_name).map_err(|_|invalid())?){return Err(invalid());}
        let target=joined(&parent,&name);let stage_path=joined(&parent,&stage);
        if !valid_path(&target,false)||!valid_path(&stage_path,false)
            ||String::from_utf16(&name).map_err(|_|invalid())?.eq_ignore_ascii_case(&stage_text)
            ||String::from_utf16(&name).map_err(|_|invalid())?.to_ascii_lowercase().starts_with(".traverse-smb-copy-"){
            return Err(invalid());
        }
        let source=self.source_handle()?;
        self.revalidate_chain().await?;
        if self.observe(source).await?!=self.source_facts{return Err(invalid());}
        if let Some((id,_))=self.open(&target,OpenKind::Probe).await?{
            self.close(id).await?;self.finish_known_refusal(source).await?;
            return Ok(Outcome::Collision);
        }
        *checkpoint=2;
        let Some((stage_id,_))=self.open(&stage_path,OpenKind::CopyStage).await? else{
            self.finish_known_refusal(source).await?;return Ok(Outcome::StageCollision);
        };
        let size=self.source_facts.size;
        if size>0{
            let reply=self.copy_ioctl(source,FSCTL_SRV_REQUEST_RESUME_KEY,Vec::new(),32).await?;
            let mut key=[0u8;24];key.copy_from_slice(&reply[..24]);
            let mut copied=0u64;
            while copied<size{
                *checkpoint=3;
                let mut input=Vec::with_capacity(32+24*MAX_COPY_CHUNKS as usize);
                input.extend_from_slice(&key);input.extend_from_slice(&0u32.to_le_bytes());
                input.extend_from_slice(&0u32.to_le_bytes());
                let mut next=copied;let mut chunks=0u32;
                while next<size&&chunks<MAX_COPY_CHUNKS{
                    let count=(size-next).min(u64::from(COPY_CHUNK)) as u32;
                    input.extend_from_slice(&next.to_le_bytes());input.extend_from_slice(&next.to_le_bytes());
                    input.extend_from_slice(&count.to_le_bytes());input.extend_from_slice(&0u32.to_le_bytes());
                    next+=u64::from(count);chunks+=1;
                }
                input[24..28].copy_from_slice(&chunks.to_le_bytes());
                let reply=self.copy_ioctl(stage_id,FSCTL_SRV_COPYCHUNK,input,12).await?;
                // A successful status with a partial chunk is not completion.
                if u32_at(&reply,0)!=chunks||u32_at(&reply,4)!=0
                    ||u64::from(u32_at(&reply,8))!=next-copied{return Err(invalid());}
                copied=next;
                progress.send((copied,size)).await.map_err(|_|invalid())?;
            }
        }
        *checkpoint=4;
        self.flush(stage_id).await?;
        let stage_before=self.observe(stage_id).await?;
        if stage_before.directory||stage_before.size!=size||stage_before.links!=1
            ||!stage_before.same_reported_volume(&self.source_facts)
            ||stage_before.index==self.source_facts.index{return Err(invalid());}
        self.revalidate_held_chain_after_mutation().await?;
        if self.observe(source).await?!=self.source_facts{return Err(invalid());}
        self.revalidate_source_path().await?;
        *checkpoint=5;
        if let Some((id,_))=self.open(&target,OpenKind::Probe).await?{
            self.close(id).await?;self.close(stage_id).await?;self.finish_known_refusal(source).await?;
            return Ok(Outcome::FinalCollision);
        }
        let buffer=super::tree::build_rename_info_buffer(&String::from_utf16(&target).map_err(|_|invalid())?,false);
        match self.set(stage_id,10,buffer).await?{
            SetResult::Collision=>{
                self.close(stage_id).await?;self.finish_known_refusal(source).await?;
                return Ok(Outcome::FinalCollision);
            },
            SetResult::Applied=>{},SetResult::NotEmpty=>return Err(invalid()),
        }
        *checkpoint=6;
        // Share access 0 makes this stage exclusive. CLOSE must be acknowledged
        // before a separate final-name probe can open the published object.
        self.close(stage_id).await?;
        let (post_id,_)=self.open(&target,OpenKind::Post).await?.ok_or_else(invalid)?;
        let post=self.observe(post_id).await?;
        if post.index!=stage_before.index||!post.same_reported_volume(&stage_before)||post.size!=size||post.directory
            ||post.links!=stage_before.links{return Err(invalid());}
        if self.observe(source).await?!=self.source_facts{return Err(invalid());}
        self.revalidate_source_path().await?;
        self.revalidate_held_chain_after_mutation().await?;
        let final_facts=self.observe(post_id).await?;
        if !final_facts.same_object_identity(&post)||final_facts.size!=size{return Err(invalid());}
        self.close(post_id).await?;self.close(source).await?;self.source_id=None;
        self.close_chain().await?;self.policy.finish()?;self.ended=true;Ok(Outcome::Confirmed)
    }
}
impl Drop for CheckedSelectedAction{
    fn drop(&mut self){if !self.ended{self.policy.poison();self.conn.mark_dead();}}
}
#[cfg(feature="b12-action-qualification")]
/// Run three generated exact-frame controls through the production policy.
pub fn qualification_action_frames()->usize{
    tests::only_held_exact_delete_frame_has_mutation_authority();
    tests::root_open_needs_exact_empty_name_and_no_share_delete();
    tests::rename_frame_retains_no_replace_and_exact_target();3
}
#[cfg(feature="b12-action-qualification")]
/// Exercise the generated path-birth-time and same-object drift controls.
pub async fn qualification_volume_witness()->usize{
    tests::volume_witness::distinct_path_birth_times_allow_preflight_but_changed_root_or_source_still_refuse().await;1
}
#[cfg(feature="b12-action-qualification")]
/// Exercise exact directory Rename and empty-directory disposition controls.
pub async fn qualification_directory_actions()->usize{
    tests::volume_witness::directory_rename_and_empty_delete_are_distinct_and_bounded().await;3
}
#[cfg(feature="b12-action-qualification")]
/// Exercise known Rename collisions and uncertain malformed/failed-close replies.
pub async fn qualification_rename_collision()->usize{
    tests::volume_witness::rename_reports_set_collision_only_after_exact_reply_and_clean_closes().await;
    tests::volume_witness::rename_target_probe_collision_still_closes_without_set().await;
    tests::volume_witness::rename_collision_reply_malformed_or_close_failed_stays_uncertain().await;3
}
#[cfg(feature="b12-action-qualification")]
/// Exercise Move on one tree with both ancestries, a fixed no-replace frame and uncertain replies.
pub async fn qualification_same_session_move()->usize{
    tests::volume_witness::move_file_and_directory_hold_both_parents_and_use_no_replace().await;
    tests::volume_witness::move_probe_collision_closes_without_set().await;
    tests::volume_witness::move_refuses_changed_destination_and_cross_volume_before_set().await;
    tests::volume_witness::move_late_collision_and_malformed_set_stay_distinct().await;
    tests::volume_witness::move_destination_parent_refusal_requires_exact_reply_and_clean_closes().await;5
}
#[cfg(feature="b12-action-qualification")]
/// Exercise bounded server-side copy success and uncertain partial/collision paths.
pub async fn qualification_same_session_copy()->usize{
    tests::copy_frame_gate_permits_only_exact_resume_chunk_and_flush();
    tests::volume_witness::copy_batches_exact_256k_chunks_without_truncating_large_file().await;
    tests::volume_witness::copy_acknowledged_data_flush_close_and_no_replace_publish().await;
    tests::volume_witness::copy_rejects_replaced_parent_after_stage_and_publication().await;
    tests::volume_witness::copy_partial_reply_and_stage_collision_never_publish().await;
    tests::volume_witness::copy_short_resume_key_reply_leaves_stage_uncertain().await;
    tests::volume_witness::copy_unused_ioctl_response_fields_are_ignored().await;
    tests::volume_witness::copy_early_and_late_collisions_have_distinct_stage_outcomes().await;8
}
#[cfg(any(test,feature="b12-action-qualification"))]mod tests{
    use super::*;
    #[cfg(any(test,feature="b12-action-qualification"))]
    pub(super) mod volume_witness{
        use super::*;
        use crate::{client::{NegotiatedParams,selected_upload::SelectedUploadPolicy},
            msg::header::Header,pack::{Guid,Pack,WriteCursor},transport::MockTransport,
            types::{Dialect,SessionId,flags::Capabilities}};
        const TREE:TreeId=TreeId(7);
        const SESSION:u64=0x1234;
        fn response(command:Command,body:Vec<u8>)->Vec<u8>{
            let mut header=Header::new_request(command);header.tree_id=Some(TREE);
            header.session_id=SessionId(SESSION);header.credits=64;header.flags.set_response();
            let mut frame=WriteCursor::new();header.pack(&mut frame);frame.write_bytes(&body);frame.into_inner()
        }
        fn response_status(command:Command,status:NtStatus,body:Vec<u8>)->Vec<u8>{
            let mut raw=response(command,body);raw[8..12].copy_from_slice(&status.0.to_le_bytes());raw
        }
        fn opened(id:u64,directory:bool)->Vec<u8>{
            let mut body=vec![0;88];body[..2].copy_from_slice(&89u16.to_le_bytes());
            body[4..8].copy_from_slice(&1u32.to_le_bytes());
            body[24..32].copy_from_slice(&300u64.to_le_bytes());
            body[56..60].copy_from_slice(&(if directory{0x10u32}else{0x20}).to_le_bytes());
            body[64..72].copy_from_slice(&id.to_le_bytes());body[72..80].copy_from_slice(&id.to_le_bytes());
            response(Command::Create,body)
        }
        fn query(data:Vec<u8>)->Vec<u8>{
            let mut body=vec![0;8];body[..2].copy_from_slice(&9u16.to_le_bytes());
            body[2..4].copy_from_slice(&72u16.to_le_bytes());
            body[4..8].copy_from_slice(&(data.len()as u32).to_le_bytes());body.extend(data);
            response(Command::QueryInfo,body)
        }
        fn metadata(index:u64,birth:u64,serial:u32,directory:bool)->Vec<Vec<u8>>{
            let mut basic=vec![0;40];basic[16..24].copy_from_slice(&300u64.to_le_bytes());
            basic[32..36].copy_from_slice(&(if directory{0x10u32}else{0x20}).to_le_bytes());
            let mut standard=vec![0;24];standard[8..16].copy_from_slice(&(if directory{0u64}else{128}).to_le_bytes());
            standard[16..20].copy_from_slice(&1u32.to_le_bytes());standard[21]=u8::from(directory);
            let mut volume=vec![0;18];volume[..8].copy_from_slice(&birth.to_le_bytes());
            volume[8..12].copy_from_slice(&serial.to_le_bytes());volume[16]=1;
            vec![query(basic),query(standard),query(index.to_le_bytes().to_vec()),query(volume)]
        }
        fn metadata_with(index:u64,birth:u64,serial:u32,size:u64,modified:u64,links:u32)->Vec<Vec<u8>>{
            let mut frames=metadata(index,birth,serial,true);
            frames[0][88..96].copy_from_slice(&modified.to_le_bytes());
            frames[1][80..88].copy_from_slice(&size.to_le_bytes());
            frames[1][88..92].copy_from_slice(&links.to_le_bytes());frames
        }
        fn open(id:u64,index:u64,birth:u64,serial:u32,directory:bool)->Vec<Vec<u8>>{
            let mut frames=vec![opened(id,directory)];frames.extend(metadata(index,birth,serial,directory));frames
        }
        fn open_directory(id:u64,index:u64,birth:u64,size:u64,modified:u64,links:u32)->Vec<Vec<u8>>{
            let mut created=opened(id,true);created[88..96].copy_from_slice(&modified.to_le_bytes());
            let mut frames=vec![created];frames.extend(metadata_with(index,birth,13,size,modified,links));frames
        }
        fn close()->Vec<u8>{let mut body=vec![0;60];body[..2].copy_from_slice(&60u16.to_le_bytes());response(Command::Close,body)}
        fn set_success()->Vec<u8>{response(Command::SetInfo,vec![2,0])}
        fn error_body()->Vec<u8>{let mut body=vec![0;8];body[..2].copy_from_slice(&9u16.to_le_bytes());body}
        fn missing()->Vec<u8>{response_status(Command::Create,NtStatus::OBJECT_NAME_NOT_FOUND,error_body())}
        fn revalidate(root_birth:u64)->Vec<Vec<u8>>{
            let mut frames=open(14,100,root_birth,13,true);frames.push(close());
            frames.extend(open(15,200,600,13,true));frames.push(close());frames
        }
        fn prepare_frames(source_serial:u32,root_recheck_birth:u64)->Vec<Vec<u8>>{
            let mut frames=open(10,100,500,13,true);frames.extend(open(11,200,600,13,true));
            frames.extend(open(12,300,700,source_serial,false));frames.extend(revalidate(root_recheck_birth));frames
        }
        fn prepare_directory_frames()->Vec<Vec<u8>>{
            let mut frames=open(10,100,500,13,true);frames.extend(open(11,200,600,13,true));
            frames.extend(open_directory(12,300,700,0,300,2));frames.extend(revalidate(500));frames
        }
        fn destination_revalidation(id:u64,birth:u64)->Vec<Vec<u8>>{
            let mut frames=open(id,400,birth,13,true);frames.push(close());frames
        }
        fn move_prepare_frames(directory:bool,destination_serial:u32)->Vec<Vec<u8>>{
            let mut frames=if directory{prepare_directory_frames()}else{prepare_frames(13,500)};
            frames.extend(open(20,400,800,destination_serial,true));
            if destination_serial!=13{return frames;}
            frames.extend(revalidate(500));frames.extend(destination_revalidation(21,800));
            frames
        }
        fn move_commit_revalidation(destination_birth:u64)->Vec<Vec<u8>>{
            let mut frames=revalidate(500);frames.extend(destination_revalidation(23,destination_birth));frames
        }
        fn held_after_move(root_birth:u64,parent_birth:u64,destination_birth:Option<u64>)->Vec<Vec<u8>>{
            let mut frames=metadata(100,root_birth,13,true);
            frames.extend(open(14,100,root_birth,13,true));frames.push(close());
            frames.extend(metadata(200,parent_birth,13,true));
            frames.extend(open(15,200,parent_birth,13,true));frames.push(close());
            if let Some(birth)=destination_birth{
                frames.extend(metadata(400,birth,13,true));
                frames.extend(destination_revalidation(23,birth));
            }
            frames
        }
        fn setup()->(Connection,Arc<MockTransport>){
            let mock=Arc::new(MockTransport::new());mock.enable_auto_rewrite_msg_id();
            let mut conn=Connection::from_transport(Box::new(mock.clone()),Box::new(mock.clone()),"generated.invalid");
            conn.set_selected_upload_policy(SelectedUploadPolicy::new()).unwrap();
            conn.set_test_params(NegotiatedParams{dialect:Dialect::Smb3_1_1,max_read_size:65536,max_write_size:65536,
                max_transact_size:65536,server_guid:Guid::ZERO,signing_required:false,
                capabilities:Capabilities::default(),gmac_negotiated:false,cipher:None,compression_supported:false});
            conn.set_session_id(SessionId(SESSION));conn.set_credits(4096);conn.set_reviver(None);
            conn.set_keepalive(None);conn.set_response_timeout(Some(std::time::Duration::from_millis(250)));
            (conn,mock)
        }
        fn listed()->ListedFile{ListedFile{name:"Final.bin".encode_utf16().collect(),attributes:0x20,
            size:128,modified:300,object:300,parent:200}}
        fn listed_directory()->ListedFile{ListedFile{name:"Folder".encode_utf16().collect(),attributes:0x10,
            size:0,modified:300,object:300,parent:200}}
        fn no_set(mock:&MockTransport){assert!(!mock.sent_messages().iter().any(|frame|u16_at(frame,12)==17));}
        fn created(id:u64)->Vec<u8>{
            let mut raw=opened(id,false);raw[68..72].copy_from_slice(&2u32.to_le_bytes());raw
        }
        fn ioctl(ctl:u32,output:&[u8])->Vec<u8>{
            let mut body=vec![0;48];body[..2].copy_from_slice(&49u16.to_le_bytes());
            body[4..8].copy_from_slice(&ctl.to_le_bytes());body[8..24].fill(255);
            body[24..28].copy_from_slice(&112u32.to_le_bytes());
            body[32..36].copy_from_slice(&112u32.to_le_bytes());
            body[36..40].copy_from_slice(&(output.len()as u32).to_le_bytes());
            body.extend_from_slice(output);
            response(Command::Ioctl,body)
        }
        fn resume()->Vec<u8>{let mut key=vec![0x42;24];key.extend_from_slice(&[0;8]);
            ioctl(FSCTL_SRV_REQUEST_RESUME_KEY,&key)}
        fn chunk(chunks:u32,partial:u32,total:u32)->Vec<u8>{
            let mut output=Vec::new();output.extend_from_slice(&chunks.to_le_bytes());
            output.extend_from_slice(&partial.to_le_bytes());output.extend_from_slice(&total.to_le_bytes());
            ioctl(FSCTL_SRV_COPYCHUNK,&output)
        }
        fn flushed()->Vec<u8>{response(Command::Flush,vec![4,0,0,0])}
        fn copy_prepare()->Vec<Vec<u8>>{
            let mut frames=prepare_frames(13,500);frames.extend(revalidate(500));frames
        }
        fn copy_before_publish()->Vec<Vec<u8>>{
            let mut frames=revalidate(500);frames.extend(metadata(300,700,13,false));
            frames.push(missing());frames.push(created(25));frames.push(resume());
            frames.push(chunk(1,0,128));frames.push(flushed());
            frames.extend(metadata(400,800,13,false));frames.extend(held_after_move(500,601,None));
            frames.extend(metadata(300,700,13,false));
            frames.extend(open(26,300,700,13,false));frames.push(close());frames
        }
        fn replaced_copy_parent(birth:u64)->Vec<Vec<u8>>{
            let mut frames=metadata(100,500,13,true);
            frames.extend(open(14,100,500,13,true));frames.push(close());
            frames.extend(metadata(200,birth,13,true));
            frames.extend(open(15,201,birth,13,true));frames.push(close());frames
        }
        fn file_metadata(index:u64,birth:u64,size:u64)->Vec<Vec<u8>>{
            let mut frames=metadata(index,birth,13,false);
            frames[1][80..88].copy_from_slice(&size.to_le_bytes());frames
        }
        fn file_open(id:u64,index:u64,birth:u64,size:u64)->Vec<Vec<u8>>{
            let mut frames=vec![opened(id,false)];frames.extend(file_metadata(index,birth,size));frames
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_batches_exact_256k_chunks_without_truncating_large_file(){
            let size=512*1024u64;let parent:Vec<u16>="Parent".encode_utf16().collect();
            let name:Vec<u16>="Copy.bin".encode_utf16().collect();
            let stage:Vec<u16>=".traverse-smb-copy-77777777-7777-4777-8777-777777777777.part".encode_utf16().collect();
            let(conn,mock)=setup();let mut listed=listed();listed.size=size;
            let mut frames=open(10,100,500,13,true);frames.extend(open(11,200,600,13,true));
            frames.extend(file_open(12,300,700,size));frames.extend(revalidate(500));frames.extend(revalidate(500));
            frames.extend(revalidate(500));frames.extend(file_metadata(300,700,size));frames.push(missing());
            frames.push(created(25));frames.push(resume());frames.push(chunk(2,0,size as u32));
            frames.push(flushed());frames.extend(file_metadata(400,800,size));frames.extend(held_after_move(500,601,None));
            frames.extend(file_metadata(300,700,size));frames.extend(file_open(26,300,700,size));frames.push(close());
            frames.push(missing());frames.push(set_success());frames.push(close());
            frames.extend(file_open(27,400,901,size));frames.extend(file_metadata(300,700,size));
            frames.extend(file_open(28,300,700,size));frames.push(close());
            frames.extend(held_after_move(500,602,None));frames.extend(file_metadata(400,901,size));
            for _ in 0..4{frames.push(close());}mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed,&parent).await.unwrap().unwrap();
            let(tx,mut rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(matches!(action.commit_copy_with_checkpoint(parent,name,stage,&mut checkpoint,&tx).await,
                Ok(Outcome::Confirmed)));
            assert_eq!(rx.try_recv().unwrap(),(size,size));
            let sent=mock.sent_messages();let chunks=sent.iter().find(|frame|u16_at(frame,12)==11&&u32_at(frame,68)==FSCTL_SRV_COPYCHUNK).unwrap();
            assert_eq!(u32_at(chunks,92),80);assert_eq!(u32_at(chunks,144),2);
            assert_eq!(u64_at(chunks,152),0);assert_eq!(u64_at(chunks,176),256*1024);
            assert_eq!(sent.iter().filter(|frame|u16_at(frame,12)==11&&u32_at(frame,68)==FSCTL_SRV_COPYCHUNK).count(),1);
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_acknowledged_data_flush_close_and_no_replace_publish(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let name:Vec<u16>="Copy.bin".encode_utf16().collect();
            let stage:Vec<u16>=".traverse-smb-copy-77777777-7777-4777-8777-777777777777.part".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(copy_before_publish());
            frames.push(missing());frames.push(set_success());frames.push(close());
            frames.extend(open(27,400,901,13,false));frames.extend(metadata(300,700,13,false));
            frames.extend(open(28,300,700,13,false));frames.push(close());
            frames.extend(held_after_move(500,602,None));
            frames.extend(metadata(400,901,13,false));
            for _ in 0..4{frames.push(close());}mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,mut rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(matches!(action.commit_copy_with_checkpoint(parent.clone(),name.clone(),stage,
                &mut checkpoint,&tx).await,Ok(Outcome::Confirmed)));
            assert_eq!(checkpoint,6);assert_eq!(rx.try_recv().unwrap(),(128,128));
            let sent=mock.sent_messages();
            let ioctls=sent.iter().filter(|frame|u16_at(frame,12)==11).collect::<Vec<_>>();
            assert_eq!(ioctls.len(),2);assert_eq!(u32_at(ioctls[0],68),FSCTL_SRV_REQUEST_RESUME_KEY);
            assert_eq!(u32_at(ioctls[1],68),FSCTL_SRV_COPYCHUNK);
            assert_eq!(u32_at(ioctls[1],88),120);assert_eq!(u32_at(ioctls[1],92),56);
            let stage_create=sent.iter().find(|frame|u16_at(frame,12)==5&&u32_at(frame,100)==2).unwrap();
            assert_eq!(u32_at(stage_create,88),COPY_STAGE_ACCESS);assert_eq!(u32_at(stage_create,96),0);
            let set=sent.iter().find(|frame|u16_at(frame,12)==17).unwrap();
            assert_eq!(set[67],10);assert_eq!(set[96],0);
            assert_eq!(&set[96..],super::super::super::tree::build_rename_info_buffer("Parent\\Copy.bin",false).as_slice());
            assert!(!sent.iter().any(|frame|u16_at(frame,12)==9||u16_at(frame,12)==14));
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_rejects_replaced_parent_after_stage_and_publication(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let name:Vec<u16>="Copy.bin".encode_utf16().collect();
            let stage:Vec<u16>=".traverse-smb-copy-77777777-7777-4777-8777-777777777777.part".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(revalidate(500));
            frames.extend(metadata(300,700,13,false));frames.push(missing());
            frames.push(created(25));frames.push(resume());frames.push(chunk(1,0,128));
            frames.push(flushed());frames.extend(metadata(400,800,13,false));
            frames.extend(replaced_copy_parent(601));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(action.commit_copy_with_checkpoint(parent.clone(),name.clone(),stage.clone(),
                &mut checkpoint,&tx).await.is_err());
            assert_eq!(checkpoint,4);no_set(&mock);
            assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(copy_before_publish());
            frames.push(missing());frames.push(set_success());frames.push(close());
            frames.extend(open(27,400,901,13,false));frames.extend(metadata(300,700,13,false));
            frames.extend(open(28,300,700,13,false));frames.push(close());
            frames.extend(replaced_copy_parent(602));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(action.commit_copy_with_checkpoint(parent,name,stage,&mut checkpoint,&tx).await.is_err());
            assert_eq!(checkpoint,6);
            assert_eq!(mock.sent_messages().iter().filter(|frame|u16_at(frame,12)==17).count(),1);
            assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_partial_reply_and_stage_collision_never_publish(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let name:Vec<u16>="Copy.bin".encode_utf16().collect();
            let stage:Vec<u16>=".traverse-smb-copy-77777777-7777-4777-8777-777777777777.part".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(revalidate(500));
            frames.extend(metadata(300,700,13,false));frames.push(missing());
            frames.push(response_status(Command::Create,NtStatus::OBJECT_NAME_COLLISION,error_body()));
            for _ in 0..3{frames.push(close());}mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(matches!(action.commit_copy_with_checkpoint(parent.clone(),name.clone(),stage.clone(),
                &mut checkpoint,&tx).await,Ok(Outcome::StageCollision)));
            no_set(&mock);assert!(!mock.sent_messages().iter().any(|f|u16_at(f,12)==11));
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(revalidate(500));
            frames.extend(metadata(300,700,13,false));frames.push(missing());frames.push(created(25));
            frames.push(resume());frames.push(chunk(0,64,64));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(action.commit_copy_with_checkpoint(parent,name,stage,&mut checkpoint,&tx).await.is_err());
            assert_eq!(checkpoint,3);no_set(&mock);
            assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_short_resume_key_reply_leaves_stage_uncertain(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let name:Vec<u16>="Copy.bin".encode_utf16().collect();
            let stage:Vec<u16>=".traverse-smb-copy-77777777-7777-4777-8777-777777777777.part".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(revalidate(500));
            frames.extend(metadata(300,700,13,false));frames.push(missing());frames.push(created(25));
            let mut short=vec![0x42;24];short.extend_from_slice(&[0;4]);
            frames.push(ioctl(FSCTL_SRV_REQUEST_RESUME_KEY,&short));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(action.commit_copy_with_checkpoint(parent,name,stage,&mut checkpoint,&tx).await.is_err());
            assert_eq!(checkpoint,2);no_set(&mock);
            assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_unused_ioctl_response_fields_are_ignored(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=copy_prepare();
            let mut reply=resume();reply[66]=1;reply[88..92].copy_from_slice(&0u32.to_le_bytes());
            reply[104..108].copy_from_slice(&1u32.to_le_bytes());
            reply[108..112].copy_from_slice(&1u32.to_le_bytes());
            reply[136..140].copy_from_slice(&7u32.to_le_bytes());
            frames.push(reply);mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let source=action.source_handle().unwrap();
            let output=action.copy_ioctl(source,FSCTL_SRV_REQUEST_RESUME_KEY,Vec::new(),32).await.unwrap();
            assert_eq!(output.len(),32);assert_eq!(&output[..24],&[0x42;24]);
            drop(action);
            assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn copy_early_and_late_collisions_have_distinct_stage_outcomes(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let name:Vec<u16>="Copy.bin".encode_utf16().collect();
            let stage:Vec<u16>=".traverse-smb-copy-77777777-7777-4777-8777-777777777777.part".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(revalidate(500));
            frames.extend(metadata(300,700,13,false));frames.push(opened(22,false));
            for _ in 0..4{frames.push(close());}mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(matches!(action.commit_copy_with_checkpoint(parent.clone(),name.clone(),stage.clone(),
                &mut checkpoint,&tx).await,Ok(Outcome::Collision)));
            assert_eq!(checkpoint,1);no_set(&mock);
            assert!(!mock.sent_messages().iter().any(|frame|u16_at(frame,12)==5&&u32_at(frame,100)==2));
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(copy_before_publish());
            frames.push(opened(29,false));for _ in 0..5{frames.push(close());}mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(matches!(action.commit_copy_with_checkpoint(parent.clone(),name.clone(),stage.clone(),
                &mut checkpoint,&tx).await,Ok(Outcome::FinalCollision)));
            assert_eq!(checkpoint,5);no_set(&mock);
            assert_eq!(mock.sent_messages().iter().filter(|frame|u16_at(frame,12)==5&&u32_at(frame,100)==2).count(),1);
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(copy_before_publish());
            frames.push(missing());frames.push(response_status(Command::SetInfo,NtStatus::OBJECT_NAME_COLLISION,error_body()));
            for _ in 0..4{frames.push(close());}mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(matches!(action.commit_copy_with_checkpoint(parent.clone(),name.clone(),stage.clone(),
                &mut checkpoint,&tx).await,Ok(Outcome::FinalCollision)));
            assert_eq!(checkpoint,5);
            let set=mock.sent_messages().into_iter().find(|frame|u16_at(frame,12)==17).unwrap();
            assert_eq!(set[96],0);
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=copy_prepare();frames.extend(copy_before_publish());
            frames.push(missing());frames.push(response_status(Command::SetInfo,NtStatus::OBJECT_NAME_COLLISION,error_body()));
            frames.push(response_status(Command::Close,NtStatus::ACCESS_DENIED,error_body()));
            mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_copy(conn.clone(),TREE,&parent,listed(),&parent).await.unwrap().unwrap();
            let(tx,_rx)=mpsc::channel(8);let mut checkpoint=0;
            assert!(action.commit_copy_with_checkpoint(parent,name,stage,&mut checkpoint,&tx).await.is_err());
            assert_eq!(checkpoint,5);
            assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn distinct_path_birth_times_allow_preflight_but_changed_root_or_source_still_refuse(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let(conn,mock)=setup();mock.queue_responses(prepare_frames(13,500));
            let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed(),ItemKind::File).await.unwrap();
            no_set(&mock);drop(action);mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();mock.queue_responses(prepare_frames(14,500));
            let error=match CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed(),ItemKind::File).await{
                Err(error)=>error,Ok(_)=>panic!("changed serial accepted")};
            assert_eq!(preflight_code(&error),Some(7));no_set(&mock);mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();mock.queue_responses(prepare_frames(13,501));
            assert!(CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed(),ItemKind::File).await.is_err());
            no_set(&mock);mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=prepare_frames(13,500);
            frames.extend(revalidate(500));frames.extend(metadata(300,701,13,false));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed(),ItemKind::File).await.unwrap();
            assert!(action.commit(Action::Delete).await.is_err());no_set(&mock);
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn directory_rename_and_empty_delete_are_distinct_and_bounded(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();

            let(conn,mock)=setup();let mut frames=prepare_directory_frames();
            frames.extend(revalidate(500));frames.extend(metadata_with(300,700,13,0,300,2));
            frames.push(response_status(Command::SetInfo,NtStatus::DIRECTORY_NOT_EMPTY,error_body()));
            frames.push(close());frames.push(close());frames.push(close());mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed_directory(),ItemKind::Directory).await.unwrap();
            assert!(matches!(action.commit(Action::DeleteEmptyDirectory).await,Ok(Outcome::NotEmpty)));
            let sent=mock.sent_messages();let dispositions=sent.iter().filter(|frame|u16_at(frame,12)==17).collect::<Vec<_>>();
            assert_eq!(dispositions.len(),1);assert_eq!(dispositions[0][67],13);assert_eq!(dispositions[0][96],1);
            assert!(!sent.iter().any(|frame|u16_at(frame,12)==14));
            assert!(sent.iter().any(|frame|u16_at(frame,12)==5&&u32_at(frame,88)==DIRECTORY_ACTION_ACCESS
                &&u32_at(frame,104)==DIRECTORY_OPTIONS));
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=prepare_directory_frames();
            frames.extend(revalidate(500));frames.extend(metadata_with(300,700,13,0,300,2));
            frames.push(response_status(Command::SetInfo,NtStatus::DIRECTORY_NOT_EMPTY,error_body()));
            frames.push(response_status(Command::Close,NtStatus::ACCESS_DENIED,error_body()));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed_directory(),ItemKind::Directory).await.unwrap();
            assert!(action.commit(Action::DeleteEmptyDirectory).await.is_err());
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=prepare_directory_frames();
            frames.extend(revalidate(500));frames.extend(metadata_with(300,700,13,0,300,2));
            frames.push(missing());frames.push(set_success());
            frames.extend(open_directory(16,300,700,32,301,2));frames.push(close());frames.push(missing());
            frames.extend(metadata_with(300,700,13,64,302,2));
            frames.push(close());frames.push(close());frames.push(close());mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed_directory(),ItemKind::Directory).await.unwrap();
            assert!(matches!(action.commit(Action::RenameDirectory("Renamed".encode_utf16().collect())).await,Ok(Outcome::Confirmed)));
            let sent=mock.sent_messages();let renames=sent.iter().filter(|frame|u16_at(frame,12)==17).collect::<Vec<_>>();
            assert_eq!(renames.len(),1);assert_eq!(renames[0][67],10);assert_eq!(renames[0][96],0);
            assert!(!sent.iter().any(|frame|u16_at(frame,12)==14));
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }

        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn rename_reports_set_collision_only_after_exact_reply_and_clean_closes(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            for directory in [false,true]{
                let(conn,mock)=setup();
                let mut frames=if directory{prepare_directory_frames()}else{prepare_frames(13,500)};
                frames.extend(revalidate(500));
                if directory{frames.extend(metadata_with(300,700,13,0,300,2));}
                else{frames.extend(metadata(300,700,13,false));}
                frames.push(missing());
                frames.push(response_status(Command::SetInfo,NtStatus::OBJECT_NAME_COLLISION,error_body()));
                frames.push(close());frames.push(close());frames.push(close());mock.queue_responses(frames);
                let kind=if directory{ItemKind::Directory}else{ItemKind::File};
                let listed=if directory{listed_directory()}else{listed()};
                let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed,kind).await.unwrap();
                let name:Vec<u16>="Occupied".encode_utf16().collect();
                let rename=if directory{Action::RenameDirectory(name)}else{Action::Rename(name)};
                assert!(matches!(action.commit(rename).await,Ok(Outcome::Collision)));
                let sent=mock.sent_messages();
                let sets=sent.iter().filter(|frame|u16_at(frame,12)==17).collect::<Vec<_>>();
                assert_eq!(sets.len(),1);assert_eq!(sets[0][67],10);assert_eq!(sets[0][96],0);
                assert!(sent.iter().rev().take(3).all(|frame|u16_at(frame,12)==6));
                mock.close();conn.qualification_stop_and_join().await.unwrap();
            }
        }

        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn rename_target_probe_collision_still_closes_without_set(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=prepare_frames(13,500);
            frames.extend(revalidate(500));frames.extend(metadata(300,700,13,false));
            frames.push(opened(16,false));
            frames.push(close());frames.push(close());frames.push(close());frames.push(close());
            mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed(),ItemKind::File).await.unwrap();
            assert!(matches!(action.commit(Action::Rename("Occupied".encode_utf16().collect())).await,
                Ok(Outcome::Collision)));
            no_set(&mock);
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }

        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn rename_collision_reply_malformed_or_close_failed_stays_uncertain(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            for malformed in [true,false]{
                let(conn,mock)=setup();let mut frames=prepare_frames(13,500);
                frames.extend(revalidate(500));frames.extend(metadata(300,700,13,false));
                frames.push(missing());
                let body=if malformed{vec![2,0]}else{error_body()};
                frames.push(response_status(Command::SetInfo,NtStatus::OBJECT_NAME_COLLISION,body));
                if !malformed{
                    frames.push(response_status(Command::Close,NtStatus::ACCESS_DENIED,error_body()));
                }
                mock.queue_responses(frames);
                let action=CheckedSelectedAction::prepare(conn.clone(),TREE,&parent,listed(),ItemKind::File).await.unwrap();
                assert!(action.commit(Action::Rename("Occupied".encode_utf16().collect())).await.is_err());
                mock.close();conn.qualification_stop_and_join().await.unwrap();
            }
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn move_file_and_directory_hold_both_parents_and_use_no_replace(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let destination:Vec<u16>="Other".encode_utf16().collect();
            for (directory,parent_after,destination_after,source_after) in
                [(false,600,800,700),(true,600,800,700),(false,601,801,701)]{
                let(conn,mock)=setup();let mut frames=move_prepare_frames(directory,13);
                frames.extend(move_commit_revalidation(800));
                if directory{frames.extend(metadata_with(300,700,13,0,300,2));}
                else{frames.extend(metadata(300,700,13,false));}
                frames.push(missing());frames.push(set_success());
                if directory{frames.extend(open_directory(24,300,700,32,301,2));}
                else{frames.extend(open(24,300,700,13,false));}
                frames.push(close());frames.push(missing());
                if directory{frames.extend(metadata_with(300,source_after,13,64,302,2));}
                else{frames.extend(metadata(300,source_after,13,false));}
                frames.push(close());frames.extend(held_after_move(500,parent_after,Some(destination_after)));
                for _ in 0..3{frames.push(close());}
                mock.queue_responses(frames);
                let kind=if directory{ItemKind::Directory}else{ItemKind::File};
                let listed=if directory{listed_directory()}else{listed()};
                let action=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed,kind,&destination).await.unwrap().unwrap();
                let move_action=if directory{Action::MoveDirectory(destination.clone())}else{Action::Move(destination.clone())};
                let mut checkpoint=0;
                assert!(matches!(action.commit_with_checkpoint(move_action,&mut checkpoint).await,Ok(Outcome::Confirmed)));
                assert_eq!(checkpoint,6);
                let sent=mock.sent_messages();let sets=sent.iter().filter(|frame|u16_at(frame,12)==17).collect::<Vec<_>>();
                assert_eq!(sets.len(),1);
                assert_eq!(sets[0][67],10);
                assert_eq!(&sets[0][96..],super::super::super::tree::build_rename_info_buffer(
                    if directory{"Other\\Folder"}else{"Other\\Final.bin"},false).as_slice());
                let destination_bytes=bytes(&destination);
                assert!(sent.iter().any(|frame|u16_at(frame,12)==5&&frame.get(120..)==Some(destination_bytes.as_slice())
                    &&u32_at(frame,88)==DIRECTORY_ACCESS));
                assert!(sent.iter().rev().take(3).all(|frame|u16_at(frame,12)==6));
                mock.close();conn.qualification_stop_and_join().await.unwrap();
            }

            // Even when a server reports a stable birth time, a replacement
            // at the original parent path must not pass the held-handle test.
            let(conn,mock)=setup();let mut frames=move_prepare_frames(false,13);
            frames.extend(move_commit_revalidation(800));frames.extend(metadata(300,700,13,false));
            frames.push(missing());frames.push(set_success());
            frames.extend(open(24,300,700,13,false));frames.push(close());frames.push(missing());
            frames.extend(metadata(300,700,13,false));frames.push(close());
            frames.extend(metadata(100,500,13,true));
            frames.extend(open(14,999,500,13,true));frames.push(close());
            mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination)
                .await.unwrap().unwrap();
            let mut checkpoint=0;
            assert!(action.commit_with_checkpoint(Action::Move(destination.clone()),&mut checkpoint).await.is_err());
            assert_eq!(checkpoint,6);
            mock.close();conn.qualification_stop_and_join().await.unwrap();

            // The wire's '-' destination is the share root. It reuses the
            // already held root rather than opening a second root handle.
            let(conn,mock)=setup();let mut frames=prepare_frames(13,500);
            frames.extend(revalidate(500));
            frames.extend(revalidate(500));frames.extend(metadata(300,700,13,false));
            frames.push(missing());frames.push(set_success());
            frames.extend(open(24,300,700,13,false));frames.push(close());frames.push(missing());
            frames.extend(metadata(300,700,13,false));frames.push(close());
            frames.extend(held_after_move(500,600,None));frames.push(close());frames.push(close());
            mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&[]).await.unwrap().unwrap();
            assert!(matches!(action.commit(Action::Move(vec![])).await,Ok(Outcome::Confirmed)));
            let sent=mock.sent_messages();let sets=sent.iter().filter(|frame|u16_at(frame,12)==17).collect::<Vec<_>>();
            assert_eq!(sets.len(),1);
            assert_eq!(&sets[0][96..],super::super::super::tree::build_rename_info_buffer("Final.bin",false).as_slice());
            assert!(sent.iter().rev().take(2).all(|frame|u16_at(frame,12)==6));
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn move_probe_collision_closes_without_set(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let destination:Vec<u16>="Other".encode_utf16().collect();
            let(conn,mock)=setup();let mut frames=move_prepare_frames(false,13);
            frames.extend(move_commit_revalidation(800));frames.extend(metadata(300,700,13,false));
            frames.push(opened(22,false));for _ in 0..5{frames.push(close());}
            mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination).await.unwrap().unwrap();
            assert!(matches!(action.commit(Action::Move(destination)).await,Ok(Outcome::Collision)));
            no_set(&mock);
            assert!(mock.sent_messages().iter().rev().take(4).all(|frame|u16_at(frame,12)==6));
            let next=conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).unwrap();
            next.finish().unwrap();
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn move_refuses_changed_destination_and_cross_volume_before_set(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let destination:Vec<u16>="Other".encode_utf16().collect();
            for path in ["Parent\\Folder","Parent\\Folder\\Child"]{
                let(conn,mock)=setup();let destination:Vec<u16>=path.encode_utf16().collect();
                assert!(CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed_directory(),
                    ItemKind::Directory,&destination).await.is_err());
                assert!(mock.sent_messages().is_empty());
                mock.close();conn.qualification_stop_and_join().await.unwrap();
            }
            let(conn,mock)=setup();mock.queue_responses(move_prepare_frames(false,14));
            assert!(CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination).await.is_err());
            no_set(&mock);mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=prepare_directory_frames();
            frames.extend(open(20,300,700,13,true));mock.queue_responses(frames);
            let alias:Vec<u16>="Alias".encode_utf16().collect();
            assert!(CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed_directory(),ItemKind::Directory,&alias).await.is_err());
            no_set(&mock);mock.close();conn.qualification_stop_and_join().await.unwrap();

            let(conn,mock)=setup();let mut frames=move_prepare_frames(false,13);
            frames.extend(move_commit_revalidation(801));mock.queue_responses(frames);
            let action=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination).await.unwrap().unwrap();
            assert!(action.commit(Action::Move(destination)).await.is_err());no_set(&mock);
            mock.close();conn.qualification_stop_and_join().await.unwrap();
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn move_late_collision_and_malformed_set_stay_distinct(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let destination:Vec<u16>="Other".encode_utf16().collect();
            for response in [Some(error_body()),Some(vec![2,0]),None]{
                let(conn,mock)=setup();let mut frames=move_prepare_frames(false,13);
                frames.extend(move_commit_revalidation(800));frames.extend(metadata(300,700,13,false));
                frames.push(missing());
                if let Some(body)=response.as_ref(){
                    frames.push(response_status(Command::SetInfo,NtStatus::OBJECT_NAME_COLLISION,body.clone()));
                    if *body==error_body(){for _ in 0..4{frames.push(close());}}
                }
                mock.queue_responses(frames);
                let action=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination).await.unwrap().unwrap();
                let mut checkpoint=0;
                let result=action.commit_with_checkpoint(Action::Move(destination.clone()),&mut checkpoint).await;
                assert_eq!(checkpoint,3);
                if response.as_ref()==Some(&error_body()){
                    assert!(matches!(result,Ok(Outcome::Collision)));
                    assert!(mock.sent_messages().iter().rev().take(4).all(|frame|u16_at(frame,12)==6));
                }else{assert!(result.is_err());}
                assert_eq!(mock.sent_messages().iter().filter(|frame|u16_at(frame,12)==17).count(),1);
                mock.close();conn.qualification_stop_and_join().await.unwrap();
            }
        }
        #[cfg_attr(test,tokio::test)]
        pub(crate) async fn move_destination_parent_refusal_requires_exact_reply_and_clean_closes(){
            let parent:Vec<u16>="Parent".encode_utf16().collect();
            let destination:Vec<u16>="Other\\Missing".encode_utf16().collect();
            for status in [NtStatus::OBJECT_NAME_NOT_FOUND,NtStatus::OBJECT_PATH_NOT_FOUND,NtStatus::ACCESS_DENIED]{
                let(conn,mock)=setup();let mut frames=prepare_frames(13,500);
                frames.extend(open(20,400,800,13,true));
                frames.push(response_status(Command::Create,status,error_body()));
                frames.extend(revalidate(500));frames.extend(destination_revalidation(21,800));
                frames.extend(metadata(300,700,13,false));for _ in 0..4{frames.push(close());}
                mock.queue_responses(frames);
                let result=CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination).await;
                assert!(matches!(result,Ok(None)));no_set(&mock);
                assert!(mock.sent_messages().iter().rev().take(4).all(|frame|u16_at(frame,12)==6));
                let next=conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).unwrap();
                next.finish().unwrap();mock.close();conn.qualification_stop_and_join().await.unwrap();
            }
            // An exact status with a malformed body, missing reply, changed
            // ancestry/source identity, or failed CLOSE cannot preserve this session.
            for variant in 0..6{
                let(conn,mock)=setup();let mut frames=prepare_frames(13,500);
                frames.extend(open(20,400,800,13,true));
                if variant!=1{
                    let status=if variant==4{NtStatus::OBJECT_NAME_COLLISION}else{NtStatus::OBJECT_NAME_NOT_FOUND};
                    frames.push(response_status(Command::Create,status,
                        if variant==0{vec![2,0]}else{error_body()}));
                }
                if variant==2{
                    frames.extend(revalidate(501));
                }else if variant==3{
                    frames.extend(revalidate(500));frames.extend(destination_revalidation(21,800));
                    frames.extend(metadata(300,700,13,false));
                    frames.push(response_status(Command::Close,NtStatus::ACCESS_DENIED,error_body()));
                }else if variant==5{
                    frames.extend(revalidate(500));frames.extend(destination_revalidation(21,800));
                    frames.extend(metadata(301,700,13,false));
                }
                mock.queue_responses(frames);
                assert!(CheckedSelectedAction::prepare_move(conn.clone(),TREE,&parent,listed(),ItemKind::File,&destination).await.is_err());
                no_set(&mock);
                assert!(conn.selected_upload_policy().unwrap().begin_action(TREE,SESSION).is_err());
                mock.close();conn.qualification_stop_and_join().await.unwrap();
            }
        }
    }
    #[cfg(test)]
    #[test]
    fn preflight_diagnostic_accepts_only_fixed_reasons(){
        assert_eq!(preflight_code(&preflight_refusal(PreflightCheck::Modified)),Some(4));
        assert_eq!(preflight_code(&Error::invalid_data("Selected SMB action preflight 4 path=private")),None);
        assert_eq!(preflight_code(&invalid()),None);
    }
    fn frame(code:u16,body:&[u8])->Vec<u8>{
        let mut raw=vec![0;64];raw[..4].copy_from_slice(b"\xfeSMB");raw[4]=64;
        raw[12..14].copy_from_slice(&code.to_le_bytes());
        raw[36..40].copy_from_slice(&1u32.to_le_bytes());
        raw[40..48].copy_from_slice(&7u64.to_le_bytes());
        raw.extend_from_slice(body);raw
    }
    #[cfg_attr(test,test)]pub(super) fn copy_frame_gate_permits_only_exact_resume_chunk_and_flush(){
        fn ioctl_body(id:FileId,ctl:u32,input:&[u8],output:u32)->Vec<u8>{
            let mut body=vec![0;56+input.len()];body[..2].copy_from_slice(&57u16.to_le_bytes());
            body[4..8].copy_from_slice(&ctl.to_le_bytes());
            body[8..16].copy_from_slice(&id.persistent.to_le_bytes());
            body[16..24].copy_from_slice(&id.volatile.to_le_bytes());
            if !input.is_empty(){body[24..28].copy_from_slice(&120u32.to_le_bytes());}
            body[28..32].copy_from_slice(&(input.len()as u32).to_le_bytes());
            body[44..48].copy_from_slice(&output.to_le_bytes());
            body[48..52].copy_from_slice(&1u32.to_le_bytes());body[56..].copy_from_slice(input);body
        }
        let policy=SelectedActionPolicy::new();let source=FileId{persistent:3,volatile:4};
        let stage=FileId{persistent:5,volatile:6};policy.begin(TreeId(1),7).unwrap();
        policy.expect(Expected::Open(vec![65,0],OpenKind::CopySource)).unwrap();policy.opened(source).unwrap();
        let resume=ioctl_body(source,FSCTL_SRV_REQUEST_RESUME_KEY,&[],32);
        assert!(!policy.permits_frame(&frame(11,&resume)));
        policy.expect(Expected::Ioctl(source,FSCTL_SRV_REQUEST_RESUME_KEY,vec![],32)).unwrap();
        assert!(policy.permits_frame(&frame(11,&resume)));
        let mut wrong=resume.clone();wrong[4]^=1;assert!(!policy.permits_frame(&frame(11,&wrong)));
        wrong=resume.clone();wrong[44]=12;assert!(!policy.permits_frame(&frame(11,&wrong)));
        wrong=resume.clone();wrong[8]^=1;assert!(!policy.permits_frame(&frame(11,&wrong)));
        policy.acknowledged().unwrap();assert!(!policy.permits_frame(&frame(11,&resume)));
        policy.expect(Expected::Open(vec![66,0],OpenKind::CopyStage)).unwrap();policy.opened(stage).unwrap();
        let mut input=vec![0x42;24];input.extend_from_slice(&1u32.to_le_bytes());input.extend_from_slice(&0u32.to_le_bytes());
        input.extend_from_slice(&0u64.to_le_bytes());input.extend_from_slice(&0u64.to_le_bytes());
        input.extend_from_slice(&128u32.to_le_bytes());input.extend_from_slice(&0u32.to_le_bytes());
        let body=ioctl_body(stage,FSCTL_SRV_COPYCHUNK,&input,12);
        policy.expect(Expected::Ioctl(stage,FSCTL_SRV_COPYCHUNK,input,12)).unwrap();
        assert!(policy.permits_frame(&frame(11,&body)));
        for at in [4,8,24,28,44,48,56,80,104,111]{
            let mut wrong=body.clone();wrong[at]^=1;assert!(!policy.permits_frame(&frame(11,&wrong)),"{at}");
        }
        assert!(!policy.permits_frame(&frame(9,&body)));
        let mut wrong_tree=frame(11,&body);wrong_tree[36]=2;assert!(!policy.permits_frame(&wrong_tree));
        policy.acknowledged().unwrap();
        let mut flush=vec![0;24];flush[..2].copy_from_slice(&24u16.to_le_bytes());
        flush[8..16].copy_from_slice(&stage.persistent.to_le_bytes());
        flush[16..24].copy_from_slice(&stage.volatile.to_le_bytes());
        policy.expect(Expected::Flush(stage)).unwrap();assert!(policy.permits_frame(&frame(7,&flush)));
        flush[8]^=1;assert!(!policy.permits_frame(&frame(7,&flush)));
    }
    #[cfg_attr(test,test)]pub(super) fn only_held_exact_delete_frame_has_mutation_authority(){
        let policy=SelectedActionPolicy::new();let id=FileId{persistent:3,volatile:4};
        let mut body=vec![0;33];body[..2].copy_from_slice(&33u16.to_le_bytes());
        body[2]=1;body[3]=13;body[4..8].copy_from_slice(&1u32.to_le_bytes());
        body[8..10].copy_from_slice(&96u16.to_le_bytes());
        body[16..24].copy_from_slice(&id.persistent.to_le_bytes());
        body[24..32].copy_from_slice(&id.volatile.to_le_bytes());body[32]=1;
        assert!(!policy.permits_frame(&frame(17,&body)));
        policy.begin(TreeId(1),7).unwrap();
        policy.expect(Expected::Open(vec![65,0],OpenKind::File)).unwrap();
        policy.opened(id).unwrap();
        assert!(!policy.permits_frame(&frame(17,&body)));
        policy.expect(Expected::Set(id,13,vec![1])).unwrap();
        assert!(policy.permits_frame(&frame(17,&body)));
        for at in [3,8,16,24,32]{let mut wrong=body.clone();wrong[at]^=1;assert!(!policy.permits_frame(&frame(17,&wrong)));}
        assert!(!policy.permits_frame(&frame(9,&body)));
        assert!(!policy.permits_frame(&frame(17,&body[..32])));
        policy.acknowledged().unwrap();assert!(!policy.permits_frame(&frame(17,&body)));
    }
    #[cfg_attr(test,test)]pub(super) fn root_open_needs_exact_empty_name_and_no_share_delete(){
        let policy=SelectedActionPolicy::new();policy.begin(TreeId(1),7).unwrap();
        policy.expect(Expected::Open(vec![],OpenKind::Directory)).unwrap();
        let mut body=vec![0;57];body[..2].copy_from_slice(&57u16.to_le_bytes());
        body[4..8].copy_from_slice(&2u32.to_le_bytes());
        body[24..28].copy_from_slice(&DIRECTORY_ACCESS.to_le_bytes());
        body[32..36].copy_from_slice(&1u32.to_le_bytes());
        body[36..40].copy_from_slice(&1u32.to_le_bytes());
        body[40..44].copy_from_slice(&DIRECTORY_OPTIONS.to_le_bytes());
        body[44..46].copy_from_slice(&120u16.to_le_bytes());
        assert!(policy.permits_frame(&frame(5,&body)));
        body[32]=5;assert!(!policy.permits_frame(&frame(5,&body)));
        body[32]=1;body[56]=1;assert!(!policy.permits_frame(&frame(5,&body)));
    }
    #[cfg_attr(test,test)]pub(super) fn rename_frame_retains_no_replace_and_exact_target(){
        let policy=SelectedActionPolicy::new();let id=FileId{persistent:3,volatile:4};
        policy.begin(TreeId(1),7).unwrap();
        policy.expect(Expected::Open(vec![65,0],OpenKind::File)).unwrap();
        policy.opened(id).unwrap();
        let buffer=super::super::tree::build_rename_info_buffer("Parent\\Target.txt",false);
        assert_eq!(buffer[0],0);assert_eq!(&buffer[1..16],&[0;15]);
        assert_eq!(u32_at(&buffer,16)as usize,buffer.len()-20);
        let mut body=vec![0;32+buffer.len()];
        body[..2].copy_from_slice(&33u16.to_le_bytes());body[2]=1;body[3]=10;
        body[4..8].copy_from_slice(&(buffer.len()as u32).to_le_bytes());
        body[8..10].copy_from_slice(&96u16.to_le_bytes());
        body[16..24].copy_from_slice(&id.persistent.to_le_bytes());
        body[24..32].copy_from_slice(&id.volatile.to_le_bytes());
        body[32..].copy_from_slice(&buffer);
        policy.expect(Expected::Set(id,10,buffer)).unwrap();
        assert!(policy.permits_frame(&frame(17,&body)));
        for at in [3,32,33,40,48,body.len()-1]{
            let mut wrong=body.clone();wrong[at]^=1;
            assert!(!policy.permits_frame(&frame(17,&wrong)));
        }
    }
}
