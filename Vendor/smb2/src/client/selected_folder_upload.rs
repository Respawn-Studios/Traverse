//! F2's narrow directory authority. Every CREATE is exclusive, beneath an
//! open private root, and under a held direct parent; no path is removed.
use std::sync::{Arc, Mutex};
use crate::{Error, Result, client::{Connection, selected_download as d1, selected_folder_download as f1},
    msg::{create::{CreateAction, CreateDisposition, CreateRequest, CreateResponse, ImpersonationLevel, ShareAccess},
        close::CloseRequest, query_info::{InfoType,QueryInfoRequest}, set_info::SetInfoRequest}, pack::{ReadCursor, Unpack},
    types::{Command, FileId, OplockLevel, TreeId, flags::{FileAccessMask, FileAttributes}, status::NtStatus}};

const ACCESS: u32 = FileAccessMask::FILE_READ_DATA | FileAccessMask::FILE_READ_ATTRIBUTES
    | FileAccessMask::DELETE | FileAccessMask::SYNCHRONIZE; // READ_DATA is LIST_DIRECTORY on a directory.
const OPTIONS: u32 = 0x0020_0001; // FILE_OPEN_REPARSE_POINT | FILE_DIRECTORY_FILE.
fn invalid() -> Error { Error::invalid_data("Selected SMB folder upload refused") }
fn u16_at(v: &[u8], n: usize) -> u16 { u16::from_le_bytes(v[n..n+2].try_into().unwrap()) }
fn u32_at(v: &[u8], n: usize) -> u32 { u32::from_le_bytes(v[n..n+4].try_into().unwrap()) }
fn u64_at(v: &[u8], n: usize) -> u64 { u64::from_le_bytes(v[n..n+8].try_into().unwrap()) }
fn same_id(v: &[u8], n: usize, id: FileId) -> bool { u64_at(v,n)==id.persistent && u64_at(v,n+8)==id.volatile }
fn usable(id: FileId) -> bool { id!=FileId::default() && id.persistent!=u64::MAX && id.volatile!=u64::MAX }
fn exact_path(path: &[u16]) -> bool { !path.is_empty() && path.len()<=2048 && path.split(|v| *v==92).all(f1::safe_remote_component) }
fn child_of(parent: &[u16], child: &[u16]) -> bool {
    child.len()>parent.len()+1 && child.starts_with(parent) && child[parent.len()]==92
        && f1::safe_remote_component(&child[parent.len()+1..])
}
fn joined(parent: &[u16], child: &[u16]) -> Vec<u16> {
    let mut path=parent.to_vec(); path.push(92); path.extend_from_slice(child); path
}

#[derive(Clone)]
enum Expected { Create(Vec<u8>,Vec<u16>), Query(FileId,u8,u8,u32), Close(FileId), Rename(Vec<u8>), Probe, Held }
enum State { Idle, Active { tree:u32, session:u64, root:Vec<u16>, open:Vec<(FileId,Vec<u16>)>,
    expected:Expected, probed:bool }, Poisoned }

/// The outer selected-upload gate delegates to this only while a folder root
/// exists. U1 child file writes are separately checked by that outer gate.
pub(crate) struct SelectedFolderUploadPolicy { state: Mutex<State> }
impl SelectedFolderUploadPolicy {
    pub(crate) fn new() -> Arc<Self> { Arc::new(Self { state:Mutex::new(State::Idle) }) }
    pub(crate) fn active(&self) -> bool { matches!(*self.state.lock().unwrap(),State::Active{..}) }
    pub(crate) fn child_stage_permitted(&self,path:&[u16]) -> bool {
        match &*self.state.lock().unwrap() {
            State::Active{open,expected:Expected::Held,probed:false,..} => open.iter().any(|(_,parent)|child_of(parent,path)),
            _ => false,
        }
    }
    pub(crate) fn allows_command(&self,code:usize) -> bool {
        match &*self.state.lock().unwrap() {
            State::Active{expected,..} => matches!(code,2|4|12|13) || match expected {
                Expected::Create(..)=>code==5, Expected::Query(..)=>code==16, Expected::Close(..)=>code==6,
                Expected::Rename(..)=>code==17, Expected::Probe|Expected::Held=>false,
            }, _=>false,
        }
    }
    pub(crate) fn permits_frame(&self,raw:&[u8]) -> bool {
        if !(64..=256*1024).contains(&raw.len()) || !raw.starts_with(b"\xfeSMB") || u16_at(raw,4)!=64 || u32_at(raw,20)!=0 { return false; }
        let held=self.state.lock().unwrap();
        let (tree,session,expected)=match &*held { State::Active{tree,session,expected,..}=>(*tree,*session,expected),_=>return false };
        let code=u16_at(raw,12); if u32_at(raw,16)&!8!=0 || u64_at(raw,40)!=session { return false; }
        if matches!(code,2|4|12|13) { return raw.len()==68 && u16_at(raw,64)==4 && raw[66..68]==[0,0] && (code!=4 || u32_at(raw,36)==tree); }
        if u32_at(raw,36)!=tree { return false; }
        let body=&raw[64..];
        match (code,expected) {
            (5,Expected::Create(name,_)) => body.len()==56+name.len() && u16_at(body,0)==57 && body[2..4]==[0,0]
                && u32_at(body,4)==2 && body[8..24]==[0;16] && u32_at(body,24)==ACCESS
                && u32_at(body,28)==FileAttributes::DIRECTORY && u32_at(body,32)==0 && u32_at(body,36)==2
                && u32_at(body,40)==OPTIONS && u16_at(body,44)==120 && usize::from(u16_at(body,46))==name.len()
                && body[48..56]==[0;8] && body[56..]==*name,
            (16,Expected::Query(id,info,class,cap)) => body.len()==40 && u16_at(body,0)==41
                && body[2]==*info && body[3]==*class && u32_at(body,4)==*cap
                && body[8..24]==[0;16] && same_id(body,24,*id),
            (6,Expected::Close(id)) => body.len()==24 && u16_at(body,0)==24 && body[2..8]==[0;6] && same_id(body,8,*id),
            (17,Expected::Rename(buffer)) => body.len()==32+buffer.len() && u16_at(body,0)==33 && body[2]==1 && body[3]==10
                && u32_at(body,4)==buffer.len() as u32 && u16_at(body,8)==96 && body[10..16]==[0;6]
                && body[32..]==*buffer && match &*held { State::Active{open,..} => open.first().is_some_and(|(id,_)|same_id(body,16,*id)),_=>false },
            _=>false,
        }
    }
    pub(crate) fn begin(&self,tree:TreeId,session:u64,root:&[u16]) -> Result<()> {
        if tree.0==0 || session==0 || !exact_path(root) { return Err(invalid()); }
        let mut held=self.state.lock().unwrap(); if !matches!(*held,State::Idle) { return Err(invalid()); }
        *held=State::Active{tree:tree.0,session,root:root.to_vec(),open:Vec::new(),probed:false,
            expected:Expected::Create(root.iter().flat_map(|v|v.to_le_bytes()).collect(),root.to_vec())}; Ok(())
    }
    fn expect_child(&self,parent:&DirectoryHandle,path:&[u16]) -> Result<()> {
        let mut held=self.state.lock().unwrap();
        match &mut *held {
            State::Active{open,expected:Expected::Held,probed:false,..} if open.len()<34
                && open.iter().any(|(id,p)|*id==parent.id && *p==parent.path) && child_of(&parent.path,path) && exact_path(path) => {
                if let State::Active{expected,..}=&mut *held {
                    *expected=Expected::Create(path.iter().flat_map(|v|v.to_le_bytes()).collect(),path.to_vec());
                }
                Ok(())
            }, _=>Err(invalid()),
        }
    }
    fn opened(&self,id:FileId,path:&[u16]) -> Result<()> {
        let mut held=self.state.lock().unwrap(); match &mut *held {
            State::Active{open,expected,..} if usable(id) && matches!(&*expected,Expected::Create(_,wanted) if wanted==path) && open.len()<34
                && !open.iter().any(|(existing,_)|*existing==id) => { open.push((id,path.to_vec())); *expected=Expected::Held; Ok(()) }, _=>Err(invalid()),
        }
    }
    fn expect_query(&self,id:FileId,info:u8,class:u8,cap:u32)->Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{open,expected:Expected::Held,..}if open.iter().any(|(found,_)|*found==id)=>{
                if let State::Active{expected,..}=&mut *held{*expected=Expected::Query(id,info,class,cap);}Ok(())
            },_=>Err(invalid()),
        }
    }
    fn queried(&self)->Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{expected,..}if matches!(expected,Expected::Query(..))=>{*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    pub(crate) fn probing(&self)->bool {
        matches!(*self.state.lock().unwrap(),State::Active{expected:Expected::Probe,..})
    }
    fn begin_probe(&self,root:&DirectoryHandle)->Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{root:stage,open,expected:Expected::Held,probed:false,..}
                if *stage==root.path && open.len()==1 && open[0].0==root.id && open[0].1==root.path=>{
                if let State::Active{expected,..}=&mut *held{*expected=Expected::Probe;}Ok(())
            },_=>Err(invalid()),
        }
    }
    fn end_probe(&self)->Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{expected,probed,..}if matches!(expected,Expected::Probe)=>{
                *expected=Expected::Held;*probed=true;Ok(())},_=>Err(invalid()),
        }
    }
    fn collision(&self) -> Result<()> {
        let mut held=self.state.lock().unwrap(); match &*held {
            State::Active{open,expected:Expected::Create(..),..} if open.is_empty()=>{*held=State::Idle;Ok(())}, _=>Err(invalid()),
        }
    }
    fn expect_close(&self,handle:&DirectoryHandle) -> Result<()> {
        let mut held=self.state.lock().unwrap(); match &mut *held {
            State::Active{open,expected,..} if matches!(expected,Expected::Held) && open.last().is_some_and(|(id,p)|*id==handle.id && *p==handle.path)=>{
                *expected=Expected::Close(handle.id);Ok(())},_=>Err(invalid()),
        }
    }
    fn closed(&self,handle:&DirectoryHandle) -> Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{open,expected,..} if matches!(&*expected,Expected::Close(id) if *id==handle.id)
                && open.last().is_some_and(|(last,path)|*last==handle.id && *path==handle.path)=>{
                open.pop();*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn expect_rename(&self,root:&DirectoryHandle,buffer:Vec<u8>) -> Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{open,root:stage,expected,probed:true,..} if matches!(expected,Expected::Held) && open.len()==1
                && open[0].0==root.id && open[0].1==root.path && *stage==root.path=>{*expected=Expected::Rename(buffer);Ok(())},_=>Err(invalid()),
        }
    }
    fn renamed(&self) -> Result<()> {
        let mut held=self.state.lock().unwrap();match &mut *held {
            State::Active{expected,..} if matches!(expected,Expected::Rename(_))=>{*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn finish(&self) -> Result<()> {
        let mut held=self.state.lock().unwrap();match &*held {
            State::Active{open,expected:Expected::Held,..} if open.is_empty()=>{*held=State::Idle;Ok(())},_=>Err(invalid()),
        }
    }
    fn poison(&self) { *self.state.lock().unwrap()=State::Poisoned; }
}

/// One directory identity held with exclusive sharing until its subtree ends.
pub struct DirectoryHandle { id:FileId, path:Vec<u16> }
/// Server-provided filesystem identity, never an ephemeral SMB open FileId.
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct FolderIdentity { pub volume:u32, pub index:u64 }
impl From<&f1::DirectorySnapshot> for FolderIdentity {
    fn from(value:&f1::DirectorySnapshot)->Self{Self{volume:value.volume,index:value.index}}
}
/// The root rename's server-confirmed terminal result.
pub enum FolderPublication {
    /// No-replace rename was acknowledged.
    Complete(FolderIdentity),
    /// The final name already existed; the private stage remains.
    FinalCollision,
}
/// Owns one private root, its bounded held ancestry, and final no-replace
/// rename. A failure poisons the whole connection and leaves the stage alone.
pub struct CheckedStagedFolder { conn:Connection, policy:Arc<SelectedFolderUploadPolicy>, tree:TreeId,
    session:u64, root:Option<DirectoryHandle>, identity:Option<FolderIdentity>, final_path:Vec<u16>, ended:bool }
impl CheckedStagedFolder {
    async fn query(&self,id:FileId,info:u8,class:u8,cap:u32)->Result<Vec<u8>> {
        self.policy.expect_query(id,info,class,cap)?;
        let request=QueryInfoRequest{info_type:if info==1{InfoType::File}else{InfoType::Filesystem},
            file_info_class:class,output_buffer_length:cap,additional_information:0,flags:0,
            file_id:id,input_buffer:vec![]};
        let frame=self.conn.execute(Command::QueryInfo,&request,Some(self.tree)).await?;
        let bytes=d1::query_bytes(&frame,cap,self.tree,self.session)?.to_vec();self.policy.queried()?;Ok(bytes)
    }
    async fn observe(&self,id:FileId)->Result<f1::DirectorySnapshot> {
        let basic=self.query(id,1,4,40).await?;let standard=self.query(id,1,5,24).await?;
        let internal=self.query(id,1,6,8).await?;let volume=self.query(id,2,1,1042).await?;
        f1::directory_snapshot_from_queries(&basic,&standard,&internal,&volume)
    }
    /// Send one exclusive directory CREATE under the current policy grant.
    async fn open(&self,path:&[u16]) -> Result<DirectoryHandle> {
        let request=CreateRequest{requested_oplock_level:OplockLevel::None,impersonation_level:ImpersonationLevel::Impersonation,
            desired_access:FileAccessMask::new(ACCESS),file_attributes:FileAttributes::DIRECTORY,share_access:ShareAccess(0),
            create_disposition:CreateDisposition::FileCreate,create_options:OPTIONS,
            name:String::from_utf16(path).map_err(|_|invalid())?,create_contexts:vec![]};
        let frame=self.conn.execute(Command::Create,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Create,self.tree,self.session)?;
        if frame.header.status==NtStatus::OBJECT_NAME_COLLISION {return Err(Error::Protocol{status:frame.header.status,command:Command::Create});}
        d1::success(&frame)?;
        if raw.len()!=152 || u16_at(raw,64)!=89 || raw[66..68]!=[0,0] || u32_at(raw,144)!=0 || u32_at(raw,148)!=0 {return Err(invalid());}
        let created=CreateResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        if created.create_action!=CreateAction::FileCreated || !usable(created.file_id)
            || created.file_attributes&0x450!=0x10 || created.end_of_file!=0 {return Err(invalid());}
        self.policy.opened(created.file_id,path)?;
        Ok(DirectoryHandle{id:created.file_id,path:path.to_vec()})
    }
    /// Create a private sibling root exclusively under the selected parent.
    pub async fn create(conn:Connection,tree:TreeId,parent:&[u16],stage:&[u16],name:&[u16]) -> Result<Self> {
        if (!parent.is_empty() && !exact_path(parent)) || !f1::safe_remote_component(stage)
            || !f1::safe_remote_component(name) || !String::from_utf16(stage).is_ok_and(|s|s.starts_with(".traverse-smb-upload-") && s.ends_with(".part"))
            || String::from_utf16(name).is_ok_and(|s|s.to_ascii_lowercase().starts_with(".traverse-smb-upload-")) {return Err(invalid());}
        let root=if parent.is_empty(){stage.to_vec()}else{joined(parent,stage)};
        let final_path=if parent.is_empty(){name.to_vec()}else{joined(parent,name)};
        if !exact_path(&root)||!exact_path(&final_path)||root==final_path {return Err(invalid());}
        let outer=conn.selected_upload_policy()?;let policy=outer.folder_write_policy();let session=conn.session_id().0;
        outer.begin_folder(tree,session,&root)?;
        let mut owner=Self{conn,policy,tree,session,root:None,identity:None,final_path,ended:false};
        match owner.open(&root).await {
            Ok(handle)=>{
                let snapshot=owner.observe(handle.id).await?;
                owner.identity=Some(FolderIdentity::from(&snapshot));owner.root=Some(handle);Ok(owner)
            },
            Err(Error::Protocol{status,command}) if status==NtStatus::OBJECT_NAME_COLLISION && command==Command::Create=>{
                owner.policy.collision()?;owner.ended=true;Err(Error::Protocol{status,command})
            },Err(error)=>Err(error),
        }
    }
    /// Borrow the held root identity for a direct child operation.
    pub fn root(&self) -> Result<&DirectoryHandle> {self.root.as_ref().ok_or_else(invalid)}
    /// Create a new directory directly beneath one held parent.
    pub async fn create_child(&self,parent:&DirectoryHandle,name:&[u16]) -> Result<DirectoryHandle> {
        if !f1::safe_remote_component(name){return Err(invalid());}
        let path=joined(&parent.path,name);self.policy.expect_child(parent,&path)?;self.open(&path).await
    }
    /// Close the most recently opened child after its subtree is complete.
    pub async fn close_child(&self,handle:DirectoryHandle) -> Result<()> {
        self.policy.expect_close(&handle)?;
        let frame=self.conn.execute(Command::Close,&CloseRequest{flags:0,file_id:handle.id},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Close,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=124 || u16_at(raw,64)!=60 || u16_at(raw,66)!=0 {return Err(invalid());}
        self.policy.closed(&handle)
    }
    /// The exact share-relative path used by the checked child file writer.
    pub fn path(&self,parent:&DirectoryHandle) -> Vec<u16> {parent.path.clone()}
    /// Re-enumerate the held private root and all descendants through F1's
    /// checked metadata policy. Its own root FileId is borrowed, not reopened
    /// or closed; all descendant opens close before publication is granted.
    pub async fn inspect_stage(&self)->Result<Vec<f1::FolderNode>> {
        let root=self.root.as_ref().ok_or_else(invalid)?;
        let identity=self.identity.ok_or_else(invalid)?;
        let current=self.observe(root.id).await?;
        if FolderIdentity::from(&current)!=identity{return Err(invalid());}
        self.policy.begin_probe(root)?;
        let prepared=f1::PreparedFolder::prepare_borrowed(self.conn.clone(),self.tree,&root.path,root.id,current).await?;
        if prepared.root_identity()!=Some((identity.volume,identity.index)){return Err(invalid());}
        let nodes=prepared.nodes().to_vec();prepared.release().await?;
        self.policy.end_probe()?;Ok(nodes)
    }
    /// Rename the held root without replacement, then close it.
    pub async fn publish(mut self) -> Result<FolderPublication> {
        let root=self.root.as_ref().ok_or_else(invalid)?;
        let identity=self.identity.ok_or_else(invalid)?;
        if FolderIdentity::from(&self.observe(root.id).await?)!=identity{return Err(invalid());}
        let dest=String::from_utf16(&self.final_path).map_err(|_|invalid())?;
        let buffer=super::tree::build_rename_info_buffer(&dest,false);
        self.policy.expect_rename(root,buffer.clone())?;
        let request=SetInfoRequest{info_type:crate::msg::query_info::InfoType::File,file_info_class:10,
            additional_information:0,file_id:root.id,buffer};
        let frame=self.conn.execute(Command::SetInfo,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::SetInfo,self.tree,self.session)?;
        let outcome=if frame.header.status==NtStatus::OBJECT_NAME_COLLISION {FolderPublication::FinalCollision}
            else {d1::success(&frame)?;if raw.len()!=66 || u16_at(raw,64)!=2 {return Err(invalid());}
                FolderPublication::Complete(identity)};
        self.policy.renamed()?;
        if matches!(&outcome,FolderPublication::Complete(_))
            && FolderIdentity::from(&self.observe(root.id).await?)!=identity{return Err(invalid());}
        let root=self.root.take().ok_or_else(invalid)?;self.close_child(root).await?;
        self.policy.finish()?;self.ended=true;Ok(outcome)
    }
}
impl Drop for CheckedStagedFolder {fn drop(&mut self){if !self.ended{self.policy.poison();self.conn.mark_dead();}}}
