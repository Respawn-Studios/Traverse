//! Selected-folder scan through the idle B2 directory metadata profile. No file CREATE,
//! SMB READ, transfer preparation, credentials or file-body capability.
use super::{catalog::SelectedRow,channel::Stop,store,wire::{self,Issue}};
use smb2::{client::{Connection,Tree},types::Command,ListOptions};
use std::{collections::HashSet,future::Future,time::{Duration,Instant}};
use tokio::sync::oneshot;

const MAX_NODES:usize=32768;
const MAX_LISTING_ENTRIES:usize=4096;
const MAX_DEPTH:usize=32;
const MAX_PATH_UNITS:usize=2048;
const MAX_ENCODED_PATH_BYTES:usize=4<<20;
const MAX_BATCHES:usize=MAX_LISTING_ENTRIES+1;
const SCAN_BUDGET:Duration=Duration::from_secs(60);

#[derive(Clone,Copy,Debug,PartialEq,Eq)]
#[repr(u8)]pub enum Reason{Stale=1,Denied=2,Changed=3,Unsupported=4,Limit=5,Deadline=6,Unavailable=7}
#[derive(Debug,PartialEq,Eq)]pub enum Failure{Reason(Reason),Fatal(Issue)}
type Result<T>=std::result::Result<T,Failure>;
#[derive(Clone,Copy,Debug,PartialEq,Eq)]pub struct Summary{pub bytes:u64,pub files:u32,pub folders:u32,pub excluded_links:u32}
pub enum End{Complete(wire::FolderSizeSelection,Summary),Unavailable(wire::FolderSizeSelection,Reason)}

#[derive(Clone,Debug,PartialEq,Eq)]struct Entry{name:String,wire:Vec<u16>,attributes:u32,size:u64,modified:u64,changed:u64,index:u64}
#[derive(Clone,Copy)]struct Witness{attributes:u32,modified:u64,changed:Option<u64>,index:u64}
struct Node{path:String,witness:Witness,depth:usize,ancestors:Vec<u64>}
struct Budget{started:Instant,nodes:usize,path_bytes:usize}
impl Budget{
    fn new(root:&str)->Self{Self{started:Instant::now(),nodes:1,path_bytes:root.encode_utf16().count()*2}}
    fn check(&self)->Result<()>{if self.started.elapsed()>SCAN_BUDGET{Err(Failure::Reason(Reason::Deadline))}else{Ok(())}}
    fn add(&mut self,path:&str,name:&[u16])->Result<()>{
        self.nodes=self.nodes.checked_add(1).filter(|v|*v<=MAX_NODES).ok_or(Failure::Reason(Reason::Limit))?;
        let encoded=path.encode_utf16().count().checked_add(name.len()).and_then(|v|v.checked_mul(2)).ok_or(Failure::Reason(Reason::Limit))?;
        self.path_bytes=self.path_bytes.checked_add(encoded).filter(|v|*v<=MAX_ENCODED_PATH_BYTES).ok_or(Failure::Reason(Reason::Limit))?;Ok(())
    }
}
fn exact_path(raw:&[u16])->Result<String>{
    if raw.is_empty()||raw.len()>MAX_PATH_UNITS||raw.split(|unit|*unit==92).any(|part|
        part.is_empty()||part.len()>255||part==[46]||part==[46,46]){return Err(Failure::Reason(Reason::Unsupported))}
    let wire=String::from_utf16(raw).map_err(|_|Failure::Reason(Reason::Unsupported))?;
    let path=smb2::name::decode_path(&wire);
    if path.split('/').any(|part|part.is_empty()||part=="."||part=="..")||smb2::name::encode_path(&path)!=wire{
        return Err(Failure::Reason(Reason::Unsupported));
    }Ok(path)
}
fn listed_name(name:&str,raw:&[u16])->Result<()>{
    if raw.is_empty()||raw.len()>255||name.is_empty()||name=="."||name==".."||name.contains(['/', '\0']){
        return Err(Failure::Reason(Reason::Unsupported));
    }
    let wire=String::from_utf16(raw).map_err(|_|Failure::Reason(Reason::Unsupported))?;
    if smb2::name::decode_name(&wire).as_ref()!=name||smb2::name::encode_name(name).as_ref()!=wire{
        return Err(Failure::Reason(Reason::Unsupported));
    }Ok(())
}
fn admit_listing_entry(name:&str,raw:&[u16],retained:usize,budget:&Budget)->Result<()>{
    if retained>=MAX_LISTING_ENTRIES.min(MAX_NODES.saturating_sub(budget.nodes)){
        return Err(Failure::Reason(Reason::Limit));
    }
    listed_name(name,raw)
}
fn child(parent:&str,entry:&Entry)->Result<String>{
    listed_name(&entry.name,&entry.wire)?;
    let path=format!("{parent}/{}",entry.name);
    if path.encode_utf16().count()>MAX_PATH_UNITS{return Err(Failure::Reason(Reason::Limit))}Ok(path)
}
trait DirectorySource{
    fn list(&mut self,path:&str,witness:Witness,budget:&Budget)->impl Future<Output=Result<Vec<Entry>>>;
}
struct NetworkSource{conn:Connection,tree:Tree}
#[derive(PartialEq,Eq)]struct Listing{entries:Vec<Entry>,dot_changed:u64}
fn open_rejection(error:&smb2::Error)->Option<Reason>{match error{
    smb2::Error::Protocol{command:Command::Create,status}=>match status.0{
        0xc0000022=>Some(Reason::Denied),
        0xc000000f|0xc0000034|0xc000003a|0xc0000103=>Some(Reason::Changed),
        0xc00000bb=>Some(Reason::Unsupported),_=>None,
    },_=>None}}
fn listing_rejection(error:&smb2::Error)->Option<Reason>{match error{
    smb2::Error::Protocol{command:Command::QueryDirectory,status}=>match status.0{
        0xc0000022=>Some(Reason::Denied),
        0xc000000f|0xc0000034|0xc000003a|0xc0000103=>Some(Reason::Changed),
        0xc0000003|0xc00000bb=>Some(Reason::Unsupported),_=>None,
    },_=>None}}
fn listing_failure(error:smb2::Error,close_acknowledged:bool)->Failure{
    if close_acknowledged{if let Some(reason)=listing_rejection(&error){return Failure::Reason(reason)}}
    Failure::Fatal(super::network::remote(error))
}
impl NetworkSource{
    async fn once(&mut self,path:&str,witness:Witness,budget:&Budget)->Result<Listing>{
        budget.check()?;
        let mut reader=match self.tree.open_directory_reader_with(self.conn.clone(),path,ListOptions::new().index_numbers(true)).await{
            Ok(value)=>value,Err(error)=>return Err(match open_rejection(&error){Some(reason)=>Failure::Reason(reason),None=>Failure::Fatal(super::network::remote(error))}),
        };
        let gathered=async{
            let mut entries=Vec::new();let mut names=HashSet::new();let mut dot_changed=None;
            for _ in 0..MAX_BATCHES{
                budget.check()?;
                let batch=match reader.next_batch().await{
                    Ok(value)=>value,
                    Err(error)=>return Err(listing_failure(error,reader.close_acknowledged())),
                };
                budget.check()?;
                let Some(batch)=batch else{
                    let changed=dot_changed.ok_or(Failure::Reason(Reason::Unsupported))?;
                    entries.sort_by(|a:&Entry,b:&Entry|a.wire.cmp(&b.wire));return Ok(Listing{entries,dot_changed:changed})
                };
                if batch.len()>700{return Err(Failure::Reason(Reason::Limit))}
                for row in batch{
                    let attr=row.attributes.bits();
                    if row.name=="."{
                        if dot_changed.is_some()||row.qualification_wire_name!=[46]||attr!=witness.attributes||row.modified.0!=witness.modified
                            ||witness.changed.is_some_and(|value|row.changed.0!=value)||row.index_number!=Some(witness.index){return Err(Failure::Reason(Reason::Changed))}
                        dot_changed=Some(row.changed.0);continue;
                    }
                    if row.name==".."{if row.qualification_wire_name!=[46,46]{return Err(Failure::Reason(Reason::Changed))}continue;}
                    let index=match row.index_number.filter(|value|*value!=0&&*value!=u64::MAX){
                        Some(value)=>value,None if attr&0x400!=0=>0,None=>return Err(Failure::Reason(Reason::Unsupported)),
                    };
                    admit_listing_entry(&row.name,&row.qualification_wire_name,entries.len(),budget)?;
                    if !names.insert(row.qualification_wire_name.clone()){return Err(Failure::Reason(Reason::Changed))}
                    entries.push(Entry{name:row.name,wire:row.qualification_wire_name,attributes:attr,size:row.size,
                        modified:row.modified.0,changed:row.changed.0,index});
                }
            }
            Err(Failure::Reason(Reason::Limit))
        }.await;
        // `next_batch(None)` already closed; on early exit the owned reader
        // awaits CLOSE. An invalidated handle is not a native CLOSE reply.
        if !matches!(reader.close_with_acknowledgement().await,Ok(true)){
            return Err(Failure::Fatal(Issue::Close))
        }
        gathered
    }
}
impl DirectorySource for NetworkSource{
    async fn list(&mut self,path:&str,witness:Witness,budget:&Budget)->Result<Vec<Entry>>{
        let first=self.once(path,witness,budget).await?;
        budget.check()?;
        let second=self.once(path,witness,budget).await?;
        if first!=second{return Err(Failure::Reason(Reason::Changed))}Ok(first.entries)
    }
}
async fn scan<S:DirectorySource>(source:&mut S,root:String,witness:Witness)->Result<Summary>{
    if witness.index==0||witness.index==u64::MAX||witness.attributes&0x450!=0x10{return Err(Failure::Reason(Reason::Unsupported))}
    let mut budget=Budget::new(&root);let mut pending=vec![Node{path:root,witness,depth:0,ancestors:vec![]}];
    let mut summary=Summary{bytes:0,files:0,folders:0,excluded_links:0};
    while let Some(node)=pending.pop(){
        budget.check()?;
        if node.ancestors.contains(&node.witness.index){return Err(Failure::Reason(Reason::Unsupported))}
        let children=source.list(&node.path,node.witness,&budget).await?;
        budget.check()?;
        if node.depth>0{summary.folders=summary.folders.checked_add(1).ok_or(Failure::Reason(Reason::Limit))?;}
        for child_entry in children{
            let path=child(&node.path,&child_entry)?;budget.add(&path,&child_entry.wire)?;
            let attr=child_entry.attributes;
            if attr&0x400!=0{
                summary.excluded_links=summary.excluded_links.checked_add(1).ok_or(Failure::Reason(Reason::Limit))?;
            }else if attr&0x40!=0{return Err(Failure::Reason(Reason::Unsupported))}
            else if attr&0x10!=0{
                if node.depth>=MAX_DEPTH{return Err(Failure::Reason(Reason::Limit))}
                let mut ancestors=node.ancestors.clone();ancestors.push(node.witness.index);
                pending.push(Node{path,witness:Witness{attributes:attr,modified:child_entry.modified,changed:Some(child_entry.changed),index:child_entry.index},depth:node.depth+1,ancestors});
            }else{
                summary.bytes=summary.bytes.checked_add(child_entry.size).ok_or(Failure::Reason(Reason::Limit))?;
                summary.files=summary.files.checked_add(1).ok_or(Failure::Reason(Reason::Limit))?;
            }
        }
    }
    budget.check()?;Ok(summary)
}

pub async fn resolve(selection:&wire::FolderSizeSelection,owner:&store::Owner,stop:&Stop)->std::result::Result<std::result::Result<SelectedRow,Reason>,Issue>{
    let(tx,rx)=oneshot::channel();
    tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=owner.commands.send(store::Command::SelectedFolderSize{selection:selection.clone(),reply:tx})=>value.map_err(|_|Issue::Storage)?}
    match tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=rx=>value.map_err(|_|Issue::Storage)?,
        _=tokio::time::sleep(Duration::from_secs(2))=>return Err(Issue::Deadline)}{
        Ok(row)=>Ok(Ok(row)),Err(Issue::Invalid)=>Ok(Err(Reason::Stale)),Err(error)=>Err(error),
    }
}
async fn execute(selection:wire::FolderSizeSelection,selected:SelectedRow,conn:Connection,tree:Tree)->std::result::Result<End,Issue>{
    let mut raw=selected.directory;if !raw.is_empty(){raw.push(92)}raw.extend(&selected.item.wire);
    let result=match exact_path(&raw){
        Ok(path)=>scan(&mut NetworkSource{conn,tree},path,Witness{attributes:selected.item.attributes,modified:selected.item.modified,changed:None,index:selected.item.object}).await,
        Err(reason)=>Err(reason),
    };
    match result{Ok(summary)=>Ok(End::Complete(selection,summary)),Err(Failure::Reason(reason))=>Ok(End::Unavailable(selection,reason)),
        Err(Failure::Fatal(issue))=>Err(issue)}
}
pub fn start(selection:wire::FolderSizeSelection,selected:SelectedRow,conn:Connection,tree:Tree)->tokio::task::JoinHandle<std::result::Result<End,Issue>>{
    // A peer can keep one QUERY_DIRECTORY alive with interim replies. Checks
    // between batches alone cannot bound the total time spent in that await.
    tokio::spawn(async move{
        tokio::time::timeout(SCAN_BUDGET,execute(selection,selected,conn,tree)).await
            .unwrap_or(Err(Issue::Deadline))
    })
}

#[cfg(test)]mod tests{
    use super::*;
    use std::collections::BTreeMap;
    struct Fake{nodes:BTreeMap<String,Vec<Entry>>,calls:usize}
    impl DirectorySource for Fake{
        async fn list(&mut self,path:&str,_:Witness,budget:&Budget)->Result<Vec<Entry>>{
            self.calls+=1;
            let rows=self.nodes.get(path).ok_or(Failure::Reason(Reason::Changed))?;
            for(index,row)in rows.iter().enumerate(){admit_listing_entry(&row.name,&row.wire,index,budget)?}
            Ok(rows.clone())
        }
    }
    fn entry(name:&str,attributes:u32,size:u64,index:u64)->Entry{Entry{name:name.into(),wire:name.encode_utf16().collect(),attributes,size,modified:7,changed:8,index}}
    fn root()->Witness{Witness{attributes:0x10,modified:7,changed:None,index:1}}
    #[tokio::test]async fn logical_size_counts_hardlink_names_and_excludes_reparse(){
        let mut source=Fake{nodes:BTreeMap::from([
            ("Root".into(),vec![entry("Empty",0x10,0,2),entry("First",0,1<<40,3),entry("Second",0,1<<40,3),entry("Link",0x400,99,4)]),
            ("Root/Empty".into(),vec![]),
        ]),calls:0};
        assert_eq!(scan(&mut source,"Root".into(),root()).await.unwrap(),Summary{bytes:2u64<<40,files:2,folders:1,excluded_links:1});
        assert_eq!(source.calls,2);
    }
    #[tokio::test]async fn bounds_and_cycles_never_emit_a_total(){
        let mut source=Fake{nodes:BTreeMap::from([("Root".into(),vec![entry("Cycle",0x10,0,1)])]),calls:0};
        assert_eq!(scan(&mut source,"Root".into(),root()).await,Err(Failure::Reason(Reason::Unsupported)));
        source.nodes.insert("Root".into(),(0..=MAX_LISTING_ENTRIES).map(|n|entry(&format!("N{n:04}"),0,1,n as u64+2)).collect());
        assert_eq!(scan(&mut source,"Root".into(),root()).await,Err(Failure::Reason(Reason::Limit)));
        source.nodes.insert("Root".into(),vec![Entry{wire:vec![0xD800],..entry("Unsafe",0,1,2)}]);
        assert_eq!(scan(&mut source,"Root".into(),root()).await,Err(Failure::Reason(Reason::Unsupported)));
        source.nodes.insert("Root".into(),vec![Entry{wire:"different".encode_utf16().collect(),..entry("Unsafe",0,1,2)}]);
        assert_eq!(scan(&mut source,"Root".into(),root()).await,Err(Failure::Reason(Reason::Unsupported)));
    }
    #[tokio::test]async fn distributed_project_exceeds_old_limit_and_total_boundary_refuses(){
        let mut source=Fake{nodes:BTreeMap::new(),calls:0};
        source.nodes.insert("Root".into(),(0..9).map(|n|entry(&format!("D{n}"),0x10,0,n+2)).collect());
        for directory in 0..9{
            source.nodes.insert(format!("Root/D{directory}"),(0..256).map(|n|
                entry(&format!("N{n:04}"),0,1,n+100)).collect());
        }
        assert_eq!(scan(&mut source,"Root".into(),root()).await.unwrap(),
            Summary{bytes:2304,files:2304,folders:9,excluded_links:0});
        assert_eq!(source.calls,10);
        let last=MAX_NODES-1-8-7*MAX_LISTING_ENTRIES;
        assert_eq!(last,4087);
        source.nodes.insert("Root".into(),(0..8).map(|n|entry(&format!("D{n}"),0x10,0,n+2)).collect());
        for directory in 0..8{
            let count=if directory==7{last}else{MAX_LISTING_ENTRIES};
            source.nodes.insert(format!("Root/D{directory}"),(0..count).map(|n|
                entry(&format!("N{n:04}"),0,1,n as u64+100)).collect());
        }
        assert_eq!(scan(&mut source,"Root".into(),root()).await.unwrap(),
            Summary{bytes:(MAX_NODES-9)as u64,files:(MAX_NODES-9)as u32,folders:8,excluded_links:0});
        source.nodes.get_mut("Root/D7").unwrap().push(entry(&format!("N{last:04}"),0,1,last as u64+100));
        assert_eq!(scan(&mut source,"Root".into(),root()).await,Err(Failure::Reason(Reason::Limit)));
    }
    #[test]fn exact_wire_path_refuses_ambiguous_roundtrip(){
        assert_eq!(exact_path(&"Folder\\Child".encode_utf16().collect::<Vec<_>>()).unwrap(),"Folder/Child");
        assert!(exact_path(&"Folder\\..\\Child".encode_utf16().collect::<Vec<_>>()).is_err());
        assert!(exact_path(&[65,0xF028,66]).is_err());
    }
    #[test]fn every_idle_mode_keeps_only_directory_metadata_frames(){
        let policies=[super::super::SendPolicy::Metadata,
            super::super::SendPolicy::File(smb2::client::selected_download::SelectedDownloadPolicy::new()),
            super::super::SendPolicy::Folder(smb2::client::selected_folder_download::SelectedFolderPolicy::new()),
            super::super::SendPolicy::Upload(smb2::client::selected_upload::SelectedUploadPolicy::new())];
        let mut frame=vec![0u8;120];frame[..4].copy_from_slice(b"\xfeSMB");frame[4]=64;
        frame[12..14].copy_from_slice(&5u16.to_le_bytes());
        frame[88..92].copy_from_slice(&0x0010_0081u32.to_le_bytes());
        frame[100..104].copy_from_slice(&1u32.to_le_bytes());frame[104..108].copy_from_slice(&0x0020_0001u32.to_le_bytes());
        for policy in policies{
            assert!(policy.permits(&frame));
            for command in [8u16,9]{frame[12..14].copy_from_slice(&command.to_le_bytes());assert!(!policy.permits(&frame));}
            frame[12..14].copy_from_slice(&5u16.to_le_bytes());frame[104..108].copy_from_slice(&0x0020_0040u32.to_le_bytes());
            assert!(!policy.permits(&frame));frame[104..108].copy_from_slice(&0x0020_0001u32.to_le_bytes());
        }
    }
    #[test]fn only_acknowledged_known_listing_refusals_are_recoverable(){
        use smb2::types::{Command,status::NtStatus};
        let denied=||smb2::Error::Protocol{command:Command::QueryDirectory,status:NtStatus::ACCESS_DENIED};
        assert_eq!(listing_failure(denied(),true),Failure::Reason(Reason::Denied));
        assert_eq!(listing_failure(denied(),false),Failure::Fatal(Issue::Denied));
        assert_eq!(listing_failure(smb2::Error::Protocol{command:Command::Close,status:NtStatus::ACCESS_DENIED},true),Failure::Fatal(Issue::Denied));
        assert_eq!(listing_failure(smb2::Error::Protocol{command:Command::QueryDirectory,status:NtStatus::NOT_SUPPORTED},true),Failure::Reason(Reason::Unsupported));
        let unknown=smb2::Error::Protocol{command:Command::QueryDirectory,status:NtStatus(0xc0000001)};
        assert_eq!(listing_failure(unknown,true),Failure::Fatal(Issue::Remote));
        let unknown_create=smb2::Error::Protocol{command:Command::Create,status:NtStatus(0xc0000001)};
        assert_eq!(open_rejection(&unknown_create),None);
    }
}
