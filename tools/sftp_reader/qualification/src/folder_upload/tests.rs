use super::*;
use std::{collections::{BTreeMap,HashMap},sync::atomic::Ordering,time::Duration};
use tokio::io::{AsyncReadExt,AsyncWriteExt,DuplexStream};
fn field(out:&mut Vec<u8>,value:&[u8]){out.extend((value.len()as u32).to_be_bytes());out.extend(value)}
fn number(bytes:&[u8],at:&mut usize,count:usize)->u64{let mut value=0;for b in &bytes[*at..*at+count]{value=(value<<8)|u64::from(*b)}*at+=count;value}
fn string<'a>(bytes:&'a[u8],at:&mut usize)->&'a[u8]{let size=number(bytes,at,4)as usize;let value=&bytes[*at..*at+size];*at+=size;value}
fn head(kind:u8,id:u32)->Vec<u8>{let mut out=vec![kind];out.extend(id.to_be_bytes());out}
fn status(id:u32,code:u32)->Vec<u8>{let mut out=head(101,id);out.extend(code.to_be_bytes());field(&mut out,b"");field(&mut out,b"");out}
#[derive(Clone)]struct Entry{mode:u32,bytes:Vec<u8>}
fn attributes(out:&mut Vec<u8>,entry:&Entry){out.extend(5u32.to_be_bytes());out.extend((entry.bytes.len()as u64).to_be_bytes());out.extend(entry.mode.to_be_bytes())}
#[derive(Default)]struct Seen{entries:BTreeMap<String,Entry>,ops:Vec<u8>,eof:bool,namespace_redirected:bool}
async fn peer(mut stream:DuplexStream,scenario:&'static str,stop:Arc<AtomicBool>)->Seen{
    let mut seen=Seen::default();let mut handles=HashMap::new();let mut listed=HashSet::new();let mut next=0u32;
    if scenario=="root-conflict"{seen.entries.insert("/generated/Folder".into(),Entry{mode:0o100644,bytes:b"Keep existing root".to_vec()});}
    loop{
        let length=match stream.read_u32().await{Ok(v)=>v as usize,Err(_)=>{seen.eof=true;return seen}};
        assert!((1..=upload::MAX_CHUNK+17000).contains(&length));let mut bytes=vec![0;length];stream.read_exact(&mut bytes).await.unwrap();
        let kind=bytes[0];seen.ops.push(kind);assert!(![13,15,18,20].contains(&kind));
        let id=if kind==1{0}else{u32::from_be_bytes(bytes[1..5].try_into().unwrap())};let mut at=5;
        let response=match kind{
            1=>{assert_eq!(bytes,[1,0,0,0,3]);let mut out=vec![2,0,0,0,3];if scenario!="no-sync"{field(&mut out,b"fsync@openssh.com");field(&mut out,b"1")}out},
            7=>{
                let path=String::from_utf8(string(&bytes,&mut at).to_vec()).unwrap();
                if scenario=="symlink-parent"&&path=="/generated/Folder/A"&&seen.entries.contains_key(&path){seen.entries.get_mut(&path).unwrap().mode=0o120777;}
                if scenario=="ancestor-swap"&&seen.namespace_redirected&&path=="/generated/Folder/A"{let mut out=head(105,id);attributes(&mut out,&Entry{mode:0o120777,bytes:Vec::new()});out}
                else{
                    let observed=if seen.namespace_redirected&&path.starts_with("/generated/Folder/A/"){path.replace("/generated/Folder/A/","/outside/")}else{path};
                    seen.entries.get(&observed).map_or_else(||status(id,2),|entry|{let mut out=head(105,id);attributes(&mut out,entry);out})
                }
            },
            14=>{
                let path=String::from_utf8(string(&bytes,&mut at).to_vec()).unwrap();assert_eq!(number(&bytes,&mut at,4),4);assert_eq!(number(&bytes,&mut at,4),0o755);
                if scenario=="mkdir-race"{seen.entries.insert(path,Entry{mode:0o040755,bytes:b"Keep raced directory".to_vec()});status(id,4)}
                else if seen.entries.contains_key(&path){status(id,4)}else{
                    seen.entries.insert(path,Entry{mode:0o040755,bytes:Vec::new()});
                    if scenario=="lost-mkdir"{return seen}
                    if scenario=="stop-mkdir"||scenario=="timeout-mkdir"{if scenario=="stop-mkdir"{stop.store(true,Ordering::Release)}let mut b=[0];seen.eof=stream.read(&mut b).await.unwrap_or(0)==0;return seen}
                    status(id,0)
                }
            },
            3|11=>{
                let mut path=String::from_utf8(string(&bytes,&mut at).to_vec()).unwrap();
                let flags=if kind==3{let flags=number(&bytes,&mut at,4);let attrs=number(&bytes,&mut at,4);assert!(flags==1&&attrs==0||flags==0x2b&&attrs==4);if attrs==4{assert_eq!(number(&bytes,&mut at,4),0o600)}flags}else{0};
                if flags==0x2b&&scenario=="ancestor-swap"&&path.contains("/A/"){seen.namespace_redirected=true;}
                if seen.namespace_redirected&&path.starts_with("/generated/Folder/A/"){path=path.replace("/generated/Folder/A/","/outside/");}
                if flags==0x2b&&scenario=="open-race"{seen.entries.insert(path.clone(),Entry{mode:0o100644,bytes:b"Keep raced file".to_vec()});}
                if flags==0x2b&&seen.entries.contains_key(&path){status(id,4)}else{
                    if flags==0x2b{seen.entries.insert(path.clone(),Entry{mode:0o100600,bytes:Vec::new()});}
                    assert!(seen.entries.contains_key(&path));next+=1;let handle=next.to_be_bytes().to_vec();handles.insert(handle.clone(),path);
                    let mut out=head(102,id);field(&mut out,&handle);out
                }
            },
            6=>{
                let handle=string(&bytes,&mut at).to_vec();let offset=number(&bytes,&mut at,8)as usize;let data=string(&bytes,&mut at);
                if scenario=="stop-write"{stop.store(true,Ordering::Release);let mut b=[0];seen.eof=stream.read(&mut b).await.unwrap_or(0)==0;return seen}
                let entry=seen.entries.get_mut(handles.get(&handle).unwrap()).unwrap();assert_eq!(offset,entry.bytes.len());entry.bytes.extend(data);
                let mut out=status(if scenario=="wrong-id"{id+1}else{id},0);if scenario=="trailing-status"{out.push(0)}out
            },
            8=>{let handle=string(&bytes,&mut at);let mut out=head(105,id);attributes(&mut out,seen.entries.get(handles.get(handle).unwrap()).unwrap());out},
            5=>{
                let handle=string(&bytes,&mut at);let offset=number(&bytes,&mut at,8)as usize;let count=number(&bytes,&mut at,4)as usize;assert!((1..=32768).contains(&count));
                let entry=seen.entries.get(handles.get(handle).unwrap()).unwrap();if offset>=entry.bytes.len(){status(id,1)}else{
                    let mut data=entry.bytes[offset..(offset+count).min(entry.bytes.len())].to_vec();if scenario=="corrupt-readback"{data[0]^=1}
                    let mut out=head(103,id);field(&mut out,&data);out
                }
            },
            10=>{let handle=string(&bytes,&mut at);assert_eq!(number(&bytes,&mut at,4),4);assert_eq!(number(&bytes,&mut at,4),0o644);seen.entries.get_mut(handles.get(handle).unwrap()).unwrap().mode=0o100644;status(id,0)},
            200=>{assert_eq!(string(&bytes,&mut at),b"fsync@openssh.com");assert!(handles.contains_key(string(&bytes,&mut at)));status(id,if scenario=="sync-failure"{4}else{0})},
            4=>{let handle=string(&bytes,&mut at);let path=handles.remove(handle).unwrap();
                if scenario=="lost-close"&&seen.entries[&path].mode&0o170000==0o100000{return seen}status(id,0)},
            12=>{
                let handle=string(&bytes,&mut at).to_vec();let path=handles.get(&handle).unwrap().clone();
                if scenario=="stop-final-list"{stop.store(true,Ordering::Release);let mut b=[0];seen.eof=stream.read(&mut b).await.unwrap_or(0)==0;return seen}
                if !listed.insert(handle){status(id,1)}else{
                    if scenario=="extra-member"{seen.entries.insert(format!("{path}/Extra"),Entry{mode:0o100644,bytes:Vec::new()});}
                    let values:Vec<_>=seen.entries.iter().filter(|(name,_)|name.rsplit_once('/').is_some_and(|(parent,_)|parent==path)).collect();
                    if values.is_empty(){status(id,1)}else{
                        let mut out=head(104,id);out.extend((values.len()as u32).to_be_bytes());
                        for(name,entry)in values{field(&mut out,name.rsplit_once('/').unwrap().1.as_bytes());field(&mut out,b"");attributes(&mut out,entry)}out
                    }
                }
            },
            _=>panic!("Unexpected fresh-folder opcode"),
        };
        assert_eq!(at,bytes.len());
        if stream.write_u32(response.len()as u32).await.is_err()||stream.write_all(&response).await.is_err(){return seen}
    }
}

fn encoded(nodes:&[(u8,Vec<&[u8]>,u64)])->Vec<u8>{
    let mut bytes=b"TRVFUP01".to_vec();bytes.extend((nodes.len()as u32).to_be_bytes());
    for(kind,parts,size)in nodes{bytes.extend([*kind,parts.len()as u8]);bytes.extend(size.to_be_bytes());for part in parts{bytes.extend((part.len()as u16).to_be_bytes());bytes.extend(*part)}}bytes
}
fn manifest(empty:bool)->Manifest{
    let nodes:Vec<(u8,Vec<&[u8]>,u64)>=if empty{vec![(1,vec![],0)]}else{vec![(1,vec![],0),(1,vec![b"A"],0),(2,vec![b"A",b"Member"],3),(1,vec![b"Empty"],0)]};Manifest::decode(&encoded(&nodes)).unwrap()
}
struct Local{manifest:Manifest,scenario:&'static str}
impl Source for Local{
    async fn bytes(&mut self,node:u32,offset:u64,count:usize)->Result<Vec<u8>>{
        assert_eq!(node,2);if self.scenario=="short-source"{return Ok(Vec::new())}Ok(b"abc"[offset as usize..offset as usize+count].to_vec())
    }
    async fn permit_file(&mut self,node:u32,digest:[u8;32])->Result<()>{assert_eq!(node,2);assert_eq!(digest,<[u8;32]>::from(Sha256::digest(b"abc")));if self.scenario=="source-changed"{Err(Failure::SourceChanged)}else{Ok(())}}
    async fn root_created(&mut self)->Result<()>{if self.scenario=="root-save-failure"{Err(Failure::SourceChanged)}else{Ok(())}}
    async fn verified(&mut self,node:u32,files:u32,bytes:u64)->Result<()>{assert_eq!((node,files,bytes),(2,1,3));if self.scenario=="progress-save-failure"{Err(Failure::SourceChanged)}else{Ok(())}}
    async fn finish(&mut self,digest:[u8;32])->Result<()>{
        let mut hash=Sha256::new();hash.update(&self.manifest.encoded);if self.manifest.files>0{hash.update(Sha256::digest(b"abc"))}assert_eq!(digest,<[u8;32]>::from(hash.finalize()));
        if self.scenario=="final-source-change"{Err(Failure::SourceChanged)}else{Ok(())}
    }
}
async fn run(scenario:&'static str,empty:bool)->(std::result::Result<Receipt,Interrupted>,Seen){
    let(a,b)=tokio::io::duplex(1024);let stop=Arc::new(AtomicBool::new(false));let remote=tokio::spawn(peer(b,scenario,stop.clone()));
    let manifest=manifest(empty);let result=send(a,"/generated","Folder",[1;16],&manifest,Local{manifest:manifest.clone(),scenario},
        upload::Limits{request_deadline:Duration::from_millis(150),total_deadline:Duration::from_secs(3)},Some(stop)).await;
    let seen=tokio::time::timeout(Duration::from_secs(1),remote).await.unwrap().unwrap();(result,seen)
}
#[test]fn independent_canonical_bytes_and_digest(){
    let bytes=encoded(&[(1,vec![],0),(1,vec![b"A"],0),(2,vec![b"A",b"File.txt"],3),(2,vec![b"z"],0)]);
    // Same frozen Python struct oracle as Swift, not either production encoder.
    assert_eq!(hex(&bytes),"545256465550303100000004010000000000000000000101000000000000000000014102020000000000000003000141000846696c652e7478740201000000000000000000017a");
    let value=Manifest::decode(&bytes).unwrap();assert_eq!((value.files,value.folders,value.bytes),(2,1,3));assert_eq!(value.encoded,bytes);
}
fn hex(bytes:&[u8])->String{bytes.iter().map(|b|format!("{b:02x}")).collect()}
#[test]fn malformed_versions_ordering_parents_and_bounds_refuse(){
    let good=manifest(true).encoded;for length in 0..good.len(){assert!(Manifest::decode(&good[..length]).is_err())}
    for offset in[7,8,12,13]{let mut bad=good.clone();bad[offset]=255;assert!(Manifest::decode(&bad).is_err())}
    let mut trailing=good.clone();trailing.push(0);assert!(Manifest::decode(&trailing).is_err());
    let variants:Vec<Vec<(u8,Vec<&[u8]>,u64)>>=vec![vec![(2,vec![],0)],vec![(1,vec![],1)],vec![(1,vec![],0),(2,vec![b"a",b"b"],0)],vec![(1,vec![],0),(2,vec![b"a"],0),(2,vec![b"a"],0)],vec![(1,vec![],0),(2,vec![b"z"],0),(2,vec![b"a"],0)],vec![(1,vec![],0),(2,vec![b"a"],u64::MAX)]];for nodes in variants{assert!(Manifest::decode(&encoded(&nodes)).is_err())}
    for name in[vec![],b".".to_vec(),b"..".to_vec(),b"a/b".to_vec(),vec![0],vec![255],vec![b'a';256]]{assert!(!component(&name))}
}
#[tokio::test(flavor="current_thread")]async fn complete_nested_and_empty_trees_one_init_no_remove_rename(){
    for empty in[false,true]{let(result,seen)=run("normal",empty).await;let receipt=result.unwrap();assert_eq!((receipt.files,receipt.bytes),if empty{(0,0)}else{(1,3)});assert!(seen.eof);assert_eq!(seen.ops.iter().filter(|v|**v==1).count(),1);assert!(!seen.ops.iter().any(|v|[13,15,18,20].contains(v)));if !empty{assert_eq!(seen.entries["/generated/Folder/A/Member"].bytes,b"abc");}}
}
#[tokio::test(flavor="current_thread")]async fn conflicts_do_not_replace_and_missing_sync_does_not_create(){
    for scenario in["root-conflict","mkdir-race","open-race","no-sync"]{
        let(result,seen)=run(scenario,false).await;let error=result.unwrap_err();
        if scenario=="root-conflict"{assert!(!error.root_may_exist);assert_eq!(seen.entries["/generated/Folder"].bytes,b"Keep existing root");}
        if scenario=="mkdir-race"{assert!(error.root_may_exist&&!error.root_acknowledged);assert_eq!(seen.entries["/generated/Folder"].bytes,b"Keep raced directory");}
        if scenario=="open-race"{assert!(error.root_acknowledged);assert_eq!(seen.entries["/generated/Folder/A/Member"].bytes,b"Keep raced file");assert!(!seen.ops.contains(&6));}
        if scenario=="no-sync"{assert!(!error.root_may_exist);assert_eq!(seen.ops,[1]);}
    }
}
#[tokio::test(flavor="current_thread")]async fn lost_mkdir_close_and_malformed_file_replies_remain_uncertain(){
    for scenario in["lost-mkdir","lost-close","wrong-id","trailing-status","corrupt-readback","sync-failure","symlink-parent","extra-member"]{
        let(result,seen)=run(scenario,false).await;let error=result.unwrap_err();assert!(error.root_may_exist);assert!(!seen.ops.iter().any(|v|[13,15,18].contains(v)));
        if scenario=="lost-mkdir"{assert!(!error.root_acknowledged);assert_eq!(error.verified_files,0)}
    }
}
#[tokio::test(flavor="current_thread")]async fn stop_and_deadline_drain_actual_peer_without_remote_cleanup(){
    for scenario in["stop-mkdir","timeout-mkdir","stop-write","stop-final-list"]{
        let start=std::time::Instant::now();let(result,seen)=run(scenario,false).await;let error=result.unwrap_err();assert!(matches!(error.cause,Failure::Stopped|Failure::Timeout));assert!(error.root_may_exist&&seen.eof);assert!(start.elapsed()<Duration::from_secs(1));
    }
}
#[tokio::test(flavor="current_thread")]async fn local_admission_progress_and_final_failure_never_report_success(){
    for scenario in["root-save-failure","short-source","source-changed","progress-save-failure","final-source-change"]{
        let(result,seen)=run(scenario,false).await;let error=result.unwrap_err();assert!(error.root_acknowledged&&seen.eof);
        if scenario=="root-save-failure"{assert!(!seen.ops.contains(&3));assert_eq!(error.verified_files,0)}
        if scenario=="progress-save-failure"||scenario=="final-source-change"{assert_eq!((error.verified_files,error.verified_bytes),(1,3))}
    }
}
#[tokio::test(flavor="current_thread")]async fn same_account_ancestor_substitution_is_an_explicit_negative_capability(){
    let(result,seen)=run("ancestor-swap",false).await;assert!(result.is_err());assert!(seen.namespace_redirected);
    // Observed checks detect the changed ancestor only after a path operation
    // was redirected. This proves the stable-namespace condition is necessary.
    assert_eq!(seen.entries["/outside/Member"].bytes,b"abc");
}
