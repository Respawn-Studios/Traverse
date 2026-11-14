//! Bounded selected-folder metadata. No filesystem, credentials, shell or body
//! authority lives here. Equality means observed fields, not stable remote IDs.
use crate::{reader,wire::{Entry,Metadata}};
use std::{collections::HashSet,future::Future,time::{Duration,Instant}};
use tokio::io::{AsyncRead,AsyncWrite};

pub(crate) const MAX_FILES:usize=1024;
pub(crate) const MAX_NODES:usize=2048;
pub(crate) const MAX_DEPTH:usize=32;
pub(crate) const MAX_BYTES:u64=1<<30;
pub(crate) const MAX_COMPONENT_BYTES:usize=4<<20;
pub(crate) const ACTIVE_DEADLINE:Duration=Duration::from_secs(600);
pub(crate) const REVIEW_EXPIRY:Duration=Duration::from_secs(300);
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub(crate) enum Failure{Input,Changed,Limit,Metadata(reader::Failure),Output}
type Result<T>=std::result::Result<T,Failure>;
#[derive(Debug,Clone,PartialEq,Eq)]pub(crate) struct Node{pub parts:Vec<String>,pub metadata:Metadata}
impl Node{pub fn directory(&self)->bool{self.metadata.permissions.is_some_and(|m|m&0o170000==0o040000)}}
#[derive(Debug,Clone,PartialEq,Eq)]pub(crate) struct Manifest{
    pub root:String,pub nodes:Vec<Node>,pub files:usize,pub folders:usize,pub bytes:u64,pub longest:usize,
}
pub(crate) trait MetadataChannel{
    fn metadata(&mut self,path:&str)->impl Future<Output=Result<Metadata>>;
    fn canonical(&mut self,path:&str)->impl Future<Output=Result<String>>;
    fn open(&mut self,path:&str)->impl Future<Output=Result<()>>;
    fn next(&mut self)->impl Future<Output=Result<Option<Vec<Entry>>>>;
    fn next_size(&mut self)->impl Future<Output=Result<Option<Vec<Entry>>>>{self.next()}
    fn close(&mut self)->impl Future<Output=Result<()>>;
}
impl<S:AsyncRead+AsyncWrite+Unpin> MetadataChannel for reader::Reader<S>{
    async fn metadata(&mut self,path:&str)->Result<Metadata>{reader::Reader::metadata(self,path).await.map_err(Failure::Metadata)}
    async fn canonical(&mut self,path:&str)->Result<String>{self.real_path(path).await.map_err(Failure::Metadata)}
    async fn open(&mut self,path:&str)->Result<()>{self.open_directory(path).await.map_err(Failure::Metadata)}
    async fn next(&mut self)->Result<Option<Vec<Entry>>>{self.next_batch().await.map_err(Failure::Metadata)}
    async fn next_size(&mut self)->Result<Option<Vec<Entry>>>{self.next_folder_size_batch().await.map_err(|error|match error{
        reader::Failure::NameLimit=>Failure::Limit,other=>Failure::Metadata(other),
    })}
    async fn close(&mut self)->Result<()>{self.close_directory().await.map_err(Failure::Metadata)}
}
pub(crate) trait Progress{fn changed(&mut self,nodes:usize,bytes:u64)->impl Future<Output=Result<()>>;}
impl<F,Fut> Progress for F where F:FnMut(usize,u64)->Fut,Fut:Future<Output=Result<()>>{
    async fn changed(&mut self,nodes:usize,bytes:u64)->Result<()>{self(nodes,bytes).await}
}
pub(crate) fn path(root:&str,parts:&[String])->Result<String>{
    if !root.starts_with('/')||root.len()>8192||root.contains('\0')||root.split('/').skip(1).any(|p|p.is_empty()||p=="."||p=="..")
        ||parts.iter().any(|p|!component(p)){return Err(Failure::Input)}
    if parts.len()>MAX_DEPTH{return Err(Failure::Limit)}
    let mut value=root.to_owned();for part in parts{value.push('/');value.push_str(part)}
    if value.len()>8192||value.split('/').skip(1).count()>128{return Err(Failure::Limit)}Ok(value)
}
fn component(value:&str)->bool{
    !value.is_empty()&&value.len()<=255&&value!="."&&value!=".."&&!value.contains(['/',':'])
        &&!value.chars().any(|c|c.is_control()||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'))
}
fn admitted(metadata:Metadata)->Result<bool>{
    if metadata.modified.is_none(){return Err(Failure::Input)}
    match metadata.permissions.map(|m|m&0o170000){Some(0o040000)=>Ok(true),
        Some(0o100000)if metadata.size.is_some_and(|s|s<=MAX_BYTES)=>Ok(false),_=>Err(Failure::Input)}
}

pub(crate) async fn collect<C:MetadataChannel,P:Progress>(source:&mut C,root:&str,expected:Metadata,mut progress:P)->Result<Manifest>{
    if !admitted(expected)?{return Err(Failure::Input)}path(root,&[])?;
    let mut pending=vec![Node{parts:vec![],metadata:expected}];let mut nodes=Vec::new();
    let(mut files,mut folders,mut bytes,mut component_bytes,mut longest)=(0usize,0usize,0u64,0usize,0usize);
    while let Some(node)=pending.pop(){
        let directory=admitted(node.metadata)?;let absolute=path(root,&node.parts)?;
        if source.metadata(&absolute).await?!=node.metadata{return Err(Failure::Changed)}
        progress.changed(nodes.len(),bytes).await?;
        if directory{
            if source.canonical(&absolute).await?.as_bytes()!=absolute.as_bytes(){return Err(Failure::Changed)}
            progress.changed(nodes.len(),bytes).await?;
            source.open(&absolute).await?;let mut children=Vec::new();let mut names=HashSet::new();
            progress.changed(nodes.len(),bytes).await?;
            loop{
                let batch=source.next().await?;progress.changed(nodes.len()+children.len(),bytes).await?;
                let Some(batch)=batch else{break};
                for entry in batch{
                    if nodes.len()+pending.len()+children.len()+1>=MAX_NODES{return Err(Failure::Limit)}
                    if !component(&entry.name)||!names.insert(entry.name.clone()){return Err(Failure::Input)}
                    admitted(entry.metadata)?;let mut parts=node.parts.clone();parts.push(entry.name);
                    path(root,&parts)?;
                    let size=parts.iter().try_fold(0usize,|n,p|n.checked_add(p.len()).ok_or(Failure::Limit))?;
                    component_bytes=component_bytes.checked_add(size).filter(|n|*n<=MAX_COMPONENT_BYTES).ok_or(Failure::Limit)?;
                    longest=longest.max(size+parts.len().saturating_sub(1));
                    children.push(Node{parts,metadata:entry.metadata});
                }
                progress.changed(nodes.len()+children.len(),bytes).await?;
            }
            source.close().await?;
            progress.changed(nodes.len()+children.len(),bytes).await?;
            if source.metadata(&absolute).await?!=node.metadata{return Err(Failure::Changed)}
            progress.changed(nodes.len()+children.len(),bytes).await?;
            children.sort_by(|a,b|a.parts.last().unwrap().as_bytes().cmp(b.parts.last().unwrap().as_bytes()));
            pending.extend(children.into_iter().rev());if !node.parts.is_empty(){folders+=1}
        }else{
            files+=1;if files>MAX_FILES{return Err(Failure::Limit)}
            bytes=bytes.checked_add(node.metadata.size.unwrap()).filter(|n|*n<=MAX_BYTES).ok_or(Failure::Limit)?;
        }
        nodes.push(node);progress.changed(nodes.len(),bytes).await?;
    }
    Ok(Manifest{root:root.to_owned(),nodes,files,folders,bytes,longest})
}
pub(crate) async fn revalidate<C:MetadataChannel,P:Progress>(source:&mut C,manifest:&Manifest,progress:P)->Result<()>{
    let observed=collect(source,&manifest.root,manifest.nodes[0].metadata,progress).await?;
    if observed!=*manifest{return Err(Failure::Changed)}Ok(())
}
pub(crate) async fn ancestors<C:MetadataChannel,P:Progress>(source:&mut C,manifest:&Manifest,node:&Node,mut progress:P)->Result<()>{
    for depth in 0..node.parts.len(){
        let parts=&node.parts[..depth];let Some(parent)=manifest.nodes.iter().find(|n|n.parts==parts)else{return Err(Failure::Input)};
        if !parent.directory(){return Err(Failure::Input)}let absolute=path(&manifest.root,parts)?;
        if source.metadata(&absolute).await?!=parent.metadata{return Err(Failure::Changed)}
        progress.changed(depth,0).await?;
        if source.canonical(&absolute).await?.as_bytes()!=absolute.as_bytes(){return Err(Failure::Changed)}
        progress.changed(depth,0).await?;
    }Ok(())
}
pub(crate) struct Prepared{
    pub request:[u8;16],pub generation:[u8;16],pub read:i64,pub revision:i64,pub manifest:Manifest,
    pub spent:Duration,pub reviewed_at:Instant,
}
impl Prepared{
    pub fn remaining(&self)->Result<Duration>{
        if self.reviewed_at.elapsed()>REVIEW_EXPIRY{return Err(Failure::Changed)}
        ACTIVE_DEADLINE.checked_sub(self.spent).filter(|d|!d.is_zero()).ok_or(Failure::Limit)
    }
}

#[cfg(test)]mod tests;
