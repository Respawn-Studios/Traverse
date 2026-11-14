//! Bounded fresh-folder copy. Names are byte-exact metadata. There is no local
//! filesystem, credential, removal, overwrite, resume or shell authority here.
use crate::upload::{self,Failure};
use sha2::{Digest,Sha256};
use std::{collections::HashSet,future::Future,fmt,sync::{Arc,atomic::AtomicBool}};
use tokio::io::{AsyncRead,AsyncWrite};
pub(crate) const MAX_FILES:usize=1024;
pub(crate) const MAX_NODES:usize=2048;
pub(crate) const MAX_DEPTH:usize=32;
pub(crate) const MAX_MANIFEST:usize=512<<10;
pub(crate) const MAX_BYTES:u64=1<<30;
type Result<T>=std::result::Result<T,Failure>;
#[derive(Clone,PartialEq,Eq)]pub(crate) struct Node{pub directory:bool,pub parts:Vec<Vec<u8>>,pub size:u64}
#[derive(Clone,PartialEq,Eq)]pub(crate) struct Manifest{
    pub nodes:Vec<Node>,pub files:u32,pub folders:u32,pub bytes:u64,pub encoded:Vec<u8>,pub digest:[u8;32],
}
impl fmt::Debug for Manifest{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{write!(f,"<SFTP bounded folder metadata>")}}
pub(crate) fn component(value:&[u8])->bool{
    !value.is_empty()&&value.len()<=255&&value!=b"."&&value!=b".."&&!value.contains(&0)&&!value.contains(&b'/')&&std::str::from_utf8(value).is_ok()
}
impl Manifest{
    pub(crate) fn decode(encoded:&[u8])->Result<Self>{
        if !(22..=MAX_MANIFEST).contains(&encoded.len())||&encoded[..8]!=b"TRVFUP01"{return Err(Failure::Input)}
        let mut at=8;
        fn take<'a>(encoded:&'a[u8],at:&mut usize,count:usize)->Result<&'a[u8]>{
            let end=at.checked_add(count).ok_or(Failure::Input)?;let value=encoded.get(*at..end).ok_or(Failure::Input)?;*at=end;Ok(value)
        }
        let count=u32::from_be_bytes(take(encoded,&mut at,4)?.try_into().unwrap())as usize;
        if !(1..=MAX_NODES).contains(&count){return Err(Failure::Input)}
        let mut nodes:Vec<Node>=Vec::with_capacity(count);let mut parents=HashSet::new();let(mut files,mut folders,mut bytes)=(0,0,0u64);
        for index in 0..count{
            let kind=take(encoded,&mut at,1)?[0];let depth=take(encoded,&mut at,1)?[0]as usize;
            let size=u64::from_be_bytes(take(encoded,&mut at,8)?.try_into().unwrap());
            if ![1,2].contains(&kind)||depth>MAX_DEPTH||(index==0)!=(depth==0)||index==0&&kind!=1{return Err(Failure::Input)}
            let mut parts=Vec::with_capacity(depth);
            for _ in 0..depth{
                let length=u16::from_be_bytes(take(encoded,&mut at,2)?.try_into().unwrap())as usize;
                if !(1..=255).contains(&length){return Err(Failure::Input)}let part=take(encoded,&mut at,length)?;
                if !component(part){return Err(Failure::Input)}parts.push(part.to_vec());
            }
            if nodes.last().is_some_and(|previous|previous.parts>=parts)||index!=0&&!parents.contains(&parts[..parts.len()-1]){return Err(Failure::Input)}
            if kind==1{
                if size!=0{return Err(Failure::Input)}parents.insert(parts.clone());if index!=0{folders+=1}
            }else{
                files+=1;if files as usize>MAX_FILES{return Err(Failure::Input)}
                bytes=bytes.checked_add(size).filter(|v|*v<=MAX_BYTES).ok_or(Failure::Input)?;
            }
            nodes.push(Node{directory:kind==1,parts,size});
        }
        if at!=encoded.len(){return Err(Failure::Input)}
        Ok(Self{nodes,files,folders,bytes,encoded:encoded.to_vec(),digest:Sha256::digest(encoded).into()})
    }
    pub(crate) fn path(&self,root:&str,index:usize)->Result<String>{
        let node=self.nodes.get(index).ok_or(Failure::Input)?;
        let mut result=root.to_owned();for part in &node.parts{result.push('/');result.push_str(std::str::from_utf8(part).map_err(|_|Failure::Input)?)}
        if result.len()>8192||result.split('/').skip(1).count()>127{return Err(Failure::Input)}Ok(result)
    }
}

pub(crate) trait Source{
    fn bytes(&mut self,node:u32,offset:u64,count:usize)->impl Future<Output=Result<Vec<u8>>>;
    fn permit_file(&mut self,node:u32,digest:[u8;32])->impl Future<Output=Result<()>>;
    fn root_created(&mut self)->impl Future<Output=Result<()>>;
    fn verified(&mut self,node:u32,files:u32,bytes:u64)->impl Future<Output=Result<()>>;
    fn finish(&mut self,digest:[u8;32])->impl Future<Output=Result<()>>;
}
struct Member<'a,T>{source:&'a mut T,node:u32,size:u64}
impl<T:Source> upload::Source for Member<'_,T>{
    fn size(&self)->u64{self.size}
    async fn next(&mut self,offset:u64,count:usize)->Result<Vec<u8>>{self.source.bytes(self.node,offset,count).await}
    async fn permit_publication(&mut self,digest:[u8;32])->Result<()>{self.source.permit_file(self.node,digest).await}
}
#[derive(Debug,PartialEq,Eq)]pub(crate) struct Interrupted{
    pub cause:Failure,pub phase:u8,pub node:u32,pub root_may_exist:bool,pub root_acknowledged:bool,pub verified_files:u32,pub verified_bytes:u64,
}
impl Interrupted{pub(crate) fn admission(cause:Failure)->Self{Self{cause,phase:0,node:0,root_may_exist:false,root_acknowledged:false,verified_files:0,verified_bytes:0}}}
#[derive(Debug)]pub(crate) struct Receipt{pub files:u32,pub bytes:u64,pub digest:[u8;32]}

/// All path-based operations assume the selected authenticated namespace stays
/// stable. SFTPv3 cannot stop a same-account actor replacing an ancestor. Strict
/// LSTAT/readback observations do not turn names into descriptor-relative IDs.
pub(crate) async fn send<S:AsyncRead+AsyncWrite+Unpin,T:Source>(stream:S,directory:&str,name:&str,nonce:[u8;16],manifest:&Manifest,mut source:T,
    limits:upload::Limits,stop:Option<Arc<AtomicBool>>)->std::result::Result<Receipt,Interrupted>{
    let(mut phase,mut node,mut root_may_exist,mut root_acknowledged,mut verified_files,mut verified_bytes)=(0u8,0u32,false,false,0u32,0u64);
    let work=async{
        let root_target=upload::Target::new(directory,name,nonce)?;let(_,root)=root_target.paths_for_intent();
        // Validate every derived path before negotiating or sending MKDIR.
        for(index,entry)in manifest.nodes.iter().enumerate(){
            let path=manifest.path(root,index)?;
            if !entry.directory{let(parent,leaf)=path.rsplit_once('/').ok_or(Failure::Input)?;upload::Target::new(parent,leaf,nonce)?;}
        }
        phase=1;let mut writer=upload::TreeWriter::new(stream,limits,stop).await?;
        let mut digests=vec![None;manifest.nodes.len()];
        for(index,entry)in manifest.nodes.iter().enumerate(){
            node=index as u32;let path=manifest.path(root,index)?;
            // Check observed parents immediately before each child write.
            if index!=0{for parent in 0..entry.parts.len(){
                    let mut value=root.to_owned();for part in &entry.parts[..parent]{value.push('/');value.push_str(std::str::from_utf8(part).map_err(|_|Failure::Input)?)}writer.check_directory(&value).await?;
            }}
            if entry.directory{
                phase=2;
                writer.create_directory(&path,&mut root_may_exist).await?;
                if index==0{root_acknowledged=true;writer.source(source.root_created()).await?;}
            }else{
                phase=3;
                let(parent,leaf)=path.rsplit_once('/').ok_or(Failure::Input)?;
                let target=upload::Target::new(parent,leaf,nonce)?;
                let receipt=writer.file(&target,Member{source:&mut source,node,size:entry.size}).await.map_err(|v|v.cause)?;
                if !receipt.exclusive_create_acknowledged||!receipt.sync_acknowledged||!receipt.final_close_acknowledged||receipt.stream_shutdown{return Err(Failure::Verification)}
                verified_files+=1;verified_bytes=verified_bytes.checked_add(receipt.bytes).ok_or(Failure::Verification)?;
                digests[index]=Some(receipt.digest);writer.source(source.verified(node,verified_files,verified_bytes)).await?;
            }
        }
        phase=4;for(index,entry)in manifest.nodes.iter().enumerate(){
            node=index as u32;let path=manifest.path(root,index)?;
            if entry.directory{
                let observed=writer.entries(&path).await?;
                let expected:Vec<_>=manifest.nodes.iter().filter(|child|child.parts.len()==entry.parts.len()+1&&child.parts.starts_with(&entry.parts)).collect();
                if observed.len()!=expected.len(){return Err(Failure::Verification)}
                for(actual,expected)in observed.iter().zip(expected){
                    if actual.name.as_bytes()!=expected.parts.last().unwrap()||actual.metadata.permissions.is_none_or(|mode|mode&0o177777!=if expected.directory{0o040755}else{0o100644})
                        ||!expected.directory&&actual.metadata.size!=Some(expected.size){return Err(Failure::Verification)}
                }
            }else{writer.verify_file(&path,entry.size,digests[index].ok_or(Failure::Verification)?).await?;}
        }
        if verified_files!=manifest.files||verified_bytes!=manifest.bytes{return Err(Failure::Verification)}
        let mut hash=Sha256::new();hash.update(&manifest.encoded);for digest in digests.into_iter().flatten(){hash.update(digest)}let digest=hash.finalize().into();
        phase=5;writer.source(source.finish(digest)).await?;phase=6;writer.finish().await?;
        Ok(Receipt{files:verified_files,bytes:verified_bytes,digest})
    }.await;
    work.map_err(|cause|Interrupted{cause,phase,node,root_may_exist,root_acknowledged,verified_files,verified_bytes})
}

#[cfg(test)]mod tests;
