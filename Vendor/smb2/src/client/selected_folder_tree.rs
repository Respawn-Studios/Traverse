//! Concrete checked tree transaction and acknowledged one-chunk receiver.
use super::*;
use std::collections::HashSet;
#[derive(Clone)]
/// Parent-first metadata. Only this module constructs the admitted manifest.
pub struct FolderNode{
    /// Parent ordinal; only the selected root has none.
    pub parent:Option<usize>,
    /// Literal class37 entry; root spelling stays in the sealed selection.
    pub entry:Option<FolderEntry>,
    /// Fresh directory facts for a directory node.
    pub directory:Option<DirectorySnapshot>,
    /// Fresh same-handle file facts for a regular member.
    pub file:Option<d1::FileSnapshot>,
}
impl FolderNode{
    /// Directory kind, including root.
    pub fn is_directory(&self)->bool{self.directory.is_some()}
}
struct Frame{directory:HeldDirectory,ordinal:usize,children:Vec<FolderEntry>,next:usize}
#[derive(Clone,Copy)]enum Phase{Prepared,Checking,Ready,Start,Reading,End,Ack{offset:u64},Done,Failed}
/// At most one data event awaits its exact consumer append acknowledgment.
pub enum FolderReadEvent{
    /// Next admitted file, before any body event.
    MemberStarted{
        /// Parent-first manifest ordinal.
        ordinal:usize,
        /// Expected file bytes.
        bytes:u64
    },
    /// One bounded positioned body chunk.
    Bytes{
        /// Exact admitted member.
        ordinal:usize,
        /// Positioned member offset.
        offset:u64,
        /// At most one 32 KiB chunk.
        bytes:Vec<u8>
    },
    /// Actual EOF/postcheck/CLOSE completed for one member.
    MemberFinished{
        /// Closed member ordinal.
        ordinal:usize,
        /// Exact acknowledged bytes.
        bytes:u64
    },
    /// Full membership recheck and all directory CLOSEs completed.
    Complete{
        /// Sum of acknowledged member bytes.
        bytes:u64,
        /// Number of completed regular files.
        files:usize
    },
}
/// One reviewed root, one immutable manifest and at most one checked file.
/// Errors/cancellation retain whole-session teardown; this is no snapshot API.
pub struct PreparedFolder{
    owner:Option<CheckedFolderReader>,root:Option<HeldDirectory>,nodes:Vec<FolderNode>,
    files:usize,folders:usize,bytes:u64,longest:usize,phase:Phase,cursor:usize,
    parents:Vec<(usize,HeldDirectory)>,file:Option<d1::CheckedFileReader>,offset:u64,
    received:u64,completed:usize,
}
fn components(nodes:&[FolderNode],mut index:usize)->Result<Vec<Vec<u16>>>{
    let mut parts=Vec::new();let mut seen=HashSet::new();
    while index!=0{
        if parts.len()>=MAX_DEPTH||!seen.insert(index){return Err(invalid());}
        let node=nodes.get(index).ok_or_else(invalid)?;let parent=node.parent.ok_or_else(invalid)?;
        if parent>=index{return Err(invalid());}parts.push(node.entry.as_ref().ok_or_else(invalid)?.name.clone());index=parent;
    }
    parts.reverse();Ok(parts)
}
fn same_file(a:&d1::FileSnapshot,b:&d1::FileSnapshot)->bool{
    a.size==b.size&&a.allocated==b.allocated&&a.modified==b.modified&&a.changed==b.changed&&a.attributes==b.attributes
        &&a.links==b.links&&a.index==b.index&&a.volume_serial==b.volume_serial
}
impl PreparedFolder{
    /// Fully inspect a root and regular members without a single body READ.
    pub async fn prepare(conn:Connection,tree:TreeId,path:&[u16],attributes:u32,modified:u64)->Result<Self>{
        let(owner,root)=CheckedFolderReader::prepare(conn,tree,path,attributes,modified).await?;
        Self::prepare_from_root(owner,root).await
    }
    /// Independently inspect an F2 root after its no-replace publication.
    pub async fn prepare_published(conn:Connection,tree:TreeId,path:&[u16])->Result<Self>{
        let(owner,root)=CheckedFolderReader::prepare_published(conn,tree,path).await?;
        Self::prepare_from_root(owner,root).await
    }
    /// Inspect F2's held private root without reopening or closing its root
    /// handle. Only metadata is gathered; no member READ is admitted.
    pub(crate) async fn prepare_borrowed(conn:Connection,tree:TreeId,path:&[u16],file:FileId,snapshot:DirectorySnapshot)->Result<Self>{
        let(owner,root)=CheckedFolderReader::prepare_borrowed(conn,tree,path,file,snapshot)?;
        Self::prepare_from_root(owner,root).await
    }
    async fn prepare_from_root(owner:CheckedFolderReader,root:HeldDirectory)->Result<Self>{
        let mut nodes=vec![FolderNode{parent:None,entry:None,directory:Some(root.snapshot.clone()),file:None}];
        let mut identities=HashSet::from([(root.snapshot.volume,root.snapshot.index)]);
        let children=owner.children(&root).await?;let mut frames=vec![Frame{directory:root,ordinal:0,children,next:0}];
        let(mut files,mut folders,mut bytes,mut path_bytes,mut longest)=(0usize,0usize,0u64,0usize,0usize);
        let root=loop{
            let depth=frames.len();
            let top=frames.last_mut().ok_or_else(invalid)?;
            if top.next==top.children.len(){
                let end=frames.pop().ok_or_else(invalid)?;
                if frames.is_empty(){break end.directory;}owner.close(end.directory).await?;continue;
            }
            let parent=top.ordinal;let entry=top.children[top.next].clone();top.next+=1;
            if nodes.len()>=MAX_NODES||depth>MAX_DEPTH||!identities.insert((top.directory.snapshot.volume,entry.index)){return Err(invalid());}
            let ordinal=nodes.len();
            if entry.directory(){
                let child=owner.open_child(&top.directory,&entry).await?;
                let children=owner.children(&child).await?;
                nodes.push(FolderNode{parent:Some(parent),entry:Some(entry),directory:Some(child.snapshot.clone()),file:None});
                frames.push(Frame{directory:child,ordinal,children,next:0});folders=folders.checked_add(1).ok_or_else(invalid)?;
            }else{
                if files>=MAX_FILES{return Err(invalid());}
                let file=owner.prepare_file(&top.directory,&entry).await?;let facts=file.snapshot().clone();
                bytes=bytes.checked_add(facts.size).filter(|v|*v<=owner.byte_limit()).ok_or_else(invalid)?;
                file.release().await?;owner.member_closed()?;
                nodes.push(FolderNode{parent:Some(parent),entry:Some(entry),directory:None,file:Some(facts)});files+=1;
            }
            let parts=components(&nodes,ordinal)?;
            let length=parts.iter().try_fold(parts.len().saturating_sub(1),|n,p|String::from_utf16(p).map_err(|_|invalid()).and_then(|s|n.checked_add(s.len()).ok_or_else(invalid)))?;
            path_bytes=path_bytes.checked_add(length).filter(|v|*v<=4<<20).ok_or_else(invalid)?;longest=longest.max(length);
        };
        if nodes.len()!=1+files+folders{return Err(invalid());}
        Ok(Self{owner:Some(owner),root:Some(root),nodes,files,folders,bytes,longest,phase:Phase::Prepared,cursor:0,
            parents:Vec::new(),file:None,offset:0,received:0,completed:0})
    }
    /// Exact immutable parent-first observed nodes.
    pub fn nodes(&self)->&[FolderNode]{&self.nodes}
    /// Number of regular files.
    pub fn files(&self)->usize{self.files}
    /// Number of subfolders, excluding the selected root.
    pub fn folders(&self)->usize{self.folders}
    /// Exact bounded sum of prepared regular file sizes.
    pub fn logical_bytes(&self)->u64{self.bytes}
    /// Stable filesystem identity from the checked root, when available.
    pub fn root_identity(&self)->Option<(u32,u64)>{self.nodes.first()?.directory.as_ref().map(|v|(v.volume,v.index))}
    /// Maximum local relative UTF-8 path length.
    pub fn longest_path_bytes(&self)->usize{self.longest}
    /// Cancel a preparation with acknowledged root CLOSE and no body read.
    pub async fn release(mut self)->Result<()>{
        if !matches!(self.phase,Phase::Prepared){return Err(invalid());}
        self.phase=Phase::Failed;let owner=self.owner.take().ok_or_else(invalid)?;
        owner.release_root(self.root.take().ok_or_else(invalid)?).await?;owner.finish()
    }
    async fn verify_tree(&self)->Result<()>{
        let owner=self.owner.as_ref().ok_or_else(invalid)?;let root=self.root.as_ref().ok_or_else(invalid)?;
        owner.revalidate_path(root).await?;
        let mut frames=vec![VerifyFrame{directory:None,ordinal:0,children:owner.children(root).await?,next:0}];
        loop{
            let top=frames.last_mut().ok_or_else(invalid)?;
            let expected=self.nodes.iter().enumerate().filter(|(_,n)|n.parent==Some(top.ordinal)).collect::<Vec<_>>();
            if top.children.len()!=expected.len()||!top.children.iter().zip(&expected).all(|(a,(_,b))|b.entry.as_ref()==Some(a)){return Err(invalid());}
            if top.next==expected.len(){let end=frames.pop().ok_or_else(invalid)?;if let Some(directory)=end.directory{owner.close(directory).await?;}if frames.is_empty(){return Ok(());}continue;}
            let(ordinal,node)=expected[top.next];top.next+=1;
            if node.is_directory(){
                let parent=top.directory.as_ref().unwrap_or(root);let child=owner.open_child(parent,node.entry.as_ref().ok_or_else(invalid)?).await?;
                if node.directory.as_ref()!=Some(&child.snapshot){return Err(invalid());}
                let children=owner.children(&child).await?;
                frames.push(VerifyFrame{directory:Some(child),ordinal,children,next:0});
            }
        }
    }
    /// Revalidate the full observed tree after explicit user acceptance.
    pub async fn begin(&mut self)->Result<()>{
        if !matches!(self.phase,Phase::Prepared){return Err(invalid());}self.phase=Phase::Checking;
        self.verify_tree().await?;self.phase=Phase::Ready;Ok(())
    }
    async fn parents_for(&mut self,ordinal:usize)->Result<()>{
        let mut wanted=Vec::new();let mut cursor=self.nodes.get(ordinal).ok_or_else(invalid)?.parent.ok_or_else(invalid)?;
        while cursor!=0{if wanted.len()>=MAX_DEPTH{return Err(invalid());}wanted.push(cursor);cursor=self.nodes[cursor].parent.ok_or_else(invalid)?;}
        wanted.reverse();let common=self.parents.iter().zip(&wanted).take_while(|((index,_),wanted)|index==*wanted).count();
        let owner=self.owner.as_ref().ok_or_else(invalid)?;
        while self.parents.len()>common{let(_,directory)=self.parents.pop().ok_or_else(invalid)?;owner.close(directory).await?;}
        for ordinal in wanted.into_iter().skip(common){
            let parent=self.parents.last().map(|(_,d)|d).or(self.root.as_ref()).ok_or_else(invalid)?;
            let node=&self.nodes[ordinal];let child=owner.open_child(parent,node.entry.as_ref().ok_or_else(invalid)?).await?;
            if node.directory.as_ref()!=Some(&child.snapshot){return Err(invalid());}self.parents.push((ordinal,child));
        }
        Ok(())
    }
    /// One event. A Bytes event must be acknowledged before another call.
    pub async fn next(&mut self)->Result<FolderReadEvent>{
        if matches!(self.phase,Phase::End){self.cursor=self.cursor.checked_add(1).ok_or_else(invalid)?;self.phase=Phase::Ready;}
        match self.phase{
            Phase::Ready=>{
                self.phase=Phase::Checking;
                while self.cursor<self.nodes.len()&&self.nodes[self.cursor].is_directory(){self.cursor+=1;}
                if self.cursor==self.nodes.len(){
                    let owner=self.owner.as_ref().ok_or_else(invalid)?;
                    while let Some((_,directory))=self.parents.pop(){owner.close(directory).await?;}
                    self.verify_tree().await?;
                    if self.received!=self.bytes||self.completed!=self.files{return Err(invalid());}
                    let owner=self.owner.take().ok_or_else(invalid)?;owner.close(self.root.take().ok_or_else(invalid)?).await?;owner.finish()?;
                    self.phase=Phase::Done;return Ok(FolderReadEvent::Complete{bytes:self.received,files:self.completed});
                }
                self.parents_for(self.cursor).await?;
                let owner=self.owner.as_ref().ok_or_else(invalid)?;let parent=self.parents.last().map(|(_,d)|d).or(self.root.as_ref()).ok_or_else(invalid)?;
                let node=&self.nodes[self.cursor];let file=owner.prepare_file(parent,node.entry.as_ref().ok_or_else(invalid)?).await?;
                if !same_file(file.snapshot(),node.file.as_ref().ok_or_else(invalid)?){return Err(invalid());}
                owner.permit_file_body()?;self.file=Some(file);self.offset=0;self.phase=Phase::Start;
                Ok(FolderReadEvent::MemberStarted{ordinal:self.cursor,bytes:node.file.as_ref().ok_or_else(invalid)?.size})
            },
            Phase::Start|Phase::Reading=>{
                self.phase=Phase::Checking;let file=self.file.as_mut().ok_or_else(invalid)?;
                if self.offset==file.snapshot().size{
                    let bytes=self.offset;self.file.take().ok_or_else(invalid)?.finish().await?;self.owner.as_ref().ok_or_else(invalid)?.member_closed()?;
                    self.completed=self.completed.checked_add(1).ok_or_else(invalid)?;self.phase=Phase::End;
                    return Ok(FolderReadEvent::MemberFinished{ordinal:self.cursor,bytes});
                }
                let offset=self.offset;let bytes=file.read_chunk().await?;
                let next=offset.checked_add(bytes.len()as u64).filter(|v|*v<=file.snapshot().size).ok_or_else(invalid)?;
                if bytes.is_empty(){return Err(invalid());}self.phase=Phase::Ack{offset:next};Ok(FolderReadEvent::Bytes{ordinal:self.cursor,offset,bytes})
            },
            _=>Err(invalid()),
        }
    }
    /// Only the exact completed local append can release one pending chunk.
    pub fn acknowledge(&mut self,ordinal:usize,offset:u64)->Result<()>{
        match self.phase{Phase::Ack{offset:expected}if ordinal==self.cursor&&offset==expected&&offset>self.offset=>{
            self.received=self.received.checked_add(offset-self.offset).filter(|v|*v<=self.bytes).ok_or_else(invalid)?;
            self.offset=offset;self.phase=Phase::Reading;Ok(())},_=>Err(invalid()),}
    }
}
struct VerifyFrame{directory:Option<HeldDirectory>,ordinal:usize,children:Vec<FolderEntry>,next:usize}
