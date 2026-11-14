//! One opt-in, encrypted, staged new-file upload on the existing SMB session.
//! The plaintext gate is checked both before encryption and before submission.
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};
use sha2::{Digest, Sha256};
use crate::{Error, Result, client::{Connection, selected_action::SelectedActionPolicy, selected_edit::SelectedEditPolicy, selected_download::{self as d1, CheckedFileReader, FileSnapshot}, selected_folder_download::{self as f1, SelectedFolderPolicy}, selected_folder_upload::SelectedFolderUploadPolicy, write_pipe::WritePipe},
    msg::{create::{CreateAction, CreateDisposition, CreateRequest, CreateResponse, ImpersonationLevel, ShareAccess},
        close::CloseRequest, flush::FlushRequest, query_info::{InfoType, QueryInfoRequest}, read::ReadRequest, set_info::SetInfoRequest},
    pack::{ReadCursor, Unpack}, types::{Command, FileId, OplockLevel, TreeId, flags::{FileAccessMask, FileAttributes}, status::NtStatus}};

pub const CHUNK: u32 = 32768;
pub const MAX_FILE: u64 = 1 << 30;
const STAGE_ACCESS: u32 = FileAccessMask::FILE_READ_DATA | FileAccessMask::FILE_WRITE_DATA |
    FileAccessMask::FILE_READ_ATTRIBUTES | FileAccessMask::DELETE | FileAccessMask::SYNCHRONIZE;
const CHILD_ACCESS: u32 = STAGE_ACCESS & !FileAccessMask::DELETE;
const FILE_OPTIONS: u32 = 0x0020_0040; // FILE_OPEN_REPARSE_POINT | FILE_NON_DIRECTORY_FILE.
fn invalid() -> Error { Error::invalid_data("Selected SMB upload refused") }
fn u16_at(v: &[u8], n: usize) -> u16 { u16::from_le_bytes(v[n..n+2].try_into().unwrap()) }
fn u32_at(v: &[u8], n: usize) -> u32 { u32::from_le_bytes(v[n..n+4].try_into().unwrap()) }
fn u64_at(v: &[u8], n: usize) -> u64 { u64::from_le_bytes(v[n..n+8].try_into().unwrap()) }
fn same_id(v: &[u8], n: usize, id: FileId) -> bool { u64_at(v,n)==id.persistent && u64_at(v,n+8)==id.volatile }
fn valid_id(id: FileId) -> bool { id!=FileId::default() && id.persistent!=u64::MAX && id.volatile!=u64::MAX }
fn exact_path(path: &[u16]) -> bool { !path.is_empty() && path.len()<=2048 && path.split(|v| *v==92).all(f1::safe_remote_component) }
fn distinct_name(stage: &[u16], final_name: &[u16]) -> bool {
    match (String::from_utf16(stage), String::from_utf16(final_name)) {
        (Ok(stage), Ok(final_name)) => !stage.eq_ignore_ascii_case(&final_name)
            && !final_name.to_ascii_lowercase().starts_with(".traverse-smb-upload-"),
        _ => false,
    }
}
fn published_attributes_match(stage_path: &[u16], final_path: &[u16], stage: u32, final_: u32) -> bool {
    if stage == final_ { return true; }
    let stage_name = stage_path.rsplit(|unit| *unit == 92).next().unwrap_or(&[]);
    let final_name = final_path.rsplit(|unit| *unit == 92).next().unwrap_or(&[]);
    // Samba can derive HIDDEN from the private stage's leading dot. Its
    // removal on rename is the only expected DOS attribute transition.
    final_name.first() != Some(&46u16)
        && String::from_utf16(stage_name).is_ok_and(|name| name.starts_with(".traverse-smb-upload-") && name.ends_with(".part"))
        && stage & FileAttributes::HIDDEN != 0
        && final_ == (stage & !FileAttributes::HIDDEN)
}
fn joined(parent: &[u16], child: &[u16]) -> Vec<u16> {
    let mut out=parent.to_vec(); if !out.is_empty() { out.push(92); } out.extend_from_slice(child); out
}

#[derive(Clone,Copy,PartialEq,Eq)]
enum UploadMode { SeparateStage, PrivateFolderChild }
impl UploadMode {
    fn access(self) -> u32 { match self { Self::SeparateStage => STAGE_ACCESS, Self::PrivateFolderChild => CHILD_ACCESS } }
}
#[derive(Clone)]
enum Expected { Create(Vec<u8>), Held, Write(u64,Vec<u8>), Flush, Query(u8,u8,u32), Read(u64,u32), Rename(Vec<u8>), Close, VerifyFinal(Vec<u8>) }
enum State { Idle, Active { tree: u32, session: u64, file: Option<FileId>, mode: UploadMode, expected: Expected }, Poisoned }

/// Owns the single upload handle while delegating idle B2/D1/F1 reads to the
/// existing folder policy. It grants no write when another transfer is active.
pub struct SelectedUploadPolicy { state: Mutex<State>, attached: AtomicBool, folder: Arc<SelectedFolderPolicy>, folder_write: Arc<SelectedFolderUploadPolicy>, action: Arc<SelectedActionPolicy>, edit: Arc<SelectedEditPolicy> }
impl SelectedUploadPolicy {
    pub fn new() -> Arc<Self> { let folder=SelectedFolderPolicy::new(); let edit=SelectedEditPolicy::new(folder.file_policy()); Arc::new(Self { state: Mutex::new(State::Idle), attached: AtomicBool::new(false), folder, folder_write: SelectedFolderUploadPolicy::new(), action: SelectedActionPolicy::new(), edit }) }
    pub(crate) fn claim(&self) -> Result<()> { self.attached.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).map(|_|()).map_err(|_|invalid()) }
    pub(crate) fn folder_policy(&self) -> Arc<SelectedFolderPolicy> { Arc::clone(&self.folder) }
    pub(crate) fn folder_write_policy(&self) -> Arc<SelectedFolderUploadPolicy> { Arc::clone(&self.folder_write) }
    pub(crate) fn begin_action(&self,tree:TreeId,session:u64)->Result<Arc<SelectedActionPolicy>>{
        let held=self.state.lock().unwrap();
        if !matches!(*held,State::Idle)||!self.folder.idle()||self.folder_write.active()||self.folder_write.probing()||!self.edit.idle(){return Err(invalid());}
        self.action.begin(tree,session)?;Ok(Arc::clone(&self.action))
    }
    pub(crate) fn begin_folder(&self, tree:TreeId, session:u64, stage:&[u16]) -> Result<()> {
        let held=self.state.lock().unwrap();
        if !matches!(*held,State::Idle) || !self.folder.idle() || !self.action.idle() || !self.edit.idle() {return Err(invalid());}
        self.folder_write.begin(tree,session,stage)
    }
    pub(crate) fn begin_edit(&self,tree:TreeId,session:u64,path:&[u16])->Result<Arc<SelectedEditPolicy>>{
        let held=self.state.lock().unwrap();
        if !matches!(*held,State::Idle)||!self.folder.idle()||self.folder_write.active()||self.folder_write.probing()||!self.action.idle(){return Err(invalid());}
        self.edit.begin(tree,session,path)?;Ok(Arc::clone(&self.edit))
    }
    pub(crate) fn allows_command(&self, code: usize) -> bool {
        match &*self.state.lock().unwrap() {
            State::Idle => if !self.edit.idle() { self.edit.allows_command(code) }
                else if !self.action.idle() { self.action.allows_command(code) }
                else if self.folder_write.probing() { self.folder.allows_command(code) }
                else if self.folder_write.active() { self.folder_write.allows_command(code) }
                else { self.folder.allows_command(code) }, State::Poisoned => false,
            State::Active { expected, .. } => matches!(code,2|4|12|13) || match expected {
                Expected::Create(_) => code==5, Expected::Held => false, Expected::Write(..) => code==9,
                Expected::Flush => code==7, Expected::Query(..) => code==16, Expected::Read(..) => code==8,
                Expected::Rename(_) => code==17, Expected::Close => code==6,
                Expected::VerifyFinal(_) => self.folder.file_policy().allows_command(code),
            }
        }
    }
    pub fn permits_frame(&self, raw: &[u8]) -> bool {
        if !(64..=256*1024).contains(&raw.len()) || !raw.starts_with(b"\xfeSMB") || u16_at(raw,4)!=64 || u32_at(raw,20)!=0 { return false; }
        let held=self.state.lock().unwrap();
        let (tree,session,file,mode,expected)=match &*held {
            State::Idle => return if !self.edit.idle() { self.edit.permits_frame(raw) }
                else if !self.action.idle() { self.action.permits_frame(raw) }
                else if self.folder_write.probing() { self.folder.permits_frame(raw) }
                else if self.folder_write.active() { self.folder_write.permits_frame(raw) }
                else { self.folder.permits_frame(raw) }, State::Poisoned => return false,
            State::Active { tree,session,file,mode,expected } => (*tree,*session,*file,*mode,expected),
        };
        let code=u16_at(raw,12); if u32_at(raw,16)&!8!=0 || u64_at(raw,40)!=session { return false; }
        if matches!(code,2|4|12|13) { return raw.len()==68 && u16_at(raw,64)==4 && raw[66..68]==[0,0] && (code!=4 || u32_at(raw,36)==tree); }
        if u32_at(raw,36)!=tree { return false; }
        if let Expected::VerifyFinal(path)=expected {
            if code==5 && (raw.len()!=120+path.len() || raw.get(120..)!=Some(path.as_slice())) { return false; }
            return self.folder.file_policy().permits_frame(raw);
        }
        let body=&raw[64..];
        match (code,expected) {
            (5,Expected::Create(name)) => body.len()==56+name.len() && u16_at(body,0)==57 && body[2..4]==[0,0]
                && u32_at(body,4)==2 && body[8..24]==[0;16] && u32_at(body,24)==mode.access()
                && u32_at(body,28)==FileAttributes::NORMAL && u32_at(body,32)==0 && u32_at(body,36)==2
                && u32_at(body,40)==FILE_OPTIONS && u16_at(body,44)==120 && usize::from(u16_at(body,46))==name.len()
                && body[48..56]==[0;8] && body[56..]==*name,
            (9,Expected::Write(offset,bytes)) => body.len()==48+bytes.len() && u16_at(body,0)==49 && u16_at(body,2)==112
                && u32_at(body,4)==bytes.len() as u32 && u64_at(body,8)==*offset && file.is_some_and(|id|same_id(body,16,id))
                && body[32..48]==[0;16] && body[48..]==*bytes,
            (7,Expected::Flush) => body.len()==24 && u16_at(body,0)==24 && body[2..8]==[0;6]
                && file.is_some_and(|id|same_id(body,8,id)),
            (16,Expected::Query(info,class,cap)) => body.len()==40 && u16_at(body,0)==41 && body[2]==*info && body[3]==*class
                && u32_at(body,4)==*cap && body[8..24]==[0;16] && file.is_some_and(|id|same_id(body,24,id)),
            (8,Expected::Read(offset,length)) => *length>0 && *length<=CHUNK && body.len()==49 && u16_at(body,0)==49
                && body[2..4]==[0;2] && u32_at(body,4)==*length && u64_at(body,8)==*offset
                && body[32..]==[0;17] && file.is_some_and(|id|same_id(body,16,id)),
            (17,Expected::Rename(buffer)) => body.len()==32+buffer.len() && u16_at(body,0)==33 && body[2]==1 && body[3]==10
                && u32_at(body,4)==buffer.len() as u32 && u16_at(body,8)==96 && body[10..16]==[0;6]
                && file.is_some_and(|id|same_id(body,16,id)) && body[32..]==*buffer,
            (6,Expected::Close) => body.len()==24 && u16_at(body,0)==24 && body[2..8]==[0;6]
                && file.is_some_and(|id|same_id(body,8,id)), _ => false,
        }
    }
    fn begin(&self, tree:TreeId, session:u64, stage:&[u16], mode:UploadMode) -> Result<()> {
        if tree.0==0 || session==0 || !exact_path(stage) { return Err(invalid()); }
        let mut held=self.state.lock().unwrap();
        if !matches!(*held,State::Idle) || !self.folder.idle() || !self.action.idle() || !self.edit.idle()
            || match mode {
                UploadMode::SeparateStage => self.folder_write.active(),
                UploadMode::PrivateFolderChild => !self.folder_write.child_stage_permitted(stage),
            } { return Err(invalid()); }
        let name=stage.iter().flat_map(|v|v.to_le_bytes()).collect();
        *held=State::Active{tree:tree.0,session,file:None,mode,expected:Expected::Create(name)}; Ok(())
    }
    fn opened(&self,id:FileId)->Result<()> {
        let mut held=self.state.lock().unwrap();
        match &mut *held { State::Active{file,expected:Expected::Create(_),..} if valid_id(id) => { *file=Some(id); if let State::Active{expected,..}=&mut *held {*expected=Expected::Held;} Ok(()) }, _=>Err(invalid()) }
    }
    fn expect(&self,next:Expected)->Result<()> {
        let mut held=self.state.lock().unwrap();
        match &mut *held { State::Active{file:Some(_),mode,expected,..} if matches!(*expected,Expected::Held)
            && !(matches!(next,Expected::Rename(_)) && *mode==UploadMode::PrivateFolderChild)
            => {*expected=next;Ok(())}, _=>Err(invalid()) }
    }
    fn acknowledged(&self)->Result<()> {
        let mut held=self.state.lock().unwrap();
        match &mut *held { State::Active{expected,..} if matches!(*expected,Expected::Write(..)|Expected::Flush|Expected::Query(..)|Expected::Read(..)|Expected::Rename(..))=>{*expected=Expected::Held;Ok(())}, _=>Err(invalid()) }
    }
    fn close_stage(&self, final_path:Option<&[u16]>)->Result<()> {
        let mut held=self.state.lock().unwrap();
        match &mut *held { State::Active{expected:Expected::Close,..} => {
            if let Some(path)=final_path { let (tree,session,mode)=match &*held {State::Active{tree,session,mode,..}=>(*tree,*session,*mode),_=>unreachable!()};
                *held=State::Active{tree,session,file:None,mode,expected:Expected::VerifyFinal(path.iter().flat_map(|v|v.to_le_bytes()).collect())}; }
            else {*held=State::Idle;} Ok(()) }, _=>Err(invalid()) }
    }
    fn finish(&self)->Result<()> {
        let mut held=self.state.lock().unwrap();
        if !matches!(&*held,State::Active{expected:Expected::VerifyFinal(_),..}) || !self.folder.file_policy().idle() {return Err(invalid());}
        *held=State::Idle;Ok(())
    }
    fn collision(&self)->Result<()> {
        let mut held=self.state.lock().unwrap();
        if !matches!(&*held,State::Active{file:None,expected:Expected::Create(_),..}) {return Err(invalid());}
        *held=State::Idle;Ok(())
    }
    fn poison(&self) { *self.state.lock().unwrap()=State::Poisoned; }
}

/// The only API that can grant the upload policy's active write authority.
/// Drop after any uncertain request closes the complete connection, not just a
/// guessed pathname. The stage is never removed automatically.
pub struct CheckedStagedUpload {
    conn:Connection, policy:Arc<SelectedUploadPolicy>, tree:TreeId, session:u64, file:Option<FileId>,
    stage:Vec<u16>, final_path:Vec<u16>, mode:UploadMode, size:u64, written:u64, ended:bool,
}
pub enum Publication { Complete, FinalCollision }
impl CheckedStagedUpload {
    pub async fn create(conn:Connection,tree:TreeId,parent:&[u16],stage:&[u16],name:&[u16],size:u64)->Result<Self>{
        if size>MAX_FILE || parent.len()>1920 || (!parent.is_empty()&&!exact_path(parent))
            || !f1::safe_remote_component(stage) || !f1::safe_remote_component(name) || !distinct_name(stage,name)
            || !String::from_utf16(stage).is_ok_and(|s|s.starts_with(".traverse-smb-upload-")&&s.ends_with(".part"))
            {return Err(invalid());}
        let stage=joined(parent,stage);let final_path=joined(parent,name);
        if !exact_path(&stage)||!exact_path(&final_path) {return Err(invalid());}
        Self::open_new(conn,tree,stage,final_path,size,UploadMode::SeparateStage).await
    }
    /// A child is born at its final relative name only inside F2's private
    /// root. The outer folder has the sole publication Rename.
    pub async fn create_private_child(conn:Connection,tree:TreeId,parent:&[u16],name:&[u16],size:u64)->Result<Self>{
        if size>MAX_FILE || parent.len()>1920 || !exact_path(parent) || !f1::safe_remote_component(name)
            || String::from_utf16(name).is_ok_and(|s|s.to_ascii_lowercase().starts_with(".traverse-smb-upload-")) {
            return Err(invalid());
        }
        let path=joined(parent,name);
        if !exact_path(&path) { return Err(invalid()); }
        Self::open_new(conn,tree,path.clone(),path,size,UploadMode::PrivateFolderChild).await
    }
    async fn open_new(conn:Connection,tree:TreeId,stage:Vec<u16>,final_path:Vec<u16>,size:u64,mode:UploadMode)->Result<Self>{
        let policy=conn.selected_upload_policy()?;let session=conn.session_id().0;policy.begin(tree,session,&stage,mode)?;
        let mut out=Self{conn,policy,tree,session,file:None,stage,final_path,mode,size,written:0,ended:false};
        let request=CreateRequest{requested_oplock_level:OplockLevel::None,impersonation_level:ImpersonationLevel::Impersonation,
            desired_access:FileAccessMask::new(mode.access()),file_attributes:FileAttributes::NORMAL,share_access:ShareAccess(0),
            create_disposition:CreateDisposition::FileCreate,create_options:FILE_OPTIONS,
            name:String::from_utf16(&out.stage).map_err(|_|invalid())?,create_contexts:vec![]};
        let frame=out.conn.execute(Command::Create,&request,Some(tree)).await?;
        let raw=d1::response(&frame,Command::Create,tree,session)?;
        if frame.header.status==NtStatus::OBJECT_NAME_COLLISION {
            out.policy.collision()?;out.ended=true;return Err(Error::Protocol{status:frame.header.status,command:Command::Create});
        }
        d1::success(&frame)?;
        if raw.len()!=152||u16_at(raw,64)!=89||raw[66..68]!=[0,0]||u32_at(raw,144)!=0||u32_at(raw,148)!=0{return Err(invalid());}
        let created=CreateResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        if created.create_action!=CreateAction::FileCreated || !valid_id(created.file_id)
            || created.file_attributes&0x450!=0 || created.end_of_file!=0 {return Err(invalid());}
        out.policy.opened(created.file_id)?;out.file=Some(created.file_id);Ok(out)
    }
    fn handle(&self)->Result<FileId>{self.file.ok_or_else(invalid)}
    pub fn maximum_chunk(&self)->Result<u32>{Ok(self.conn.params().ok_or_else(invalid)?.max_write_size.min(CHUNK).max(1))}
    pub fn written(&self)->u64{self.written}
    pub async fn write_chunk(&mut self,bytes:Vec<u8>)->Result<()> {
        let n=bytes.len();if n==0||n>self.maximum_chunk()? as usize||self.written.checked_add(n as u64).is_none_or(|end|end>self.size){return Err(invalid());}
        self.policy.expect(Expected::Write(self.written,bytes.clone()))?;
        let mut pipe=WritePipe::new(self.conn.clone(),self.tree,self.handle()?,self.maximum_chunk()?);
        pipe.set_chunk_size(self.maximum_chunk()?);pipe.set_offset(self.written);
        pipe.send(bytes).await?;pipe.drain().await?;
        if pipe.confirmed()!=n as u64 || pipe.offset()!=self.written+n as u64 {return Err(invalid());}
        self.policy.acknowledged()?;self.written+=n as u64;Ok(())
    }
    pub async fn flush(&mut self)->Result<()> {
        if self.written!=self.size {return Err(invalid());}self.policy.expect(Expected::Flush)?;
        let frame=self.conn.execute(Command::Flush,&FlushRequest{file_id:self.handle()?},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Flush,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=68||u16_at(raw,64)!=4||raw[66..68]!=[0,0]{return Err(invalid());}
        self.policy.acknowledged()
    }
    async fn query(&mut self,info:u8,class:u8,cap:u32)->Result<Vec<u8>> {
        self.policy.expect(Expected::Query(info,class,cap))?;
        let request=QueryInfoRequest{info_type:if info==1{InfoType::File}else{InfoType::Filesystem},file_info_class:class,
            output_buffer_length:cap,additional_information:0,flags:0,file_id:self.handle()?,input_buffer:vec![]};
        let frame=self.conn.execute(Command::QueryInfo,&request,Some(self.tree)).await?;
        let data=d1::query_bytes(&frame,cap,self.tree,self.session)?.to_vec();self.policy.acknowledged()?;Ok(data)
    }
    async fn observe(&mut self)->Result<FileSnapshot> {
        let basic=self.query(1,4,40).await?;let standard=self.query(1,5,24).await?;
        let internal=self.query(1,6,8).await?;let volume=self.query(2,1,1042).await?;
        if basic.len()!=40||standard.len()!=24||internal.len()!=8||volume.len()<18{return Err(invalid());}
        let size=u64_at(&standard,8);let attrs=u32_at(&basic,32);let index=u64_at(&internal,0);let serial=u32_at(&volume,8);
        let label=u32_at(&volume,12) as usize;
        if size!=self.size||attrs&0x450!=0||index==0||index==u64::MAX||serial==0||u32_at(&standard,16)==0
            || standard[20..22]!=[0,0]||volume[16]>1||label%2!=0||label>1024||18+label!=volume.len(){return Err(invalid());}
        Ok(FileSnapshot{size,allocated:u64_at(&standard,0),created:u64_at(&basic,0),modified:u64_at(&basic,16),changed:u64_at(&basic,24),
            attributes:attrs,links:u32_at(&standard,16),index,volume_created:u64_at(&volume,0),volume_serial:serial})
    }
    async fn read(&mut self,offset:u64,length:u32)->Result<Option<Vec<u8>>> {
        if length==0||length>CHUNK||length>self.conn.params().ok_or_else(invalid)?.max_read_size{return Err(invalid());}
        self.policy.expect(Expected::Read(offset,length))?;
        let request=ReadRequest{padding:0,flags:0,length,offset,file_id:self.handle()?,minimum_count:0,channel:0,remaining_bytes:0,read_channel_info:vec![]};
        let frame=self.conn.execute(Command::Read,&request,Some(self.tree)).await?;
        let data=d1::read_bytes(&frame,length,self.tree,self.session)?;self.policy.acknowledged()?;Ok(data)
    }
    /// Independently read the staged bytes through the held handle, then
    /// require exact EOF and stable file identity before asking for publication.
    pub async fn verify_stage(&mut self,digest:&[u8;32])->Result<FileSnapshot> {
        if self.written!=self.size{return Err(invalid());}
        let before=self.observe().await?;let mut hash=Sha256::new();let mut offset=0;
        while offset<self.size {
            let length=(self.size-offset).min(CHUNK as u64).min(self.conn.params().ok_or_else(invalid)?.max_read_size as u64) as u32;
            let bytes=self.read(offset,length).await?.ok_or_else(invalid)?;
            if bytes.is_empty(){return Err(invalid());}offset+=bytes.len() as u64;hash.update(&bytes);
        }
        if self.read(self.size,1).await?.is_some(){return Err(invalid());}
        let after=self.observe().await?;
        if before.index!=after.index||before.volume_serial!=after.volume_serial||before.size!=after.size||before.attributes!=after.attributes
            || hash.finalize().as_slice()!=digest{return Err(invalid());}
        Ok(after)
    }
    async fn close_stage(&mut self,final_check:bool)->Result<()> {
        self.policy.expect(Expected::Close)?;
        let frame=self.conn.execute(Command::Close,&CloseRequest{flags:0,file_id:self.handle()?},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Close,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=124||u16_at(raw,64)!=60||u16_at(raw,66)!=0{return Err(invalid());}
        self.policy.close_stage(if final_check{Some(&self.final_path)}else{None})?;self.file=None;Ok(())
    }
    /// Only the caller's durable publication-intent ACK may invoke this.
    pub async fn publish(mut self,stage:FileSnapshot,digest:&[u8;32])->Result<Publication> {
        if self.mode!=UploadMode::SeparateStage{return Err(invalid());}
        let dest=String::from_utf16(&self.final_path).map_err(|_|invalid())?;
        let buffer=super::tree::build_rename_info_buffer(&dest,false);
        self.policy.expect(Expected::Rename(buffer.clone()))?;
        let request=SetInfoRequest{info_type:InfoType::File,file_info_class:10,additional_information:0,file_id:self.handle()?,buffer};
        let frame=self.conn.execute(Command::SetInfo,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::SetInfo,self.tree,self.session)?;
        if frame.header.status==NtStatus::OBJECT_NAME_COLLISION {
            // A server-confirmed no-replace collision leaves the stage alone.
            self.policy.acknowledged()?;self.close_stage(false).await?;self.ended=true;return Ok(Publication::FinalCollision);
        }
        d1::success(&frame)?;if raw.len()!=66||u16_at(raw,64)!=2{return Err(invalid());}
        self.policy.acknowledged()?;
        let after=self.observe().await?;
        if after.index!=stage.index||after.volume_serial!=stage.volume_serial||after.size!=stage.size
            ||!published_attributes_match(&self.stage,&self.final_path,stage.attributes,after.attributes){return Err(invalid());}
        self.confirm_final(after,digest).await?;Ok(Publication::Complete)
    }
    /// Finish a verified private child without any per-file Rename. Full
    /// readback after CLOSE still guards its identity and content.
    pub async fn finish_private_child(mut self,stage:FileSnapshot,digest:&[u8;32])->Result<()> {
        if self.mode!=UploadMode::PrivateFolderChild{return Err(invalid());}
        let after=self.observe().await?;
        if after.index!=stage.index||after.volume_serial!=stage.volume_serial||after.size!=stage.size
            ||after.attributes!=stage.attributes{return Err(invalid());}
        self.confirm_final(after,digest).await
    }
    async fn confirm_final(&mut self,after:FileSnapshot,digest:&[u8;32])->Result<()> {
        self.close_stage(true).await?;
        let mut reader=CheckedFileReader::prepare_published(self.conn.clone(),self.tree,&self.final_path,&after).await?;
        if reader.snapshot().index!=after.index||reader.snapshot().volume_serial!=after.volume_serial
            ||reader.snapshot().size!=after.size||reader.snapshot().attributes!=after.attributes{return Err(invalid());}
        let mut hash=Sha256::new();let mut count=0;
        while count<self.size {let bytes=reader.read_chunk().await?;count+=bytes.len() as u64;hash.update(&bytes);}
        reader.finish().await?;
        if count!=self.size||hash.finalize().as_slice()!=digest{return Err(invalid());}
        self.policy.finish()?;self.ended=true;Ok(())
    }
}
impl Drop for CheckedStagedUpload {
    fn drop(&mut self) {if !self.ended {self.policy.poison();self.conn.mark_dead();}}
}

#[cfg(feature = "b12-qualification")]
#[path = "selected_upload_controls.rs"]
mod controls;

#[cfg(feature = "b12-qualification")]
/// Run generated, zero-network selected upload publication controls.
pub async fn qualification_run() -> Result<usize> { controls::run().await }
