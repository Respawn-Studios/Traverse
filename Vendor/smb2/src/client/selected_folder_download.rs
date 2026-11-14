//! Explicit F1 folder authority. Metadata browsing never starts a tree read.
use std::sync::{Arc,Mutex,atomic::{AtomicBool,AtomicU64,Ordering}};
use crate::{Error,Result,client::{Connection,selected_download as d1},pack::{Pack,WriteCursor,ReadCursor,Unpack},
    msg::{create::{CreateResponse,CreateAction},close::CloseRequest,query_info::{QueryInfoRequest,InfoType},
        query_directory::{QueryDirectoryRequest,QueryDirectoryFlags,FileInformationClass},directory_info::{parse_entries,DirectoryInfoEntry}},
    types::{Command,FileId,TreeId}};
const MAX_HANDLES:usize=34;
/// Maximum regular files in one explicitly admitted tree.
pub const MAX_FILES:usize=1024;
/// Maximum nodes including the selected root.
pub const MAX_NODES:usize=2048;
/// Maximum relative child depth.
pub const MAX_DEPTH:usize=32;
/// One selected download tree stays inside its bounded body spool.
pub const MAX_BYTES:u64=256<<20;
const PUBLISHED_UPLOAD_MAX_BYTES:u64=1<<30;
fn invalid()->Error{Error::invalid_data("Selected SMB folder download refused")}
fn u16_at(v:&[u8],n:usize)->u16{u16::from_le_bytes(v[n..n+2].try_into().unwrap())}
fn u32_at(v:&[u8],n:usize)->u32{u32::from_le_bytes(v[n..n+4].try_into().unwrap())}
fn u64_at(v:&[u8],n:usize)->u64{u64::from_le_bytes(v[n..n+8].try_into().unwrap())}
fn same_id(v:&[u8],at:usize,id:FileId)->bool{u64_at(v,at)==id.persistent&&u64_at(v,at+8)==id.volatile}
fn usable(id:FileId)->bool{id!=FileId::default()&&id.persistent!=u64::MAX&&id.volatile!=u64::MAX}
fn safe_path(path:&[u16])->bool{!path.is_empty()&&path.len()<=2048&&path.split(|v|*v==92).all(safe_remote_component)}
pub(crate) fn safe_remote_component(name:&[u16])->bool{
    let Ok(text)=String::from_utf16(name)else{return false};
    !name.is_empty()&&name.len()<=255&&name!=[46]&&name!=[46,46]&&!matches!(name.last(),Some(32|46))
        &&!name.iter().any(|v|*v<32||matches!(*v,47|58|92|42|63|34|60|62|124))
        &&!text.chars().any(|c|c.is_control()||matches!(c as u32,0x061c|0x200e|0x200f|0x202a..=0x202e|0x2066..=0x2069))
}
fn safe_name(name:&[u16])->bool{safe_remote_component(name)&&String::from_utf16(name).is_ok_and(|v|v.len()<=255)}
#[derive(Clone)]
enum Expected{Held,Open(Vec<u8>),Query(FileId,u8,u8,u32),List(FileId,bool,u32),Close(FileId),Member{path:Vec<u8>,read:bool}}
enum State{Idle,Active{tree:u32,session:u64,handles:Vec<FileId>,expected:Expected},Poisoned}
/// One closed folder policy per connection, retaining D1's nested file guard.
pub struct SelectedFolderPolicy{state:Mutex<State>,attached:AtomicBool,serial:AtomicU64,file:Arc<d1::SelectedDownloadPolicy>}
impl SelectedFolderPolicy{
    /// No folder authority until an explicit prepared transaction starts.
    pub fn new()->Arc<Self>{Arc::new(Self{state:Mutex::new(State::Idle),attached:AtomicBool::new(false),serial:AtomicU64::new(0),file:d1::SelectedDownloadPolicy::new()})}
    pub(crate) fn claim(&self)->Result<()>{self.attached.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).map(|_|()).map_err(|_|invalid())}
    pub(crate) fn file_policy(&self)->Arc<d1::SelectedDownloadPolicy>{Arc::clone(&self.file)}
    pub(crate) fn idle(&self)->bool{matches!(*self.state.lock().unwrap(),State::Idle)&&self.file.idle()}
    /// Check the actual outbound plaintext before transport and encryption.
    pub fn permits_frame(&self,raw:&[u8])->bool{
        if !(64..=256*1024).contains(&raw.len())||!raw.starts_with(b"\xfeSMB")||u16_at(raw,4)!=64||u32_at(raw,20)!=0{return false;}
        let held=self.state.lock().unwrap();let(tree,session,expected)=match &*held{
            State::Idle=>return self.file.permits_frame(raw),State::Poisoned=>return false,
            State::Active{tree,session,expected,..}=>(*tree,*session,expected),
        };
        let command=u16_at(raw,12);if u32_at(raw,16)&!8!=0||u64_at(raw,40)!=session{return false;}
        if matches!(command,2|4|12|13){return raw.len()==68&&u16_at(raw,64)==4&&raw[66..68]==[0,0]&&(command!=4||u32_at(raw,36)==tree);}
        if u32_at(raw,36)!=tree{return false;}let body=&raw[64..];
        if let Expected::Member{path,read}=expected{
            // D1's successful CLOSE restores its inner Idle. The outer F1
            // authority never lets that reopen ordinary B2 metadata permission.
            if !self.file.active()||!self.file.permits_frame(raw){return false;}
            return match command{5=>body.len()==56+path.len()&&body.get(56..)==Some(path.as_slice()),8=>*read,6|16=>true,_=>false};
        }
        match(command,expected){
            (5,Expected::Open(path))=>body.len()==56+path.len()&&u16_at(body,0)==57&&body[2..4]==[0,0]
                &&u32_at(body,4)==2&&body[8..24]==[0;16]&&u32_at(body,24)==0x0010_0081&&u32_at(body,28)==0
                &&u32_at(body,32)==1&&u32_at(body,36)==1&&u32_at(body,40)==0x0020_0001
                &&u16_at(body,44)==120&&usize::from(u16_at(body,46))==path.len()&&body[48..56]==[0;8]&&body[56..]==*path,
            (16,Expected::Query(id,info,class,cap))=>body.len()==40&&u16_at(body,0)==41&&body[2]==*info&&body[3]==*class
                &&u32_at(body,4)==*cap&&body[8..24]==[0;16]&&same_id(body,24,*id),
            (14,Expected::List(id,restart,cap))=>body.len()==34&&u16_at(body,0)==33&&body[2]==37
                &&body[3]==u8::from(*restart)&&body[4..8]==[0;4]&&same_id(body,8,*id)&&u32_at(body,28)==*cap
                &&u16_at(body,24)==96&&u16_at(body,26)==2&&body[32..]==[42,0],
            (6,Expected::Close(id))=>body.len()==24&&u16_at(body,0)==24&&body[2..8]==[0;6]&&same_id(body,8,*id),_=>false,
        }
    }
    pub(crate) fn allows_command(&self,command:usize)->bool{
        match &*self.state.lock().unwrap(){State::Idle=>self.file.allows_command(command),State::Poisoned=>false,
            State::Active{expected,..}=>matches!(command,2|4|12|13)||match expected{
                Expected::Held=>false,Expected::Open(_)=>command==5,Expected::Query(..)=>command==16,
                Expected::List(..)=>command==14,Expected::Close(_)=>command==6,Expected::Member{read,..}=>matches!(command,5|6|16)||command==8&&*read,
            },
        }
    }
    fn begin(&self,tree:TreeId,session:u64)->Result<u64>{
        let mut value=self.state.lock().unwrap();if tree.0==0||session==0||!matches!(*value,State::Idle)||!self.file.idle(){return Err(invalid());}
        let generation=self.serial.load(Ordering::Acquire).checked_add(1).ok_or_else(invalid)?;
        self.serial.store(generation,Ordering::Release);
        *value=State::Active{tree:tree.0,session,handles:Vec::new(),expected:Expected::Held};Ok(generation)
    }
    fn begin_borrowed(&self,tree:TreeId,session:u64,root:FileId)->Result<u64>{
        if !usable(root){return Err(invalid());}
        let generation=self.begin(tree,session)?;
        let mut value=self.state.lock().unwrap();
        match &mut *value{State::Active{handles,expected:Expected::Held,..}if handles.is_empty()=>{
            handles.push(root);Ok(generation)},_=>Err(invalid())}
    }
    fn release_borrowed(&self,root:FileId)->Result<()>{
        let mut value=self.state.lock().unwrap();match &mut *value{
            State::Active{handles,expected:Expected::Held,..}if handles.as_slice()==[root]&&self.file.idle()=>{
                handles.clear();Ok(())},_=>Err(invalid()),
        }
    }
    fn expect(&self,next:Expected)->Result<()>{
        let mut value=self.state.lock().unwrap();match &mut *value{
            State::Active{handles,expected,..}if matches!(*expected,Expected::Held)=>{
                let valid=match &next{Expected::Query(id,..)|Expected::List(id,..)|Expected::Close(id)=>handles.contains(id),
                    Expected::Open(_)=>handles.len()<MAX_HANDLES,Expected::Member{..}=>self.file.idle(),Expected::Held=>false};
                if !valid{return Err(invalid());}*expected=next;Ok(())},_=>Err(invalid()),
        }
    }
    fn opened(&self,id:FileId)->Result<()>{
        let mut value=self.state.lock().unwrap();match &mut *value{
            State::Active{handles,expected,..}if matches!(*expected,Expected::Open(_))&&usable(id)&&!handles.contains(&id)&&handles.len()<MAX_HANDLES=>{handles.push(id);*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn acknowledged(&self)->Result<()>{
        let mut value=self.state.lock().unwrap();match &mut *value{
            State::Active{expected,..}if matches!(*expected,Expected::Query(..)|Expected::List(..))=>{*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn closed(&self,id:FileId)->Result<()>{
        let mut value=self.state.lock().unwrap();match &mut *value{
            State::Active{handles,expected,..}if matches!(*expected,Expected::Close(wanted)if wanted==id)=>{
                let Some(at)=handles.iter().position(|v|*v==id)else{return Err(invalid())};handles.remove(at);*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn permit_member_read(&self)->Result<()>{let mut value=self.state.lock().unwrap();match &mut *value{
        State::Active{expected:Expected::Member{read,..},..}if !*read&&self.file.active()=>{*read=true;Ok(())},_=>Err(invalid()),}}
    fn end_member(&self)->Result<()>{let mut value=self.state.lock().unwrap();match &mut *value{
        State::Active{expected,..}if matches!(*expected,Expected::Member{..})&&self.file.idle()=>{*expected=Expected::Held;Ok(())},_=>Err(invalid()),}}
    fn finish(&self)->Result<()>{let mut value=self.state.lock().unwrap();match &*value{
        State::Active{handles,expected:Expected::Held,..}if handles.is_empty()&&self.file.idle()=>{*value=State::Idle;Ok(())},_=>Err(invalid()),}}
    fn poison(&self){*self.state.lock().unwrap()=State::Poisoned;}
    fn file_conflicts(&self,id:FileId)->bool{match &*self.state.lock().unwrap(){State::Active{handles,..}=>handles.contains(&id),_=>true}}
}
struct ExactDirectory<'a>(&'a[u16]);
impl Pack for ExactDirectory<'_>{fn pack(&self,out:&mut WriteCursor){
    out.write_u16_le(57);out.write_bytes(&[0;2]);out.write_u32_le(2);out.write_bytes(&[0;16]);
    for value in [0x0010_0081u32,0,1,1,0x0020_0001]{out.write_u32_le(value);}
    out.write_u16_le(120);out.write_u16_le((self.0.len()*2)as u16);out.write_bytes(&[0;8]);for part in self.0{out.write_u16_le(*part);}
}}
#[derive(Clone,PartialEq,Eq)]
/// Complete same-handle directory facts; never a promise of atomic snapshot.
pub struct DirectorySnapshot{
    /// Reported EOF.
    pub size:u64,
    /// Reported allocation.
    pub allocated:u64,
    /// Last-write FILETIME.
    pub modified:u64,
    /// Change FILETIME.
    pub changed:u64,
    /// Exact DOS attributes.
    pub attributes:u32,
    /// Mandatory usable filesystem index.
    pub index:u64,
    /// Mandatory volume serial.
    pub volume:u32,
}
pub(crate) fn directory_snapshot_from_queries(basic:&[u8],standard:&[u8],internal:&[u8],volume:&[u8])->Result<DirectorySnapshot>{
    if basic.len()!=40||standard.len()!=24||internal.len()!=8||volume.len()<18{return Err(invalid());}
    let attributes=u32_at(basic,32);let index=u64_at(internal,0);let serial=u32_at(volume,8);let label=u32_at(volume,12)as usize;
    if attributes&0x450!=0x10||index==0||index==u64::MAX||serial==0||standard[20]!=0||standard[21]!=1
        ||volume[16]>1||label%2!=0||label>1024||18usize.checked_add(label)!=Some(volume.len()){return Err(invalid());}
    Ok(DirectorySnapshot{size:u64_at(standard,8),allocated:u64_at(standard,0),modified:u64_at(basic,16),
        changed:u64_at(basic,24),attributes,index,volume:serial})
}
/// A live checked directory open retained through an admitted tree transaction.
pub struct HeldDirectory{file:FileId,path:Vec<u16>,snapshot:DirectorySnapshot,owner:Arc<SelectedFolderPolicy>,generation:u64}
impl HeldDirectory{
    /// Fresh same-handle facts.
    pub fn snapshot(&self)->&DirectorySnapshot{&self.snapshot}
}
#[derive(Clone,PartialEq,Eq)]
/// One exact class37 child observation, including its enumeration parent.
pub struct FolderEntry{
    /// Literal component; never a display-normalized spelling.
    pub name:Vec<u16>,
    /// Exact DOS attributes.
    pub attributes:u32,
    /// Reported EOF.
    pub size:u64,
    /// Reported allocation.
    pub allocated:u64,
    /// Last-write FILETIME.
    pub modified:u64,
    /// Change FILETIME.
    pub changed:u64,
    /// Mandatory enumeration filesystem ID.
    pub index:u64,
}
impl FolderEntry{
    /// Regular/directory classification; reparse/device members are rejected.
    pub fn directory(&self)->bool{self.attributes&0x10!=0}
}
/// One root transaction. Abandonment poisons the whole connection; no detached
/// Drop CLOSE is scheduled and only acknowledged closes count as completion.
pub struct CheckedFolderReader{conn:Connection,policy:Arc<SelectedFolderPolicy>,tree:TreeId,session:u64,root_path:Vec<u16>,generation:u64,limit:u64,borrowed_root:bool,ended:bool}
impl CheckedFolderReader{
    /// Start a selected root. The caller retains its exact catalog selection.
    pub async fn prepare(conn:Connection,tree:TreeId,path:&[u16],attributes:u32,modified:u64)->Result<(Self,HeldDirectory)>{
        if !safe_path(path)||attributes&0x450!=0x10{return Err(invalid());}
        let policy=conn.selected_folder_policy()?;let session=conn.session_id().0;let generation=policy.begin(tree,session)?;
        let owner=Self{conn,policy,tree,session,root_path:path.to_vec(),generation,limit:MAX_BYTES,borrowed_root:false,ended:false};let root=owner.open_directory_path(path).await?;
        if root.snapshot.attributes!=attributes||root.snapshot.modified!=modified{return Err(invalid());}Ok((owner,root))
    }
    /// F2's newly published private root has no earlier catalog entry. This
    /// still opens it through the exact F1 gate and validates its same-handle
    /// directory facts before any member body is read.
    pub async fn prepare_published(conn:Connection,tree:TreeId,path:&[u16])->Result<(Self,HeldDirectory)>{
        if !safe_path(path){return Err(invalid());}
        let policy=conn.selected_folder_policy()?;let session=conn.session_id().0;let generation=policy.begin(tree,session)?;
        let owner=Self{conn,policy,tree,session,root_path:path.to_vec(),generation,limit:PUBLISHED_UPLOAD_MAX_BYTES,borrowed_root:false,ended:false};
        let root=owner.open_directory_path(path).await?;Ok((owner,root))
    }
    /// F2's held staged root supplies the exact root handle. This metadata
    /// reader never owns or closes that handle; all child opens still use the
    /// ordinary F1 checker and are acknowledged before it releases the claim.
    pub(crate) fn prepare_borrowed(conn:Connection,tree:TreeId,path:&[u16],file:FileId,snapshot:DirectorySnapshot)->Result<(Self,HeldDirectory)>{
        if !safe_path(path)||snapshot.index==0||snapshot.volume==0||snapshot.attributes&0x450!=0x10{return Err(invalid());}
        let policy=conn.selected_folder_policy()?;let session=conn.session_id().0;
        let generation=policy.begin_borrowed(tree,session,file)?;
        let root=HeldDirectory{file,path:path.to_vec(),snapshot,owner:Arc::clone(&policy),generation};
        let owner=Self{conn,policy,tree,session,root_path:path.to_vec(),generation,limit:PUBLISHED_UPLOAD_MAX_BYTES,borrowed_root:true,ended:false};
        Ok((owner,root))
    }
    pub(crate) fn byte_limit(&self)->u64{self.limit}
    async fn query(&self,file:FileId,info:u8,class:u8,cap:u32)->Result<Vec<u8>>{
        self.policy.expect(Expected::Query(file,info,class,cap))?;
        let request=QueryInfoRequest{info_type:if info==1{InfoType::File}else{InfoType::Filesystem},file_info_class:class,output_buffer_length:cap,
            additional_information:0,flags:0,file_id:file,input_buffer:vec![]};
        let frame=self.conn.execute(Command::QueryInfo,&request,Some(self.tree)).await?;
        let result=d1::query_bytes(&frame,cap,self.tree,self.session)?.to_vec();self.policy.acknowledged()?;Ok(result)
    }
    async fn observe(&self,file:FileId)->Result<DirectorySnapshot>{
        let basic=self.query(file,1,4,40).await?;let standard=self.query(file,1,5,24).await?;
        let internal=self.query(file,1,6,8).await?;let volume=self.query(file,2,1,1042).await?;
        directory_snapshot_from_queries(&basic,&standard,&internal,&volume)
    }
    async fn open_directory_path(&self,path:&[u16])->Result<HeldDirectory>{
        if !safe_path(path){return Err(invalid());}self.policy.expect(Expected::Open(path.iter().flat_map(|v|v.to_le_bytes()).collect()))?;
        let frame=self.conn.execute(Command::Create,&ExactDirectory(path),Some(self.tree)).await?;let raw=d1::response(&frame,Command::Create,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=152||u16_at(raw,64)!=89||raw[66]!=0||raw[67]!=0||u32_at(raw,144)!=0||u32_at(raw,148)!=0{return Err(invalid());}
        let opened=CreateResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        if opened.create_action!=CreateAction::FileOpened||opened.file_attributes&0x450!=0x10{return Err(invalid());}
        self.policy.opened(opened.file_id)?;let snapshot=self.observe(opened.file_id).await?;
        if snapshot.attributes!=opened.file_attributes||snapshot.modified!=opened.last_write_time.0||snapshot.changed!=opened.change_time.0{return Err(invalid());}
        Ok(HeldDirectory{file:opened.file_id,path:path.to_vec(),snapshot,owner:Arc::clone(&self.policy),generation:self.generation})
    }
    fn owns(&self,directory:&HeldDirectory)->Result<()>{if !Arc::ptr_eq(&self.policy,&directory.owner)||directory.generation!=self.generation{return Err(invalid());}Ok(())}
    /// Reopen the exact current namespace path and compare the held identity.
    pub async fn revalidate_path(&self,directory:&HeldDirectory)->Result<()>{
        self.owns(directory)?;
        if self.borrowed_root&&directory.path==self.root_path{
            return if self.observe(directory.file).await?==directory.snapshot{Ok(())}else{Err(invalid())};
        }
        let fresh=self.open_directory_path(&directory.path).await?;let matches=fresh.snapshot==directory.snapshot;
        self.close(fresh).await?;if !matches{return Err(invalid());}Ok(())
    }
    /// Require one unmodified known directory and class37 end-of-enumeration.
    pub async fn children(&self,directory:&HeldDirectory)->Result<Vec<FolderEntry>>{
        self.owns(directory)?;
        if self.observe(directory.file).await?!=directory.snapshot{return Err(invalid());}
        let cap=self.conn.params().ok_or_else(invalid)?.max_transact_size.min(65536);if cap<1024{return Err(invalid());}
        let mut first=true;let mut result=Vec::<FolderEntry>::new();let mut component_bytes=0usize;
        for _ in 0..=MAX_NODES{
            self.policy.expect(Expected::List(directory.file,first,cap))?;
            let request=QueryDirectoryRequest{file_information_class:FileInformationClass::FileIdBothDirectoryInformation,flags:QueryDirectoryFlags(u8::from(first)),file_index:0,
                file_id:directory.file,output_buffer_length:cap,file_name:"*".into()};
            first=false;let frame=self.conn.execute(Command::QueryDirectory,&request,Some(self.tree)).await?;
            let raw=d1::response(&frame,Command::QueryDirectory,self.tree,self.session)?;
            if frame.header.status.0==0x80000006{
                if !(72..=73).contains(&raw.len())||u16_at(raw,64)!=9||raw[66..68]!=[0;2]||u32_at(raw,68)!=0||raw[72..].iter().any(|v|*v!=0){return Err(invalid());}
                self.policy.acknowledged()?;
                if self.observe(directory.file).await?!=directory.snapshot{return Err(invalid());}
                result.sort_by(|a,b|a.name.cmp(&b.name));return Ok(result);
            }
            d1::success(&frame)?;
            if raw.len()<72||u16_at(raw,64)!=9{return Err(invalid());}let at=usize::from(u16_at(raw,66));let count=u32_at(raw,68)as usize;
            if at<72||count==0||count>cap as usize||at.checked_add(count)!=Some(raw.len()){return Err(invalid());}
            let rows=parse_entries(FileInformationClass::FileIdBothDirectoryInformation,&raw[at..])?;
            if rows.is_empty()||rows.len()>700{return Err(invalid());}
            for row in rows{self.add_entry(row,&mut result,&mut component_bytes)?;}
            self.policy.acknowledged()?;
        }
        Err(invalid())
    }
    fn add_entry(&self,row:DirectoryInfoEntry,result:&mut Vec<FolderEntry>,component_bytes:&mut usize)->Result<()>{
        if row.file_name=="."||row.file_name==".."{return if row.file_attributes&0x450==0x10{Ok(())}else{Err(invalid())};}
        let name=row.file_name.encode_utf16().collect::<Vec<_>>();let index=row.file_id.ok_or_else(invalid)?;
        if !safe_name(&name)||row.file_attributes&0x440!=0||index==0||index==u64::MAX||result.len()>=MAX_NODES
            ||result.iter().any(|v|v.name==name||v.index==index)||row.end_of_file>self.limit&&row.file_attributes&0x10==0{return Err(invalid());}
        *component_bytes=component_bytes.checked_add(name.len()*2).filter(|v|*v<=4<<20).ok_or_else(invalid)?;
        result.push(FolderEntry{name,attributes:row.file_attributes,size:row.end_of_file,allocated:row.allocation_size,modified:row.last_write_time.0,changed:row.change_time.0,index});Ok(())
    }
    fn path(&self,parent:&HeldDirectory,name:&[u16])->Result<Vec<u16>>{
        self.owns(parent)?;
        if !safe_name(name)||!parent.path.starts_with(&self.root_path){return Err(invalid());}
        if parent.path.len()>self.root_path.len()&&parent.path[self.root_path.len()]!=92{return Err(invalid());}
        let mut path=parent.path.clone();path.push(92);path.extend_from_slice(name);if !safe_path(&path){return Err(invalid());}Ok(path)
    }
    /// Bind a directory to its exact enumerating parent before traversal.
    pub async fn open_child(&self,parent:&HeldDirectory,entry:&FolderEntry)->Result<HeldDirectory>{
        if !entry.directory(){return Err(invalid());}self.revalidate_path(parent).await?;
        let path=self.path(parent,&entry.name)?;let child=self.open_directory_path(&path).await?;
        if child.snapshot.index!=entry.index||child.snapshot.volume!=parent.snapshot.volume||child.snapshot.attributes!=entry.attributes
            ||child.snapshot.modified!=entry.modified||child.snapshot.changed!=entry.changed{return Err(invalid());}
        Ok(child)
    }
    /// Revalidated regular member, no body permission before matching all facts.
    pub async fn prepare_file(&self,parent:&HeldDirectory,entry:&FolderEntry)->Result<d1::CheckedFileReader>{
        if entry.directory(){return Err(invalid());}self.revalidate_path(parent).await?;
        let path=self.path(parent,&entry.name)?;self.policy.expect(Expected::Member{path:path.iter().flat_map(|v|v.to_le_bytes()).collect(),read:false})?;
        let reader=d1::CheckedFileReader::prepare(self.conn.clone(),self.tree,&path,d1::ListedFile{attributes:entry.attributes,size:entry.size,modified:entry.modified}).await?;
        let facts=reader.snapshot();
        if facts.index!=entry.index||facts.volume_serial!=parent.snapshot.volume||facts.changed!=entry.changed||facts.allocated!=entry.allocated||facts.links!=1
            ||self.policy.file_conflicts(reader.handle_id()?){return Err(invalid());}
        Ok(reader)
    }
    /// Explicitly admit this already prepared member's bounded bytes.
    pub fn permit_file_body(&self)->Result<()>{self.policy.permit_member_read()}
    /// Call only after D1 acknowledged CLOSE; the enclosing guard stays held.
    pub fn member_closed(&self)->Result<()>{self.policy.end_member()}
    /// A successful native CLOSE is required; errors stay whole-session fatal.
    pub async fn close(&self,directory:HeldDirectory)->Result<()>{
        self.owns(&directory)?;
        self.policy.expect(Expected::Close(directory.file))?;
        let frame=self.conn.execute(Command::Close,&CloseRequest{flags:0,file_id:directory.file},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Close,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=124||u16_at(raw,64)!=60||u16_at(raw,66)!=0{return Err(invalid());}self.policy.closed(directory.file)
    }
    pub(crate) async fn release_root(&self,directory:HeldDirectory)->Result<()>{
        self.owns(&directory)?;
        if self.borrowed_root&&directory.path==self.root_path{
            self.policy.release_borrowed(directory.file)
        }else{self.close(directory).await}
    }
    /// Final state only after every directory and file acknowledged closure.
    pub fn finish(mut self)->Result<()>{self.policy.finish()?;self.ended=true;Ok(())}
}
impl Drop for CheckedFolderReader{fn drop(&mut self){if !self.ended{self.policy.poison();self.conn.mark_dead();}}}

#[path="selected_folder_tree.rs"]mod tree;
pub use tree::{PreparedFolder,FolderNode,FolderReadEvent};

#[cfg(feature="b12-folder-qualification")]
#[path="selected_folder_controls.rs"]mod controls;
#[cfg(feature="b12-folder-qualification")]
/// Generated no-socket controls of exact folder authority and native frames.
pub async fn qualification_run()->Result<usize>{controls::run().await}

#[cfg(feature="b12-folder-qualification")]
/// Generated transport responder rejects empty continuation patterns like Samba.
pub async fn qualification_continuation()->Result<usize>{controls::continuation_run().await}
