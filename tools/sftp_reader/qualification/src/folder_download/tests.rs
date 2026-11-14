use super::*;
use std::collections::BTreeMap;
use std::sync::{Arc,atomic::{AtomicUsize,Ordering}};
fn attrs(directory:bool,size:u64)->Metadata{Metadata{size:Some(size),modified:Some(19),permissions:Some(if directory{0o040755}else{0o100644})}}
#[derive(Default)]struct Fake{
    nodes:BTreeMap<String,Metadata>,open:Option<String>,sent:bool,closes:usize,
    duplicate:bool,deny_close:bool,alias:bool,endless:bool,
    operations:Arc<AtomicUsize>,
}
impl Fake{
    fn new()->Self{let mut s=Self::default();for(path,dir,size)in[("/Root",true,4096),("/Root/Empty",true,0),("/Root/Café",true,0),("/Root/Café/Report",false,7),("/Root/Zero\\file",false,0)]{s.nodes.insert(path.into(),attrs(dir,size));}s}
}
impl MetadataChannel for Fake{
    async fn metadata(&mut self,path:&str)->Result<Metadata>{self.operations.fetch_add(1,Ordering::SeqCst);self.nodes.get(path).copied().ok_or(Failure::Metadata(reader::Failure::Status(2)))}
    async fn canonical(&mut self,path:&str)->Result<String>{self.operations.fetch_add(1,Ordering::SeqCst);Ok(if self.alias{path.to_owned()+"-alias"}else{path.to_owned()})}
    async fn open(&mut self,path:&str)->Result<()>{self.operations.fetch_add(1,Ordering::SeqCst);if self.open.is_some(){return Err(Failure::Input)}self.open=Some(path.into());self.sent=false;Ok(())}
    async fn next(&mut self)->Result<Option<Vec<Entry>>>{
        self.operations.fetch_add(1,Ordering::SeqCst);
        if self.endless{tokio::task::yield_now().await;return Ok(Some(vec![]))}
        if self.sent{return Ok(None)}self.sent=true;let prefix=self.open.as_ref().ok_or(Failure::Input)?.to_owned()+"/";
        let mut rows:Vec<_>=self.nodes.iter().filter_map(|(path,metadata)|{let name=path.strip_prefix(&prefix)?;(!name.contains('/')).then(||Entry{name:name.into(),metadata:*metadata})}).collect();
        rows.reverse();if self.duplicate{if let Some(first)=rows.first().cloned(){rows.push(first)}}Ok(Some(rows))
    }
    async fn close(&mut self)->Result<()>{self.operations.fetch_add(1,Ordering::SeqCst);if self.deny_close{return Err(Failure::Metadata(reader::Failure::Status(3)))}if self.open.take().is_none(){return Err(Failure::Input)}self.closes+=1;Ok(())}
}
#[test]fn every_metadata_round_trip_offers_progress_before_another_request(){runtime().block_on(async{
    let mut source=Fake::new();let operations=source.operations.clone();let mut seen=0;
    collect(&mut source,"/Root",attrs(true,4096),move|_,_|{
        let current=operations.load(Ordering::SeqCst);let valid=current-seen<=1;seen=current;
        std::future::ready(if valid{Ok(())}else{Err(Failure::Output)})
    }).await.unwrap();
})}
async fn silent(_:usize,_:u64)->Result<()>{Ok(())}
fn runtime()->tokio::runtime::Runtime{tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()}
#[test]fn nested_empty_and_byte_exact_names_produce_one_deterministic_manifest(){runtime().block_on(async{
    let mut source=Fake::new();let m=collect(&mut source,"/Root",attrs(true,4096),silent).await.unwrap();
    assert_eq!((m.files,m.folders,m.bytes,m.nodes.len(),source.closes),(2,2,7,5,3));assert!(source.open.is_none());
    assert_eq!(m.nodes[4].parts,["Zero\\file"]);revalidate(&mut source,&m,silent).await.unwrap();assert_eq!(source.closes,6);
    ancestors(&mut source,&m,&m.nodes[2],silent).await.unwrap();
})}
#[test]fn unsupported_metadata_names_duplicate_and_unacknowledged_close_refuse(){runtime().block_on(async{
    for variant in 0..7{
        let mut s=Fake::new();match variant{
            0=>s.nodes.get_mut("/Root/Café/Report").unwrap().permissions=Some(0o120777),
            1=>s.nodes.get_mut("/Root/Café/Report").unwrap().size=None,
            2=>s.nodes.get_mut("/Root/Empty").unwrap().modified=None,
            3=>{s.nodes.insert("/Root/line\nname".into(),attrs(false,0));},
            4=>s.duplicate=true,5=>s.deny_close=true,_=>s.alias=true,
        }assert!(collect(&mut s,"/Root",attrs(true,4096),silent).await.is_err());
    }
})}
#[test]fn membership_file_and_ancestor_changes_are_detected_without_reinterpreting_review(){runtime().block_on(async{
    let mut s=Fake::new();let m=collect(&mut s,"/Root",attrs(true,4096),silent).await.unwrap();
    s.nodes.insert("/Root/Extra".into(),attrs(false,0));assert_eq!(revalidate(&mut s,&m,silent).await,Err(Failure::Changed));s.nodes.remove("/Root/Extra");
    s.nodes.get_mut("/Root/Café").unwrap().modified=Some(20);
    let member=m.nodes.iter().find(|n|n.parts==["Café","Report"]).unwrap();assert_eq!(ancestors(&mut s,&m,member,silent).await,Err(Failure::Changed));
    s.nodes.get_mut("/Root/Café").unwrap().modified=Some(19);s.nodes.get_mut("/Root/Café/Report").unwrap().modified=Some(20);
    assert_eq!(revalidate(&mut s,&m,silent).await,Err(Failure::Changed));
})}
#[test]fn counts_bytes_depth_and_local_names_have_fixed_caps(){runtime().block_on(async{
    for variant in 0..3{
        let mut s=Fake::default();s.nodes.insert("/Root".into(),attrs(true,0));
        if variant==0{for i in 0..=MAX_FILES{s.nodes.insert(format!("/Root/f{i:04}"),attrs(false,0));}}
        else if variant==1{s.nodes.insert("/Root/A".into(),attrs(false,MAX_BYTES));s.nodes.insert("/Root/B".into(),attrs(false,1));}
        else{let mut path="/Root".to_owned();for _ in 0..=MAX_DEPTH{path.push_str("/a");s.nodes.insert(path.clone(),attrs(true,0));}}
        assert_eq!(collect(&mut s,"/Root",attrs(true,0),silent).await.unwrap_err(),Failure::Limit);
    }
    assert!(!component(".."));assert!(!component("colon:name"));assert!(!component("\u{202e}hidden"));assert!(component("literal\\name"));
    assert!(path("/Root",&vec!["A".into();33]).is_err());assert!(path("/Root/../Other",&[]).is_err());
})}
#[test]fn endless_metadata_and_progress_failure_are_bounded(){runtime().block_on(async{
    let mut s=Fake::new();s.endless=true;
    assert!(tokio::time::timeout(Duration::from_millis(10),collect(&mut s,"/Root",attrs(true,4096),silent)).await.is_err());
    let mut s=Fake::new();let result=collect(&mut s,"/Root",attrs(true,4096),|_,_|async{Err(Failure::Output)}).await;
    assert_eq!(result.unwrap_err(),Failure::Output);
})}
#[test]fn absent_stable_identity_is_not_claimed_and_review_and_active_time_expire(){runtime().block_on(async{
    let mut s=Fake::new();let m=collect(&mut s,"/Root",attrs(true,4096),silent).await.unwrap();
    // No body/file-ID API exists in the manifest. An equal-attribute remote
    // replacement cannot be identified by SFTP-v3 metadata and remains equal.
    revalidate(&mut s,&m,silent).await.unwrap();
    let mut p=Prepared{request:[1;16],generation:[2;16],read:1,revision:1,manifest:m,spent:Duration::from_secs(2),reviewed_at:Instant::now()};
    assert_eq!(p.remaining().unwrap(),Duration::from_secs(598));p.reviewed_at=Instant::now()-Duration::from_secs(301);assert!(p.remaining().is_err());
    p.reviewed_at=Instant::now();p.spent=ACTIVE_DEADLINE;assert!(p.remaining().is_err());
})}
