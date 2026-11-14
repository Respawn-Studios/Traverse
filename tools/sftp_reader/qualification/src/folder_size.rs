//! One selected-folder logical size observation. The metadata channel exposes
//! LSTAT, REALPATH, OPENDIR, READDIR and CLOSE only; no transfer is prepared.
use crate::{folder_download::{Failure as ChannelFailure,MetadataChannel},reader,wire::{Entry,Metadata}};
use std::{collections::HashSet,time::{Duration,Instant}};

const MAX_NODES:usize=32768;
const MAX_LISTING_ENTRIES:usize=4096;
const MAX_DEPTH:usize=32;
const MAX_PATH_BYTES:usize=8192;
const MAX_ENCODED_PATH_BYTES:usize=4<<20;
const MAX_BATCHES:usize=MAX_LISTING_ENTRIES+1;
const SCAN_BUDGET:Duration=Duration::from_secs(60);

/// Fixed result reasons shared with SMB; only a complete result has a total.
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
#[repr(u8)]pub(crate) enum Unavailable{Stale=1,Denied=2,Changed=3,Unsupported=4,Limit=5,Deadline=6,Unavailable=7}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub(crate) enum Failure{Reason(Unavailable),Channel(reader::Failure),Close}
type Result<T>=std::result::Result<T,Failure>;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub(crate) struct Summary{pub bytes:u64,pub files:u32,pub folders:u32,pub excluded_links:u32}

fn channel(error:ChannelFailure)->Failure{match error{
    ChannelFailure::Metadata(error)=>Failure::Channel(error),
    ChannelFailure::Changed=>Failure::Reason(Unavailable::Changed),
    ChannelFailure::Limit=>Failure::Reason(Unavailable::Limit),
    ChannelFailure::Input|ChannelFailure::Output=>Failure::Reason(Unavailable::Unsupported),
}}
fn name(value:&str)->bool{!value.is_empty()&&value.len()<=255&&value!="."&&value!=".."&&!value.contains(['/', '\0'])}
fn root(path:&str)->bool{path.starts_with('/')&&path.len()<=MAX_PATH_BYTES&&!path.contains('\0')&&
    (path=="/"||!path.split('/').skip(1).any(|part|!name(part)))}
fn child(parent:&str,name:&str)->Result<String>{
    if !self::name(name){return Err(Failure::Reason(Unavailable::Unsupported))}
    let mut path=parent.trim_end_matches('/').to_owned();path.push('/');path.push_str(name);
    if path.len()>MAX_PATH_BYTES{return Err(Failure::Reason(Unavailable::Limit))}Ok(path)
}
fn kind(metadata:Metadata)->Result<u32>{metadata.permissions.map(|mode|mode&0o170000)
    .ok_or(Failure::Reason(Unavailable::Unsupported))}
struct Budget{started:Instant,paths:usize,nodes:usize}
impl Budget{
    fn new(root:&str)->Self{Self{started:Instant::now(),paths:root.len(),nodes:1}}
    fn check(&self)->Result<()>{if self.started.elapsed()>SCAN_BUDGET{Err(Failure::Reason(Unavailable::Deadline))}else{Ok(())}}
    fn add(&mut self,path:&str)->Result<()>{
        self.nodes=self.nodes.checked_add(1).filter(|n|*n<=MAX_NODES).ok_or(Failure::Reason(Unavailable::Limit))?;
        self.paths=self.paths.checked_add(path.len()).filter(|n|*n<=MAX_ENCODED_PATH_BYTES).ok_or(Failure::Reason(Unavailable::Limit))?;
        Ok(())
    }
}
struct Node{path:String,metadata:Metadata,depth:usize}

async fn children<C:MetadataChannel>(source:&mut C,path:&str,expected:Metadata,depth:usize,budget:&mut Budget)->Result<Vec<Node>>{
    budget.check()?;
    if source.canonical(path).await.map_err(channel)?!=path{return Err(Failure::Reason(Unavailable::Changed))}
    budget.check()?;
    source.open(path).await.map_err(channel)?;
    // Once OPENDIR succeeds, every exit awaits exactly one owned CLOSE.
    let gathered=async{
        let mut children=Vec::new();let mut names=HashSet::new();
        for _ in 0..MAX_BATCHES{
            budget.check()?;
            let batch=source.next_size().await.map_err(channel)?;
            budget.check()?;
            let Some(batch)=batch else{return Ok(children)};
            for Entry{name,metadata} in batch{
                if children.len()>=MAX_LISTING_ENTRIES||budget.nodes>=MAX_NODES{
                    return Err(Failure::Reason(Unavailable::Limit));
                }
                let absolute=child(path,&name)?;
                if depth>=MAX_DEPTH{return Err(Failure::Reason(Unavailable::Limit))}
                if !names.insert(name.clone()){return Err(Failure::Reason(Unavailable::Changed))}
                budget.add(&absolute)?;
                children.push(Node{path:absolute,metadata,depth:depth+1});
            }
        }
        Err(Failure::Reason(Unavailable::Limit))
    }.await;
    if source.close().await.is_err(){return Err(Failure::Close)}
    let children=gathered?;
    budget.check()?;
    if source.metadata(path).await.map_err(channel)?!=expected{return Err(Failure::Reason(Unavailable::Changed))}
    budget.check()?;
    Ok(children)
}

pub(crate) async fn summarize<C:MetadataChannel>(source:&mut C,path:&str,expected:Metadata)->Result<Summary>{
    if !root(path){return Err(Failure::Reason(Unavailable::Unsupported))}
    if kind(expected)?!=0o040000{return Err(Failure::Reason(Unavailable::Unsupported))}
    let mut budget=Budget::new(path);let mut pending=vec![Node{path:path.to_owned(),metadata:expected,depth:0}];
    let mut result=Summary{bytes:0,files:0,folders:0,excluded_links:0};
    while let Some(node)=pending.pop(){
        budget.check()?;
        let observed=source.metadata(&node.path).await.map_err(channel)?;
        budget.check()?;
        if observed!=node.metadata{return Err(Failure::Reason(Unavailable::Changed))}
        match kind(observed)?{
            0o040000=>{
                let children=children(source,&node.path,observed,node.depth,&mut budget).await?;
                if node.depth>0{result.folders=result.folders.checked_add(1).ok_or(Failure::Reason(Unavailable::Limit))?;}
                pending.extend(children.into_iter().rev());
            },
            0o100000=>{
                let size=observed.size.ok_or(Failure::Reason(Unavailable::Unsupported))?;
                result.bytes=result.bytes.checked_add(size).ok_or(Failure::Reason(Unavailable::Limit))?;
                result.files=result.files.checked_add(1).ok_or(Failure::Reason(Unavailable::Limit))?;
            },
            0o120000=>result.excluded_links=result.excluded_links.checked_add(1).ok_or(Failure::Reason(Unavailable::Limit))?,
            _=>return Err(Failure::Reason(Unavailable::Unsupported)),
        }
    }
    budget.check()?;Ok(result)
}

#[cfg(test)]mod tests;
