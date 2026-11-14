//! Concrete checked SMB file reader. First qualified in an isolated source copy.
use std::sync::{Arc,Mutex,atomic::{AtomicBool,Ordering}};
use crate::{Error,error::Result,client::{Connection,Frame},pack::{ReadCursor,Unpack,Pack,WriteCursor},
    msg::{create::{CreateResponse,CreateAction},
        read::ReadRequest,query_info::{QueryInfoRequest,InfoType},close::CloseRequest},
    types::{Command,FileId,TreeId}};

/// Maximum body bytes in one positioned request.
pub const CHUNK:u32=32768;
/// Maximum explicitly selected file size; no large allocation follows this cap.
pub const MAX_FILE:u64=1<<30;
fn invalid()->Error{Error::invalid_data("Selected SMB file download refused")}
fn u16_at(v:&[u8],n:usize)->u16{u16::from_le_bytes(v[n..n+2].try_into().unwrap())}
fn u32_at(v:&[u8],n:usize)->u32{u32::from_le_bytes(v[n..n+4].try_into().unwrap())}
fn u64_at(v:&[u8],n:usize)->u64{u64::from_le_bytes(v[n..n+8].try_into().unwrap())}
#[derive(Clone)]
enum Expected {Opening(Vec<u8>),Held,Query(u8,u8,u32),Read(u64,u32),Close}
#[derive(Clone)]
enum State {Idle,Active{tree:u32,session:u64,file:Option<FileId>,expected:Expected},Poisoned}
/// One per connection, shared by the transport and pre-encryption/submission gates.
/// Only CheckedFileReader can change its private per-handle authority.
pub struct SelectedDownloadPolicy {state:Mutex<State>,attached:AtomicBool}
impl SelectedDownloadPolicy {
    /// Start with only the unchanged metadata profile; no handle is admitted.
    pub fn new()->Arc<Self>{Arc::new(Self{state:Mutex::new(State::Idle),attached:AtomicBool::new(false)})}
    pub(crate) fn idle(&self)->bool {matches!(*self.state.lock().unwrap(),State::Idle)}
    pub(crate) fn active(&self)->bool {matches!(*self.state.lock().unwrap(),State::Active{..})}
    pub(crate) fn claim(&self)->Result<()> {
        self.attached.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).map(|_|()).map_err(|_|invalid())
    }
    /// Check the actual plaintext before transport submission or encryption.
    pub fn permits_frame(&self,data:&[u8])->bool {
        if !(64..=256*1024).contains(&data.len())||!data.starts_with(b"\xfeSMB")||u16_at(data,4)!=64||u32_at(data,20)!=0{return false;}
        let state=self.state.lock().unwrap();
        let (tree,session,file,expected)=match &*state {
            State::Idle=>return super::connection::b10_metadata::permitted_frame(data),
            State::Poisoned=>return false,
            State::Active{tree,session,file,expected}=>(*tree,*session,*file,expected),
        };
        let command=u16_at(data,12);
        if u32_at(data,16)&!8!=0{return false;}
        // Teardown and cancellation retain the current connection's authority.
        if matches!(command,2|4|12|13){return data.len()==68&&u16_at(data,64)==4&&data[66..68]==[0,0]
            &&u64_at(data,40)==session&&(command!=4||u32_at(data,36)==tree);}
        if u32_at(data,36)!=tree||u64_at(data,40)!=session{return false;}
        let body=&data[64..];
        match (command,expected) {
            (5,Expected::Opening(name))=>body.len()==56+name.len()&&u16_at(body,0)==57&&body[2..4]==[0,0]
                &&u32_at(body,4)==2&&body[8..24]==[0;16]&&u32_at(body,24)==0x0010_0081
                &&u32_at(body,28)==0&&u32_at(body,32)==1&&u32_at(body,36)==1&&u32_at(body,40)==0x0020_0040
                &&u16_at(body,44)==120&&usize::from(u16_at(body,46))==name.len()&&body[48..56]==[0;8]&&body[56..]==*name,
            (16,Expected::Query(info,class,cap))=>body.len()==40&&u16_at(body,0)==41&&body[2]==*info&&body[3]==*class
                &&u32_at(body,4)==*cap&&body[8..24]==[0;16]&&file.is_some_and(|id|same_file(body,24,id)),
            (8,Expected::Read(offset,length))=>*length>0&&*length<=CHUNK&&body.len()==49&&u16_at(body,0)==49&&body[2..4]==[0;2]
                &&u32_at(body,4)==*length&&u64_at(body,8)==*offset&&body[32..]==[0;17]
                &&file.is_some_and(|id|same_file(body,16,id)),
            (6,Expected::Close)=>body.len()==24&&u16_at(body,0)==24&&body[2..8]==[0;6]&&file.is_some_and(|id|same_file(body,8,id)),
            _=>false,
        }
    }
    pub(crate) fn allows_command(&self,code:usize)->bool {
        match &*self.state.lock().unwrap(){
            State::Idle=>[0,1,2,3,4,5,6,12,13,14].contains(&code),State::Poisoned=>false,
            State::Active{expected,..}=>matches!(code,2|4|12|13)||match expected{
                Expected::Opening(_)=>code==5,Expected::Query(..)=>code==16,Expected::Read(..)=>code==8,Expected::Close=>code==6,Expected::Held=>false,
            },
        }
    }
    fn begin(&self,tree:TreeId,session:u64,name:&[u16])->Result<()> {
        if session==0||tree.0==0||!valid_path(name){return Err(invalid());}
        let mut state=self.state.lock().unwrap();if !matches!(*state,State::Idle){return Err(invalid());}
        *state=State::Active{tree:tree.0,session,file:None,expected:Expected::Opening(name.iter().flat_map(|v|v.to_le_bytes()).collect())};Ok(())
    }
    fn opened(&self,id:FileId)->Result<()> {
        if id==FileId::default()||id.persistent==u64::MAX||id.volatile==u64::MAX{return Err(invalid());}
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{file,expected:expected@Expected::Opening(_),..}=>{*file=Some(id);*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn expect(&self,next:Expected)->Result<()> {
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{file:Some(_),expected,..}if matches!(*expected,Expected::Held)=>{*expected=next;Ok(())},_=>Err(invalid()),
        }
    }
    fn acknowledged(&self)->Result<()> {
        let mut state=self.state.lock().unwrap();match &mut *state{
            State::Active{file:Some(_),expected,..}if matches!(*expected,Expected::Query(..)|Expected::Read(..))=>{*expected=Expected::Held;Ok(())},_=>Err(invalid()),
        }
    }
    fn closed(&self)->Result<()> {
        let mut state=self.state.lock().unwrap();if !matches!(*state,State::Active{expected:Expected::Close,..}){return Err(invalid());}
        *state=State::Idle;Ok(())
    }
    fn poison(&self){*self.state.lock().unwrap()=State::Poisoned;}
}
fn same_file(body:&[u8],at:usize,id:FileId)->bool{u64_at(body,at)==id.persistent&&u64_at(body,at+8)==id.volatile}
// CreateRequest's general name mapper is intentionally bypassed: the catalog
// already supplies the exact UTF-16 wire spelling, including private-use units.
struct ExactOpen<'a>(&'a[u16]);
impl Pack for ExactOpen<'_>{fn pack(&self,out:&mut WriteCursor){
    out.write_u16_le(57);out.write_bytes(&[0;2]);out.write_u32_le(2);out.write_bytes(&[0;16]);
    for value in [0x0010_0081u32,0,1,1,0x0020_0040]{out.write_u32_le(value);}
    out.write_u16_le(120);out.write_u16_le((self.0.len()*2)as u16);out.write_bytes(&[0;8]);
    for value in self.0{out.write_u16_le(*value);}
}}
fn valid_path(name:&[u16])->bool {
    if name.is_empty()||name.len()>2048||String::from_utf16(name).is_err(){return false;}
    name.split(|v|*v==92).all(|part|!part.is_empty()&&part!=[46]&&part!=[46,46]
        &&!matches!(part.last(),Some(32|46))&&!part.iter().any(|v|*v<32||matches!(*v,47|58|42|63|34|60|62|124)))
}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
/// Frozen current catalog facts. This is not an identity proof back to listing.
pub struct ListedFile {
    /// Exact listed DOS attributes.
    pub attributes:u32,
    /// Exact listed EOF length.
    pub size:u64,
    /// Exact listed last-write FILETIME.
    pub modified:u64,
}
#[derive(Clone,Copy)]
enum OpenBinding<'a> { Listed(ListedFile), Published(&'a FileSnapshot) }
#[derive(Clone,Debug,PartialEq,Eq)]
/// Mandatory metadata queried through the same live handle, before and after.
pub struct FileSnapshot {
    /// EOF length.
    pub size:u64,
    /// Server allocation length, compared without promising exclusive space.
    pub allocated:u64,
    /// Creation FILETIME.
    pub created:u64,
    /// Last-write FILETIME.
    pub modified:u64,
    /// Change FILETIME; last-access changes caused by reading are ignored.
    pub changed:u64,
    /// DOS attributes; links/reparse points/directories/devices refuse.
    pub attributes:u32,
    /// Reported hard-link count.
    pub links:u32,
    /// Nonzero filesystem index, distinct from the SMB open identifier.
    pub index:u64,
    /// Volume creation FILETIME.
    pub volume_created:u64,
    /// Nonzero volume serial number.
    pub volume_serial:u32,
}
fn regular(attributes:u32)->bool{attributes&0x450==0}
pub(crate) fn response<'a>(frame:&'a Frame,command:Command,tree:TreeId,session:u64)->Result<&'a[u8]> {
    let raw=&frame.raw;
    if raw.len()<64||raw.len()>256*1024||!raw.starts_with(b"\xfeSMB")||u16_at(raw,4)!=64||u16_at(raw,12)!=command as u16
        ||u32_at(raw,16)&1==0||u32_at(raw,16)&!9!=0||u32_at(raw,20)!=0||u32_at(raw,36)!=tree.0||u64_at(raw,40)!=session
        ||frame.header.command!=command||frame.header.session_id.0!=session||frame.header.tree_id!=Some(tree)
        ||frame.header.status.0!=u32_at(raw,8)||frame.header.message_id.0!=u64_at(raw,24)
        ||frame.body.as_slice()!=&raw[64..]{return Err(invalid());}Ok(raw)
}
pub(crate) fn success(frame:&Frame)->Result<()>{if frame.header.status.0==0{Ok(())}else{Err(Error::Protocol{status:frame.header.status,command:frame.header.command})}}
pub(crate) fn query_bytes(frame:&Frame,cap:u32,tree:TreeId,session:u64)->Result<&[u8]> {
    let raw=response(frame,Command::QueryInfo,tree,session)?;success(frame)?;
    if raw.len()<72||u16_at(raw,64)!=9{return Err(invalid());}
    let offset=usize::from(u16_at(raw,66));let length=u32_at(raw,68)as usize;
    if offset<72||length==0||length>cap as usize||offset.checked_add(length)!=Some(raw.len()){return Err(invalid());}
    Ok(&raw[offset..])
}
pub(crate) fn read_bytes(frame:&Frame,requested:u32,tree:TreeId,session:u64)->Result<Option<Vec<u8>>> {
    let raw=response(frame,Command::Read,tree,session)?;
    if frame.header.status.0==0xc0000011 {
        if raw.len()<72||u16_at(raw,64)!=9||raw[66]!=0||u32_at(raw,68)!=0||raw[72..].iter().any(|v|*v!=0)||raw.len()>73{return Err(invalid());}
        return Ok(None);
    }
    success(frame)?;if raw.len()<80||u16_at(raw,64)!=17||u32_at(raw,72)!=0||u32_at(raw,76)!=0{return Err(invalid());}
    let offset=usize::from(raw[66]);let length=u32_at(raw,68)as usize;
    if requested==0||requested>CHUNK||offset<80||length==0||length>requested as usize||offset.checked_add(length)!=Some(raw.len()){return Err(invalid());}
    Ok(Some(raw[offset..].to_vec()))
}
/// Owns one remote handle; abandon/error closes the exact whole connection.
/// Finish requires all bytes consumed, a real EOF read, postcheck and actual CLOSE.
pub struct CheckedFileReader {conn:Connection,policy:Arc<SelectedDownloadPolicy>,tree:TreeId,file:Option<FileId>,snapshot:Option<FileSnapshot>,offset:u64,session:u64,ended:bool}
impl CheckedFileReader {
    /// Open the exact admitted UTF-16 spelling and bind fresh same-handle facts.
    /// Any uncertain opening ends this connection; it is never retried.
    pub async fn prepare(conn:Connection,tree:TreeId,name:&[u16],listed:ListedFile)->Result<Self> {
        Self::prepare_bound(conn,tree,name,OpenBinding::Listed(listed),false).await?.ok_or_else(invalid)
    }
    /// Retained editor Open may refuse a changed listed file after closing the
    /// actual handle. No body is read and the connection remains usable.
    pub async fn prepare_edit(conn:Connection,tree:TreeId,name:&[u16],listed:ListedFile)->Result<Option<Self>> {
        Self::prepare_bound(conn,tree,name,OpenBinding::Listed(listed),true).await
    }
    /// Reopen the published stage by its filesystem identity. Last-write may
    /// finalize on CLOSE, so bind it from this new CREATE and same-handle QUERY.
    pub(crate) async fn prepare_published(conn:Connection,tree:TreeId,name:&[u16],stage:&FileSnapshot)->Result<Self> {
        Self::prepare_bound(conn,tree,name,OpenBinding::Published(stage),false).await?.ok_or_else(invalid)
    }
    async fn prepare_bound(conn:Connection,tree:TreeId,name:&[u16],binding:OpenBinding<'_>,
        edit_open:bool)->Result<Option<Self>> {
        let (attributes,size)=match binding {OpenBinding::Listed(file)=>(file.attributes,file.size),
            OpenBinding::Published(stage)=>(stage.attributes,stage.size)};
        if !regular(attributes)||size>MAX_FILE{
            return if edit_open{Ok(None)}else{Err(invalid())};
        }
        let policy=conn.selected_download_policy()?;let session=conn.session_id().0;policy.begin(tree,session,name)?;
        let mut reader=Self{conn,policy,tree,file:None,snapshot:None,offset:0,session,ended:false};
        let request=ExactOpen(name);
        let frame=reader.conn.execute(Command::Create,&request,Some(tree)).await?;
        let raw=response(&frame,Command::Create,tree,session)?;success(&frame)?;
        if raw.len()!=152||u16_at(raw,64)!=89||raw[66]!=0||raw[67]!=0||u32_at(raw,144)!=0||u32_at(raw,148)!=0{return Err(invalid());}
        let created=CreateResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        let modified=match binding {OpenBinding::Listed(file)=>file.modified,
            OpenBinding::Published(_)=>created.last_write_time.0};
        if created.create_action!=CreateAction::FileOpened{return Err(invalid());}
        reader.policy.opened(created.file_id)?;reader.file=Some(created.file_id);
        if !regular(created.file_attributes)||created.end_of_file!=size
            ||created.last_write_time.0!=modified||created.file_attributes!=attributes{
            if edit_open {reader.close_handle().await?;return Ok(None);}return Err(invalid());
        }
        let snapshot=reader.observe().await?;
        if snapshot.size!=size||snapshot.modified!=modified||snapshot.attributes!=attributes
            ||snapshot.created!=created.creation_time.0||snapshot.changed!=created.change_time.0{
            if edit_open {reader.close_handle().await?;return Ok(None);}return Err(invalid());
        }
        if let OpenBinding::Published(stage)=binding {
            if snapshot.index!=stage.index||snapshot.volume_serial!=stage.volume_serial{return Err(invalid());}
        }
        reader.snapshot=Some(snapshot);Ok(Some(reader))
    }
    /// Fresh prepared facts, available without reading any file body.
    pub fn snapshot(&self)->&FileSnapshot{self.snapshot.as_ref().expect("prepared reader")}
    pub(crate) fn handle_id(&self)->Result<FileId>{self.file.ok_or_else(invalid)}
    async fn query(&mut self,info:u8,class:u8,cap:u32)->Result<Vec<u8>> {
        let file=self.file.ok_or_else(invalid)?;self.policy.expect(Expected::Query(info,class,cap))?;
        let request=QueryInfoRequest{info_type:if info==1{InfoType::File}else{InfoType::Filesystem},file_info_class:class,
            output_buffer_length:cap,additional_information:0,flags:0,file_id:file,input_buffer:vec![]};
        let frame=self.conn.execute(Command::QueryInfo,&request,Some(self.tree)).await?;
        let bytes=query_bytes(&frame,cap,self.tree,self.session)?.to_vec();self.policy.acknowledged()?;Ok(bytes)
    }
    async fn observe(&mut self)->Result<FileSnapshot> {
        let basic=self.query(1,4,40).await?;let standard=self.query(1,5,24).await?;
        let internal=self.query(1,6,8).await?;let volume=self.query(2,1,1042).await?;
        if basic.len()!=40||standard.len()!=24||internal.len()!=8||volume.len()<18{return Err(invalid());}
        let size=u64_at(&standard,8);let attributes=u32_at(&basic,32);let index=u64_at(&internal,0);let serial=u32_at(&volume,8);
        let label=u32_at(&volume,12)as usize;
        if size>MAX_FILE||!regular(attributes)||index==0||index==u64::MAX||serial==0||standard[20..22]!=[0,0]||u32_at(&standard,16)==0
            ||volume[16]>1||label%2!=0||label>1024||18usize.checked_add(label)!=Some(volume.len()){return Err(invalid());}
        Ok(FileSnapshot{size,allocated:u64_at(&standard,0),created:u64_at(&basic,0),modified:u64_at(&basic,16),changed:u64_at(&basic,24),attributes,
            links:u32_at(&standard,16),index,volume_created:u64_at(&volume,0),volume_serial:serial})
    }
    async fn wire_read(&mut self,length:u32)->Result<Option<Vec<u8>>> {
        if length==0||length>CHUNK||self.conn.params().map_or(true,|p|length>p.max_read_size){return Err(invalid());}
        self.policy.expect(Expected::Read(self.offset,length))?;
        let request=ReadRequest{padding:0,flags:0,length,offset:self.offset,file_id:self.file.ok_or_else(invalid)?,
            minimum_count:0,channel:0,remaining_bytes:0,read_channel_info:vec![]};
        let frame=self.conn.execute(Command::Read,&request,Some(self.tree)).await?;
        let bytes=read_bytes(&frame,length,self.tree,self.session)?;self.policy.acknowledged()?;Ok(bytes)
    }
    /// Receive one bounded positive chunk, advancing by the actual byte count.
    /// Call only while fewer than snapshot.size bytes have been received.
    pub async fn read_chunk(&mut self)->Result<Vec<u8>> {
        let remaining=self.snapshot().size.checked_sub(self.offset).ok_or_else(invalid)?;
        if remaining==0{return Err(invalid());}
        let length=remaining.min(u64::from(CHUNK)).min(u64::from(self.conn.params().ok_or_else(invalid)?.max_read_size))as u32;
        let bytes=self.wire_read(length).await?.ok_or_else(invalid)?;
        self.offset=self.offset.checked_add(bytes.len()as u64).ok_or_else(invalid)?;Ok(bytes)
    }
    /// Prove wire EOF, compare fresh facts and require actual successful CLOSE.
    pub async fn finish(mut self)->Result<FileSnapshot> {
        if self.offset!=self.snapshot().size||self.wire_read(1).await?.is_some(){return Err(invalid());}
        let after=self.observe().await?;if !self.snapshot().same_source(&after){return Err(invalid());}
        self.close_handle().await?;Ok(after)
    }
    /// Release a prepared handle before any body is requested, with real CLOSE.
    /// This is a cancelled preparation, never a completed Download receipt.
    pub async fn release(mut self)->Result<()> {
        if self.offset!=0{return Err(invalid());}self.close_handle().await
    }
    async fn close_handle(&mut self)->Result<()> {
        self.policy.expect(Expected::Close)?;
        let frame=self.conn.execute(Command::Close,&CloseRequest{flags:0,file_id:self.file.ok_or_else(invalid)?},Some(self.tree)).await?;
        let raw=response(&frame,Command::Close,self.tree,self.session)?;success(&frame)?;
        if raw.len()!=124||u16_at(raw,64)!=60||u16_at(raw,66)!=0{return Err(invalid());}
        self.policy.closed()?;self.ended=true;self.file=None;Ok(())
    }
}
impl Drop for CheckedFileReader {fn drop(&mut self){
    // Even CREATE cancellation can leave an unknown handle. No async Drop work.
    if !self.ended{self.policy.poison();self.conn.mark_dead();}
}}

#[cfg(feature="b12-qualification")]
#[path="selected_download_controls.rs"]
mod controls;
#[cfg(feature="b12-qualification")]
/// Execute copied-build generated controls; this feature is never shipped.
pub async fn qualification_run()->Result<usize>{let n=controls::run().await?;Ok(n+controls::compatibility_run().await?+controls::unavailable_identity_controls().await?)}

impl FileSnapshot {
    /// Creation fields may be POSIX approximations affected by our own READ.
    /// The held handle plus these exact witnesses guard source consistency.
    fn same_source(&self,other:&Self)->bool {
        self.size==other.size&&self.allocated==other.allocated&&self.modified==other.modified
            &&self.changed==other.changed&&self.attributes==other.attributes&&self.links==other.links
            &&self.index==other.index&&self.volume_serial==other.volume_serial
    }
}
