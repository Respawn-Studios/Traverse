//! Guarded in-place text edit of the original SMB object. This authority is
//! available only inside the opt-in encrypted upload policy.
use std::sync::{Arc, Mutex, atomic::{AtomicU8, Ordering}};
use sha2::{Digest, Sha256};
use crate::{Error, Result,
    client::{Connection, selected_download::{self as d1, CheckedFileReader, FileSnapshot, SelectedDownloadPolicy}, write_pipe::WritePipe},
    msg::{create::{CreateAction, CreateDisposition, CreateRequest, CreateResponse, ImpersonationLevel, ShareAccess},
        close::CloseRequest, flush::FlushRequest, query_info::{InfoType, QueryInfoRequest}, read::ReadRequest, set_info::SetInfoRequest},
    pack::{ReadCursor, Unpack},
    types::{Command, FileId, OplockLevel, TreeId, flags::FileAccessMask}};

pub const MAX_TEXT: u64 = 1 << 20;
const CHUNK: u32 = 32768;
const ACCESS: u32 = FileAccessMask::FILE_READ_DATA | FileAccessMask::FILE_WRITE_DATA
    | FileAccessMask::FILE_READ_ATTRIBUTES | FileAccessMask::SYNCHRONIZE;
const OPTIONS: u32 = 0x0020_0040; // Open reparse point; require a nondirectory file.
fn invalid() -> Error { Error::invalid_data("Selected SMB original edit refused") }
fn u16_at(v: &[u8], n: usize) -> u16 { u16::from_le_bytes([v[n], v[n+1]]) }
fn u32_at(v: &[u8], n: usize) -> u32 { u32::from_le_bytes(v[n..n+4].try_into().expect("fixed frame")) }
fn u64_at(v: &[u8], n: usize) -> u64 { u64::from_le_bytes(v[n..n+8].try_into().expect("fixed frame")) }
fn same_file(v: &[u8], n: usize, id: FileId) -> bool { u64_at(v,n)==id.persistent && u64_at(v,n+8)==id.volatile }
fn wire_name(path: &[u16]) -> Result<Vec<u8>> {
    if path.is_empty() || path.len()>2048 || !path.split(|v| *v==92).all(super::selected_folder_download::safe_remote_component) {
        return Err(invalid());
    }
    Ok(path.iter().flat_map(|v|v.to_le_bytes()).collect())
}
fn acceptable(snapshot: &FileSnapshot) -> bool {
    snapshot.size<=MAX_TEXT && snapshot.links==1 && snapshot.attributes&0x451==0
        && snapshot.index!=0 && snapshot.index!=u64::MAX && snapshot.volume_serial!=0
}
fn same_object(before: &FileSnapshot, after: &FileSnapshot, contract:EditAttributeContract) -> bool {
    before.index==after.index && before.volume_serial==after.volume_serial
        && (!contract.exact_creation_witnesses() ||
            before.volume_created==after.volume_created && before.created==after.created)
        && before.attributes==after.attributes && before.links==after.links
}
/// Versioned metadata comparison for an original Save write.
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub enum EditAttributeContract {
    /// The existing exact v1 comparison.
    ExactV1,
    /// The bounded archive-bit write transition of the opt-in v2 command.
    ArchiveWriteV2,
    /// V2's attribute transition plus creation-field approximation across mutation.
    ArchiveWriteCreationApproxV3,
}
impl EditAttributeContract {
    /// Attribute comparison after the first postwrite observation stays exact.
    pub fn permits_first_postwrite(self,before:u32,after:u32)->bool {
        if before==after{return true;}
        if self==Self::ExactV1{return false;}
        const ARCHIVE:u32=0x20;
        const NORMAL:u32=0x80;
        (before==NORMAL && after==ARCHIVE)
            || (before!=0 && before&(ARCHIVE|NORMAL)==0 && after==(before|ARCHIVE))
    }
    fn exact_creation_witnesses(self)->bool { self!=Self::ArchiveWriteCreationApproxV3 }
}
/// Fixed diagnostic family only. Retain the original comparison order.
fn first_postwrite_mismatch(before:&FileSnapshot,after:&FileSnapshot,contract:EditAttributeContract)->Option<u8> {
    if before.index!=after.index || before.volume_serial!=after.volume_serial
        || contract.exact_creation_witnesses() &&
            (before.volume_created!=after.volume_created || before.created!=after.created) { return Some(25); }
    if !contract.permits_first_postwrite(before.attributes,after.attributes) { return Some(26); }
    if before.links!=after.links { return Some(27); }
    None
}
fn mark(checkpoint:Option<&AtomicU8>,code:u8) {
    if let Some(value)=checkpoint { value.store(code,Ordering::Release); }
}

#[derive(Clone)]
enum Expected { Open(Vec<u8>), Held, Query(u8,u8,u32), Read(u64,u32), Write(u64,Vec<u8>), SetLength([u8;8]), Flush, Close, VerifyName(Vec<u8>) }
enum State { Idle, Active { tree:u32, session:u64, file:Option<FileId>, expected:Expected }, Poisoned }
/// Exact plaintext gate. Each command is armed by the checked handle, and the
/// current-name read after CLOSE is delegated to the existing D1 reader.
pub struct SelectedEditPolicy { state:Mutex<State>, read:Arc<SelectedDownloadPolicy> }
impl SelectedEditPolicy {
    pub(crate) fn new(read:Arc<SelectedDownloadPolicy>) -> Arc<Self> {
        Arc::new(Self { state:Mutex::new(State::Idle), read })
    }
    pub(crate) fn idle(&self) -> bool { matches!(*self.state.lock().unwrap(),State::Idle) }
    pub(crate) fn begin(&self,tree:TreeId,session:u64,path:&[u16]) -> Result<()> {
        let name=wire_name(path)?;
        let mut state=self.state.lock().unwrap();
        if tree.0==0 || session==0 || !matches!(*state,State::Idle) || !self.read.idle() { return Err(invalid()); }
        *state=State::Active{tree:tree.0,session,file:None,expected:Expected::Open(name)};Ok(())
    }
    pub(crate) fn allows_command(&self,code:usize) -> bool {
        match &*self.state.lock().unwrap() {
            State::Idle|State::Poisoned=>false,
            State::Active{expected,..}=>matches!(code,2|4|12|13)||match expected {
                Expected::Open(_)=>code==5,
                Expected::VerifyName(_)=>self.read.allows_command(code),
                Expected::Held=>false,Expected::Query(..)=>code==16,Expected::Read(..)=>code==8,
                Expected::Write(..)=>code==9,Expected::SetLength(_)=>code==17,
                Expected::Flush=>code==7,Expected::Close=>code==6,
            },
        }
    }
    pub fn permits_frame(&self,raw:&[u8]) -> bool {
        if !(64..=256*1024).contains(&raw.len()) || !raw.starts_with(b"\xfeSMB")
            || u16_at(raw,4)!=64 || u32_at(raw,20)!=0 { return false; }
        let state=self.state.lock().unwrap();
        let (tree,session,file,expected)=match &*state {
            State::Active{tree,session,file,expected}=>(*tree,*session,*file,expected),
            _=>return false,
        };
        let code=u16_at(raw,12);
        if u32_at(raw,16)&!8!=0 || u64_at(raw,40)!=session { return false; }
        if matches!(code,2|4|12|13) {
            return raw.len()==68 && u16_at(raw,64)==4 && raw[66..68]==[0,0]
                && (code!=4 || u32_at(raw,36)==tree);
        }
        if u32_at(raw,36)!=tree { return false; }
        if let Expected::VerifyName(name)=expected {
            if code==5 && (raw.len()!=120+name.len() || raw.get(120..)!=Some(name.as_slice())) { return false; }
            return self.read.permits_frame(raw);
        }
        let body=&raw[64..];
        match (code,expected) {
            (5,Expected::Open(name))=>body.len()==56+name.len() && u16_at(body,0)==57
                && body[2..4]==[0,0] && u32_at(body,4)==2 && body[8..24]==[0;16]
                && u32_at(body,24)==ACCESS && u32_at(body,28)==0 && u32_at(body,32)==1
                && u32_at(body,36)==1 && u32_at(body,40)==OPTIONS && u16_at(body,44)==120
                && usize::from(u16_at(body,46))==name.len() && body[48..56]==[0;8]
                && body[56..]==*name,
            (16,Expected::Query(info,class,cap))=>body.len()==40 && u16_at(body,0)==41
                && body[2]==*info && body[3]==*class && u32_at(body,4)==*cap
                && body[8..24]==[0;16] && file.is_some_and(|id|same_file(body,24,id)),
            (8,Expected::Read(offset,length))=>body.len()==49 && *length>0 && *length<=CHUNK
                && u16_at(body,0)==49 && body[2..4]==[0;2] && u32_at(body,4)==*length
                && u64_at(body,8)==*offset && body[32..]==[0;17]
                && file.is_some_and(|id|same_file(body,16,id)),
            (9,Expected::Write(offset,bytes))=>body.len()==48+bytes.len() && u16_at(body,0)==49
                && u16_at(body,2)==112 && u32_at(body,4)==bytes.len() as u32
                && u64_at(body,8)==*offset && body[32..48]==[0;16] && body[48..]==*bytes
                && file.is_some_and(|id|same_file(body,16,id)),
            (17,Expected::SetLength(length))=>body.len()==40 && u16_at(body,0)==33
                && body[2]==1 && body[3]==20 && u32_at(body,4)==8
                && u16_at(body,8)==96 && body[10..16]==[0;6]
                && body[32..40]==*length && file.is_some_and(|id|same_file(body,16,id)),
            (7,Expected::Flush)|(6,Expected::Close)=>body.len()==24 && u16_at(body,0)==24
                && body[2..8]==[0;6] && file.is_some_and(|id|same_file(body,8,id)),
            _=>false,
        }
    }
    fn opened(&self,id:FileId) -> Result<()> {
        if id==FileId::default() || id.persistent==u64::MAX || id.volatile==u64::MAX { return Err(invalid()); }
        let mut state=self.state.lock().unwrap();
        match &mut *state {
            State::Active{file,expected:Expected::Open(_),..}=>{*file=Some(id);
                if let State::Active{expected,..}=&mut *state {*expected=Expected::Held;} Ok(())},
            _=>Err(invalid()),
        }
    }
    fn expect(&self,next:Expected) -> Result<()> {
        let mut state=self.state.lock().unwrap();
        match &mut *state {
            State::Active{file:Some(_),expected,..} if matches!(expected,Expected::Held)=>{*expected=next;Ok(())},
            _=>Err(invalid()),
        }
    }
    fn acknowledged(&self) -> Result<()> {
        let mut state=self.state.lock().unwrap();
        match &mut *state {
            State::Active{expected,..} if matches!(expected,Expected::Query(..)|Expected::Read(..)|Expected::Write(..)|Expected::SetLength(_)|Expected::Flush)
                =>{*expected=Expected::Held;Ok(())},
            _=>Err(invalid()),
        }
    }
    fn closed(&self,verify:Option<&[u16]>) -> Result<()> {
        let mut state=self.state.lock().unwrap();
        let (tree,session)=match &*state {
            State::Active{tree,session,expected:Expected::Close,..}=>(*tree,*session),
            _=>return Err(invalid()),
        };
        *state=if let Some(path)=verify {
            State::Active{tree,session,file:None,expected:Expected::VerifyName(wire_name(path)?)}
        } else { State::Idle };Ok(())
    }
    fn finished(&self) -> Result<()> {
        let mut state=self.state.lock().unwrap();
        if !matches!(*state,State::Active{expected:Expected::VerifyName(_),..}) || !self.read.idle() { return Err(invalid()); }
        *state=State::Idle;Ok(())
    }
    fn poison(&self) { *self.state.lock().unwrap()=State::Poisoned; }
}

pub struct EditBaseline { pub snapshot:FileSnapshot, pub digest:[u8;32] }
pub enum EditPreflight { Ready(CheckedOriginalEdit), Changed }
/// A claimed original handle. Drop on any uncertain step poisons the policy
/// and closes the whole connection. No rename, replacement or rollback exists.
pub struct CheckedOriginalEdit {
    conn:Connection, policy:Arc<SelectedEditPolicy>, tree:TreeId, session:u64,
    file:Option<FileId>, path:Vec<u16>, before:FileSnapshot, ended:bool,
}
impl CheckedOriginalEdit {
    pub async fn prepare(conn:Connection,tree:TreeId,path:&[u16],baseline:EditBaseline) -> Result<EditPreflight> {
        if !acceptable(&baseline.snapshot) { return Err(invalid()); }
        let policy=conn.selected_upload_policy()?.begin_edit(tree,conn.session_id().0,path)?;
        let mut value=Self{session:conn.session_id().0,conn,policy,tree,file:None,path:path.to_vec(),before:baseline.snapshot,ended:false};
        let request=CreateRequest{requested_oplock_level:OplockLevel::None,
            impersonation_level:ImpersonationLevel::Impersonation,desired_access:FileAccessMask::new(ACCESS),
            file_attributes:0,share_access:ShareAccess(1),
            create_disposition:CreateDisposition::FileOpen,create_options:OPTIONS,
            name:String::from_utf16(path).map_err(|_|invalid())?,create_contexts:vec![]};
        let frame=value.conn.execute(Command::Create,&request,Some(tree)).await?;
        let raw=d1::response(&frame,Command::Create,tree,value.session)?;d1::success(&frame)?;
        if raw.len()!=152 || u16_at(raw,64)!=89 || raw[66..68]!=[0,0]
            || u32_at(raw,144)!=0 || u32_at(raw,148)!=0 { return Err(invalid()); }
        let opened=CreateResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        value.policy.opened(opened.file_id)?;value.file=Some(opened.file_id);
        if opened.create_action!=CreateAction::FileOpened || !acceptable(&value.before)
            || opened.end_of_file!=value.before.size || opened.file_attributes!=value.before.attributes
            || opened.creation_time.0!=value.before.created || opened.last_write_time.0!=value.before.modified
            || opened.change_time.0!=value.before.changed {
            value.close(None).await?;return Ok(EditPreflight::Changed);
        }
        let observed=value.observe(None).await?;
        if observed!=value.before || !acceptable(&observed)
            || value.digest(value.before.size).await?!=baseline.digest
            || value.observe(None).await?!=value.before {
            value.close(None).await?;return Ok(EditPreflight::Changed);
        }
        Ok(EditPreflight::Ready(value))
    }
    fn handle(&self) -> Result<FileId> { self.file.ok_or_else(invalid) }
    async fn query(&mut self,info:u8,class:u8,cap:u32) -> Result<Vec<u8>> {
        self.policy.expect(Expected::Query(info,class,cap))?;
        let request=QueryInfoRequest{info_type:if info==1{InfoType::File}else{InfoType::Filesystem},
            file_info_class:class,output_buffer_length:cap,additional_information:0,flags:0,
            file_id:self.handle()?,input_buffer:vec![]};
        let frame=self.conn.execute(Command::QueryInfo,&request,Some(self.tree)).await?;
        let data=d1::query_bytes(&frame,cap,self.tree,self.session)?.to_vec();
        self.policy.acknowledged()?;Ok(data)
    }
    async fn observe(&mut self,checkpoint:Option<&AtomicU8>) -> Result<FileSnapshot> {
        mark(checkpoint,15);
        let basic=self.query(1,4,40).await?;
        mark(checkpoint,16);
        let standard=self.query(1,5,24).await?;
        mark(checkpoint,17);
        let internal=self.query(1,6,8).await?;
        mark(checkpoint,18);
        let volume=self.query(2,1,1042).await?;
        mark(checkpoint,19);
        if basic.len()!=40 { return Err(invalid()); }
        mark(checkpoint,20);
        if standard.len()!=24 { return Err(invalid()); }
        mark(checkpoint,21);
        if internal.len()!=8 { return Err(invalid()); }
        mark(checkpoint,22);
        if volume.len()<18 { return Err(invalid()); }
        let label=u32_at(&volume,12) as usize;
        mark(checkpoint,23);
        if standard[20..22]!=[0,0] { return Err(invalid()); }
        mark(checkpoint,24);
        if volume[16]>1 || label%2!=0 || label>1024 || 18+label!=volume.len() { return Err(invalid()); }
        Ok(FileSnapshot{size:u64_at(&standard,8),allocated:u64_at(&standard,0),
            created:u64_at(&basic,0),modified:u64_at(&basic,16),changed:u64_at(&basic,24),
            attributes:u32_at(&basic,32),links:u32_at(&standard,16),index:u64_at(&internal,0),
            volume_created:u64_at(&volume,0),volume_serial:u32_at(&volume,8)})
    }
    async fn read(&mut self,offset:u64,length:u32) -> Result<Option<Vec<u8>>> {
        if length==0 || length>CHUNK || self.conn.params().is_none_or(|p|length>p.max_read_size) { return Err(invalid()); }
        self.policy.expect(Expected::Read(offset,length))?;
        let request=ReadRequest{padding:0,flags:0,length,offset,file_id:self.handle()?,
            minimum_count:0,channel:0,remaining_bytes:0,read_channel_info:vec![]};
        let frame=self.conn.execute(Command::Read,&request,Some(self.tree)).await?;
        let data=d1::read_bytes(&frame,length,self.tree,self.session)?;
        self.policy.acknowledged()?;Ok(data)
    }
    async fn digest(&mut self,size:u64) -> Result<[u8;32]> {
        let mut hash=Sha256::new();let mut offset=0u64;
        let max_read=self.conn.params().ok_or_else(invalid)?.max_read_size;
        while offset<size {
            let length=(size-offset).min(u64::from(CHUNK)).min(u64::from(max_read)) as u32;
            let bytes=self.read(offset,length).await?.ok_or_else(invalid)?;
            if bytes.is_empty() || bytes.len()>length as usize { return Err(invalid()); }
            offset+=bytes.len() as u64;hash.update(&bytes);
        }
        if self.read(size,1).await?.is_some() { return Err(invalid()); }
        Ok(hash.finalize().into())
    }
    async fn close(&mut self,verify:Option<&[u16]>) -> Result<()> {
        self.policy.expect(Expected::Close)?;
        let frame=self.conn.execute(Command::Close,&CloseRequest{flags:0,file_id:self.handle()?},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Close,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=124 || u16_at(raw,64)!=60 || u16_at(raw,66)!=0 { return Err(invalid()); }
        self.policy.closed(verify)?;self.file=None;
        if verify.is_none() { self.ended=true; }
        Ok(())
    }
    /// Call only after the caller's durable mutation intent has been ACKed.
    /// This is the first method permitted to submit a remote mutation.
    pub async fn write_and_verify(mut self,edited:&[u8],expected:&[u8;32],
        attribute_contract:EditAttributeContract, checkpoint:&AtomicU8) -> Result<FileSnapshot> {
        if edited.len()>MAX_TEXT as usize || Sha256::digest(edited).as_slice()!=expected { return Err(invalid()); }
        let max_write=self.conn.params().ok_or_else(invalid)?.max_write_size.min(CHUNK).max(1);
        // Diagnostic only: the value names the boundary entered, not an ACK or
        // proof that the remote mutation completed. It contains no file data.
        checkpoint.store(3,Ordering::Release);
        let mut offset=0usize;
        for bytes in edited.chunks(max_write as usize) {
            self.policy.expect(Expected::Write(offset as u64,bytes.to_vec()))?;
            let mut pipe=WritePipe::new(self.conn.clone(),self.tree,self.handle()?,max_write);
            pipe.set_chunk_size(max_write);pipe.set_offset(offset as u64);
            pipe.send(bytes.to_vec()).await?;pipe.drain().await?;
            if pipe.confirmed()!=bytes.len() as u64 || pipe.offset()!=offset as u64+bytes.len() as u64 { return Err(invalid()); }
            self.policy.acknowledged()?;offset+=bytes.len();
        }
        checkpoint.store(4,Ordering::Release);
        let length=(edited.len() as u64).to_le_bytes();
        self.policy.expect(Expected::SetLength(length))?;
        let request=SetInfoRequest{info_type:InfoType::File,file_info_class:20,additional_information:0,
            file_id:self.handle()?,buffer:length.to_vec()};
        let frame=self.conn.execute(Command::SetInfo,&request,Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::SetInfo,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=66 || u16_at(raw,64)!=2 { return Err(invalid()); }
        self.policy.acknowledged()?;
        checkpoint.store(5,Ordering::Release);
        self.policy.expect(Expected::Flush)?;
        let frame=self.conn.execute(Command::Flush,&FlushRequest{file_id:self.handle()?},Some(self.tree)).await?;
        let raw=d1::response(&frame,Command::Flush,self.tree,self.session)?;d1::success(&frame)?;
        if raw.len()!=68 || u16_at(raw,64)!=4 || raw[66..68]!=[0,0] { return Err(invalid()); }
        self.policy.acknowledged()?;
        checkpoint.store(6,Ordering::Release);
        let after=self.observe(Some(checkpoint)).await?;
        if let Some(code)=first_postwrite_mismatch(&self.before,&after,attribute_contract) {
            checkpoint.store(code,Ordering::Release);return Err(invalid());
        }
        checkpoint.store(28,Ordering::Release);
        if after.size!=edited.len() as u64 { return Err(invalid()); }
        checkpoint.store(29,Ordering::Release);
        if !acceptable(&after) { return Err(invalid()); }
        checkpoint.store(7,Ordering::Release);
        if self.digest(after.size).await?!=*expected { return Err(invalid()); }
        checkpoint.store(8,Ordering::Release);
        let checked=self.observe(None).await?;
        if !same_object(&after,&checked,attribute_contract) || after.size!=checked.size || after.modified!=checked.modified
            || after.changed!=checked.changed { return Err(invalid()); }
        checkpoint.store(9,Ordering::Release);
        let path=self.path.clone();self.close(Some(&path)).await?;
        checkpoint.store(10,Ordering::Release);
        let mut current=CheckedFileReader::prepare_published(self.conn.clone(),self.tree,&path,&checked).await?;
        if !same_object(&checked,current.snapshot(),attribute_contract) || current.snapshot().size!=checked.size { return Err(invalid()); }
        checkpoint.store(11,Ordering::Release);
        let mut hash=Sha256::new();let mut seen=0u64;
        while seen<checked.size {
            let bytes=current.read_chunk().await?;
            if bytes.is_empty() { return Err(invalid()); }
            seen+=bytes.len() as u64;hash.update(&bytes);
        }
        let final_snapshot=current.finish().await?;
        if seen!=checked.size || hash.finalize().as_slice()!=expected || !same_object(&checked,&final_snapshot,attribute_contract) {
            return Err(invalid());
        }
        checkpoint.store(12,Ordering::Release);
        self.policy.finished()?;self.ended=true;Ok(final_snapshot)
    }
}
impl Drop for CheckedOriginalEdit {
    fn drop(&mut self) { if !self.ended { self.policy.poison();self.conn.mark_dead(); } }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn archive_write_v2_is_the_only_first_postwrite_attribute_extension() {
        let v1=EditAttributeContract::ExactV1;
        let v2=EditAttributeContract::ArchiveWriteV2;
        assert!(!v1.permits_first_postwrite(0x80,0x20));
        for (before,after) in [(0x80,0x20),(0x02,0x22),(0x02,0x02),(0x20,0x20)] {
            assert!(v2.permits_first_postwrite(before,after));
        }
        for (before,after) in [(0x80,0xa0),(0x22,0x02),(0x02,0x20),(0,0x20),
            (0x01,0x02),(0x20,0)] {
            assert!(!v2.permits_first_postwrite(before,after));
        }
        let baseline=FileSnapshot{size:3,allocated:4096,created:11,modified:12,changed:13,
            attributes:0x80,links:1,index:17,volume_created:18,volume_serial:19};
        let mut after=baseline.clone();after.attributes=0x20;
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v2),None);
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v1),Some(26));
        assert!(!same_object(&baseline,&after,v2));
        after.index+=1;
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v2),Some(25));
        after.index-=1;after.links=2;
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v2),Some(27));
    }
    #[test]
    fn v3_first_postwrite_allows_approximate_creation_facts_on_the_held_original() {
        let baseline=FileSnapshot{size:18,allocated:4096,created:11,modified:12,changed:13,
            attributes:0x80,links:1,index:40,volume_created:18,volume_serial:19};
        let mut after=baseline.clone();
        after.size=20;after.modified=21;after.changed=22;after.attributes=0x20;
        after.created=23;after.volume_created=24;
        let v3=EditAttributeContract::ArchiveWriteCreationApproxV3;
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v3),None);
        assert_eq!(first_postwrite_mismatch(&baseline,&after,EditAttributeContract::ArchiveWriteV2),Some(25));
        assert_eq!(first_postwrite_mismatch(&baseline,&after,EditAttributeContract::ExactV1),Some(25));
        after.index=41;
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v3),Some(25));
        after.index=40;after.volume_serial=20;
        assert_eq!(first_postwrite_mismatch(&baseline,&after,v3),Some(25));
        after.volume_serial=19;
        assert!(!same_object(&baseline,&after,v3)); // Attribute transition only at the first check.
        after.attributes=0x80;
        assert!(same_object(&baseline,&after,v3));
        assert!(!same_object(&baseline,&after,EditAttributeContract::ArchiveWriteV2));
        after.links=2;
        assert!(!same_object(&baseline,&after,v3));
    }
    fn frame(code:u16,body:Vec<u8>)->Vec<u8>{
        let mut raw=vec![0;64];raw[..4].copy_from_slice(b"\xfeSMB");
        raw[4..6].copy_from_slice(&64u16.to_le_bytes());
        raw[12..14].copy_from_slice(&code.to_le_bytes());
        raw[36..40].copy_from_slice(&7u32.to_le_bytes());
        raw[40..48].copy_from_slice(&11u64.to_le_bytes());
        raw.extend(body);raw
    }
    #[test]
    fn exact_original_create_and_mutation_frames_only() {
        let policy=SelectedEditPolicy::new(SelectedDownloadPolicy::new());
        let name=wire_name(&[b'f' as u16]).unwrap();
        let mut create=vec![0;56+name.len()];
        create[..2].copy_from_slice(&57u16.to_le_bytes());
        create[4..8].copy_from_slice(&2u32.to_le_bytes());
        create[24..28].copy_from_slice(&ACCESS.to_le_bytes());
        create[32..36].copy_from_slice(&1u32.to_le_bytes());
        create[36..40].copy_from_slice(&1u32.to_le_bytes());
        create[40..44].copy_from_slice(&OPTIONS.to_le_bytes());
        create[44..46].copy_from_slice(&120u16.to_le_bytes());
        create[46..48].copy_from_slice(&(name.len() as u16).to_le_bytes());
        create[56..].copy_from_slice(&name);
        assert!(!policy.permits_frame(&frame(5,create.clone())));
        policy.begin(TreeId(7),11,&[b'f' as u16]).unwrap();
        assert!(policy.permits_frame(&frame(5,create.clone())));
        let mut overwrite=create.clone();overwrite[36]=5;
        assert!(!policy.permits_frame(&frame(5,overwrite)));
        let mut delete=create.clone();delete[24..28].copy_from_slice(&(ACCESS|FileAccessMask::DELETE).to_le_bytes());
        assert!(!policy.permits_frame(&frame(5,delete)));
        assert!(!policy.permits_frame(&frame(9,vec![0;49])));
        let id=FileId{persistent:13,volatile:17};policy.opened(id).unwrap();
        let mut write=vec![0;49];write[..2].copy_from_slice(&49u16.to_le_bytes());
        write[2..4].copy_from_slice(&112u16.to_le_bytes());
        write[4..8].copy_from_slice(&1u32.to_le_bytes());
        write[16..24].copy_from_slice(&13u64.to_le_bytes());
        write[24..32].copy_from_slice(&17u64.to_le_bytes());write[48]=b'A';
        assert!(!policy.permits_frame(&frame(9,write.clone())));
        policy.expect(Expected::Write(0,vec![b'A'])).unwrap();
        assert!(policy.permits_frame(&frame(9,write.clone())));
        write[8]=1;assert!(!policy.permits_frame(&frame(9,write)));
        assert!(!policy.permits_frame(&frame(17,vec![0;40])));
    }
}
