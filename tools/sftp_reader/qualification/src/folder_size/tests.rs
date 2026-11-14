use super::*;
use crate::folder_download::{Failure as ChannelFailure,MetadataChannel};
use std::collections::BTreeMap;

fn attrs(mode:u32,size:Option<u64>)->Metadata{Metadata{size,modified:Some(17),permissions:Some(mode)}}
#[derive(Default)]struct Fake{nodes:BTreeMap<String,Metadata>,opened:Option<String>,listed:bool,closes:usize,deny_next:bool,alias:bool}
impl Fake{
    fn base()->Self{let mut value=Self::default();value.nodes.insert("/Root".into(),attrs(0o040755,None));value}
    fn insert(&mut self,path:&str,mode:u32,size:Option<u64>){self.nodes.insert(path.into(),attrs(mode,size));}
}
impl MetadataChannel for Fake{
    async fn metadata(&mut self,path:&str)->std::result::Result<Metadata,ChannelFailure>{
        self.nodes.get(path).copied().ok_or(ChannelFailure::Metadata(reader::Failure::Status(2)))
    }
    async fn canonical(&mut self,path:&str)->std::result::Result<String,ChannelFailure>{
        Ok(if self.alias{format!("{path}-alias")}else{path.to_owned()})
    }
    async fn open(&mut self,path:&str)->std::result::Result<(),ChannelFailure>{
        if self.opened.is_some(){return Err(ChannelFailure::Input)}self.opened=Some(path.into());self.listed=false;Ok(())
    }
    async fn next(&mut self)->std::result::Result<Option<Vec<Entry>>,ChannelFailure>{
        if self.deny_next{return Err(ChannelFailure::Metadata(reader::Failure::Status(3)))}
        if self.listed{return Ok(None)}self.listed=true;
        let prefix=format!("{}/",self.opened.as_deref().ok_or(ChannelFailure::Input)?);
        Ok(Some(self.nodes.iter().filter_map(|(path,metadata)|{
            let name=path.strip_prefix(&prefix)?;(!name.contains('/')).then(||Entry{name:name.into(),metadata:*metadata})
        }).collect()))
    }
    async fn close(&mut self)->std::result::Result<(),ChannelFailure>{
        self.opened.take().ok_or(ChannelFailure::Input)?;self.closes+=1;Ok(())
    }
}
fn run(value:impl std::future::Future<Output=()>){tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(value)}
#[test]fn counts_large_files_nested_folders_and_excluded_links_without_body_authority(){run(async{
    let mut fake=Fake::base();fake.insert("/Root/Empty",0o040755,None);
    fake.insert("/Root/Hard:one",0o100644,Some(1u64<<40));
    fake.insert("/Root/Hard:two",0o100644,Some(1u64<<40));
    fake.insert("/Root/Link",0o120777,Some(99));
    fake.insert("/Root/Empty/Zero",0o100644,Some(0));
    let root=fake.nodes["/Root"];
    let result=summarize(&mut fake,"/Root",root).await.unwrap();
    assert_eq!(result,Summary{bytes:2u64<<40,files:3,folders:1,excluded_links:1});
    assert_eq!(fake.closes,2);assert!(fake.opened.is_none());
})}
#[test]fn empty_root_has_zero_and_denied_read_still_closes(){run(async{
    let mut fake=Fake::base();let root=fake.nodes["/Root"];
    assert_eq!(summarize(&mut fake,"/Root",root).await.unwrap(),Summary{bytes:0,files:0,folders:0,excluded_links:0});
    fake.deny_next=true;
    assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Channel(reader::Failure::Status(3))));
    assert_eq!(fake.closes,2);assert!(fake.opened.is_none());
})}
#[test]fn changed_alias_unsupported_and_bounds_refuse_exact_total(){run(async{
    let mut fake=Fake::base();let root=fake.nodes["/Root"];
    fake.alias=true;assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Reason(Unavailable::Changed)));
    fake.alias=false;fake.insert("/Root/Special",0o020666,None);
    assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Reason(Unavailable::Unsupported)));
    fake.nodes.remove("/Root/Special");fake.insert("/Root/Large",0o100644,Some(u64::MAX));
    fake.insert("/Root/Another",0o100644,Some(1));
    assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Reason(Unavailable::Limit)));
    fake.nodes.remove("/Root/Large");fake.nodes.remove("/Root/Another");
    for n in 0..=MAX_LISTING_ENTRIES{fake.insert(&format!("/Root/N{n:04}"),0o120777,None);}
    assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Reason(Unavailable::Limit)));
    assert!(fake.opened.is_none());assert_eq!(fake.closes,3);
    fake.nodes.insert("/Root/Bad\0name".into(),attrs(0o100644,Some(1)));
    fake.nodes.retain(|path,_|path=="/Root"||path=="/Root/Bad\0name");
    assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Reason(Unavailable::Unsupported)));
    assert!(fake.opened.is_none());assert_eq!(fake.closes,4);
})}
#[test]fn distributed_project_exceeds_old_limit_and_total_boundary_refuses(){run(async{
    let mut fake=Fake::base();let root=fake.nodes["/Root"];
    for directory in 0..9{
        fake.insert(&format!("/Root/D{directory}"),0o040755,None);
        for item in 0..256{fake.insert(&format!("/Root/D{directory}/N{item:04}"),0o100644,Some(1));}
    }
    assert_eq!(summarize(&mut fake,"/Root",root).await.unwrap(),
        Summary{bytes:2304,files:2304,folders:9,excluded_links:0});
    assert!(fake.opened.is_none());assert_eq!(fake.closes,10);
    fake.nodes.retain(|path,_|path=="/Root");
    let last=MAX_NODES-1-8-7*MAX_LISTING_ENTRIES;
    assert_eq!(last,4087);
    for directory in 0..8{
        fake.insert(&format!("/Root/D{directory}"),0o040755,None);
        let count=if directory==7{last}else{MAX_LISTING_ENTRIES};
        for item in 0..count{
            fake.insert(&format!("/Root/D{directory}/N{item:04}"),0o100644,Some(1));
        }
    }
    assert_eq!(summarize(&mut fake,"/Root",root).await.unwrap(),
        Summary{bytes:(MAX_NODES-9)as u64,files:(MAX_NODES-9)as u32,folders:8,excluded_links:0});
    assert!(fake.opened.is_none());assert_eq!(fake.closes,19);
    fake.insert(&format!("/Root/D7/N{last:04}"),0o100644,Some(1));
    assert_eq!(summarize(&mut fake,"/Root",root).await,Err(Failure::Reason(Unavailable::Limit)));
    assert!(fake.opened.is_none());assert_eq!(fake.closes,28);
})}
