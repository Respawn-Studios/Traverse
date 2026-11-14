//! Generated immutable tree and explicit fault controls. No local file/remote
//! host, mutation command or credential discovery is implemented in this peer.
use super::*;
use std::collections::BTreeMap;
#[derive(Default)]pub struct State{pub opens:usize,pub root_observations:usize}
#[derive(Clone)]struct Node{mode:u32,size:u64}
fn tree(scenario:&str)->BTreeMap<String,Node>{
    let mut result=BTreeMap::new();
    for(path,directory,size)in[("/generated",true,4096),("/generated/Folder",true,4096),("/generated/Empty",true,0),
        ("/generated/Folder/Café",true,4096),("/generated/Folder/Café/Report.bin",false,65_553),
        ("/generated/Folder/Empty",true,0),("/generated/Folder/Zero\\file",false,0),("/generated/Folder/Readme.txt",false,17)]{
        result.insert(path.into(),Node{mode:if directory{0o040755}else{0o100644},size});
    }
    match scenario{
        "folder-link"=>{result.insert("/generated/Folder/Link".into(),Node{mode:0o120777,size:7});},
        "folder-collision"=>{for name in["Case","case"]{result.insert(format!("/generated/Folder/{name}"),Node{mode:0o100644,size:0});}},
        "folder-limit"=>{for i in 0..1025{result.insert(format!("/generated/Folder/f{i:04}"),Node{mode:0o100644,size:0});}},
        _=>{}
    }result
}
fn attrs(id:u32,node:&Node,modified:u32)->Vec<u8>{let mut b=head(105,id);word(&mut b,13);b.extend(node.size.to_be_bytes());word(&mut b,node.mode);word(&mut b,0);word(&mut b,modified);b}
fn path_field(body:&[u8])->Option<(&str,usize)>{
    if body.len()<9{return None}let size=u32::from_be_bytes(body[5..9].try_into().ok()?)as usize;
    if size>8192||size>body.len()-9{return None}Some((std::str::from_utf8(&body[9..9+size]).ok()?,9+size))
}
fn canonical_path(path:&str)->String{
    if path=="."{"/generated".into()}
    else if let Some(relative)=path.strip_prefix("./"){format!("/generated/{relative}")}
    else{path.into()}
}
pub fn generated(path:&str,offset:u64)->u8{((offset*31+path.bytes().map(u64::from).sum::<u64>())%251)as u8}
pub async fn serve(mut stream:ChannelStream<server::Msg>,scenario:String,counts:Arc<Counts>){
    let nodes=tree(&scenario);let mut opened:Option<(String,bool)>=None;let mut listed=0usize;let mut offset=0u64;let mut slow_steps=0;
    loop{
        let Ok(length)=stream.read_u32().await else{return};if !(1..=8224).contains(&length){return}
        let mut body=vec![0;length as usize];if stream.read_exact(&mut body).await.is_err(){return}
        counts.requests.fetch_add(1,Ordering::SeqCst);let kind=body[0];
        if kind!=1&&body.len()<9{return}let id=if kind==1{0}else{u32::from_be_bytes(body[1..5].try_into().unwrap())};
        if let Some((path,_))=path_field(&body){
            if slow_round_trip(&scenario,path,kind,slow_steps){slow_steps+=1;tokio::time::sleep(Duration::from_secs(17)).await;}
        }
        let reply=match kind{
            1 if body==[1,0,0,0,3]=>vec![2,0,0,0,3],
            16=>{let Some((path,end))=path_field(&body)else{return};if end!=body.len(){return}
                let canonical=canonical_path(path);
                if !nodes.contains_key(&canonical){status(id,2)}else{let mut b=head(104,id);word(&mut b,1);text(&mut b,canonical.as_bytes());text(&mut b,b"");word(&mut b,0);b}},
            7|8=>{
                let Some((value,end))=path_field(&body)else{return};if end!=body.len(){return}
                let path=if kind==8{if let Some((path,false))=&opened{if value!="file-handle"{return}path.as_str()}else{return}}else{value};
                if let Some(node)=nodes.get(path){
                    let mut state=counts.folder.lock().unwrap();
                    if path=="/generated/Folder"&&kind==7{state.root_observations+=1;}
                    let modified=if scenario=="folder-changed-review"&&path=="/generated/Folder"&&state.root_observations>=3
                        ||scenario=="folder-changed-body"&&kind==8&&offset>0{20}else{19};attrs(id,node,modified)
                }else{status(id,2)}
            },
            11|3=>{
                let Some((path,end))=path_field(&body)else{return};let directory=kind==11;
                if opened.is_some()||directory&&end!=body.len()||!directory&&body.get(end..)!=Some(&[0,0,0,1,0,0,0,0][..]){return}
                if let Some(node)=nodes.get(path){
                    if directory!=(node.mode&0o170000==0o040000){status(id,4)}
                    else if !directory&&scenario=="folder-denied"{status(id,3)}
                    else{
                        if !directory{counts.folder.lock().unwrap().opens+=1;}
                        opened=Some((path.into(),directory));listed=0;offset=0;
                        let mut b=head(102,id);text(&mut b,if directory{b"directory-handle"}else{b"file-handle"});b
                    }
                }else{status(id,2)}
            },
            12=>{
                let Some((handle,end))=path_field(&body)else{return};if end!=body.len()||handle!="directory-handle"{return}
                let Some((path,true))=&opened else{return};let prefix=path.to_owned()+"/";
                let mut rows:Vec<_>=nodes.iter().filter_map(|(path,node)|{let name=path.strip_prefix(&prefix)?;(!name.contains('/')).then(||(name.to_owned(),node.clone()))}).collect();
                if scenario=="folder-final-membership"&&path=="/generated/Folder"&&counts.folder.lock().unwrap().opens>=3{rows.push(("Extra".into(),Node{mode:0o100644,size:0}));}
                if listed>=rows.len(){status(id,1)}else{
                    let count=(rows.len()-listed).min(256);let mut b=head(104,id);word(&mut b,count as u32);
                    for(name,node)in&rows[listed..listed+count]{text(&mut b,name.as_bytes());text(&mut b,b"");word(&mut b,13);b.extend(node.size.to_be_bytes());word(&mut b,node.mode);word(&mut b,0);word(&mut b,19);}
                    listed+=count;b
                }
            },
            5=>{
                let Some((handle,end))=path_field(&body)else{return};if handle!="file-handle"||body.len()!=end+12{return}
                let Some((path,false))=&opened else{return};let size=nodes[path].size;
                let at=u64::from_be_bytes(body[end..end+8].try_into().unwrap());let wanted=u32::from_be_bytes(body[end+8..].try_into().unwrap())as u64;
                if at!=offset||!(1..=32768).contains(&wanted){return}counts.file_reads.fetch_add(1,Ordering::SeqCst);
                if scenario=="folder-stop"{counts.folder_waiting.store(1,Ordering::SeqCst);let mut byte=[0];let _=stream.read(&mut byte).await;return}
                if offset==size{status(id,1)}else{
                    let end=(offset+wanted).min(size);let bytes=(offset..end).map(|i|generated(path,i)).collect::<Vec<_>>();offset=end;
                    let mut b=head(103,if scenario=="folder-malformed"{id+1}else{id});text(&mut b,&bytes);b
                }
            },
            4=>{
                let Some((handle,end))=path_field(&body)else{return};if end!=body.len(){return}
                let Some((path,directory))=opened.take()else{return};
                if handle!=if directory{"directory-handle"}else{"file-handle"}{return}
                counts.closes.fetch_add(1,Ordering::SeqCst);
                if denied_directory_close(&scenario,&path,directory){status(id,3)}
                else if !directory&&scenario=="folder-lost-close"{counts.folder_waiting.store(2,Ordering::SeqCst);let mut byte=[0];let _=stream.read(&mut byte).await;return}
                else{status(id,0)}
            },
            _=>{counts.rejected.fetch_add(1,Ordering::SeqCst);return}
        };
        if stream.write_u32(reply.len()as u32).await.is_err()||stream.write_all(&reply).await.is_err(){return}
    }
}
fn denied_directory_close(scenario:&str,path:&str,directory:bool)->bool{
    scenario=="folder-denied-close"&&directory&&path=="/generated/Folder"
}
fn slow_round_trip(scenario:&str,path:&str,kind:u8,step:usize)->bool{
    scenario=="folder-slow-body"&&path=="/generated/Folder/Café/Report.bin"&&(kind==7&&step==0||kind==3&&step==1)
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn generated_tree_has_fixed_types_bodies_and_no_source_io(){
        let nodes=tree("folder-success");assert_eq!(nodes.len(),8);assert_eq!(nodes.values().filter(|n|n.mode&0o170000==0o100000).map(|n|n.size).sum::<u64>(),65570);
        assert_eq!(generated("/generated/Folder/Readme.txt",0),generated("/generated/Folder/Readme.txt",251));
        assert_eq!(tree("folder-limit").len(),1033);assert_eq!(tree("folder-link")["/generated/Folder/Link"].mode,0o120777);
    }
    #[test]fn malformed_path_field_never_reads_outside_input(){
        for size in[0usize,1,4,8]{assert!(path_field(&vec![0;size]).is_none());}
        let mut body=head(7,1);word(&mut body,u32::MAX);assert!(path_field(&body).is_none());
    }
    #[test]fn close_fault_starts_only_at_selected_folder_not_ordinary_parent_listing(){
        assert!(denied_directory_close("folder-denied-close","/generated/Folder",true));
        assert!(!denied_directory_close("folder-denied-close","/generated",true));
        assert!(!denied_directory_close("folder-denied-close","/generated/Folder",false));
    }
    #[test]fn slow_round_trips_are_only_two_body_operations_below_the_individual_deadline(){
        let path="/generated/Folder/Café/Report.bin";
        assert!(slow_round_trip("folder-slow-body",path,7,0));assert!(slow_round_trip("folder-slow-body",path,3,1));
        assert!(!slow_round_trip("folder-slow-body",path,7,2));assert!(!slow_round_trip("folder-slow-metadata",path,7,0));
    }
    #[test]fn browser_home_relative_descendants_resolve_before_opening(){
        assert_eq!(canonical_path("."),"/generated");
        assert_eq!(canonical_path("./Folder"),"/generated/Folder");
        assert_eq!(canonical_path("./Folder/Café"),"/generated/Folder/Café");
        assert_eq!(canonical_path("/generated/Empty"),"/generated/Empty");
    }
}
