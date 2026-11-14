//! Generated encrypted-peer adapter derived from the independently scripted H
//! test peer. Never bundled; its fixed namespace contains only disposable data.
use super::Counts;
use std::{collections::{BTreeMap,HashMap,HashSet},sync::{Arc,atomic::Ordering}};
use tokio::io::{AsyncReadExt,AsyncWriteExt};
use russh::{server,ChannelStream};
use macexplorer_sftp_reader_qualification::upload;
use sha2::{Digest,Sha256};
fn field(out:&mut Vec<u8>,value:&[u8]){out.extend((value.len()as u32).to_be_bytes());out.extend(value)}
fn number(bytes:&[u8],at:&mut usize,count:usize)->u64{let mut value=0;for b in &bytes[*at..*at+count]{value=(value<<8)|u64::from(*b)}*at+=count;value}
fn string<'a>(bytes:&'a[u8],at:&mut usize)->&'a[u8]{let size=number(bytes,at,4)as usize;let value=&bytes[*at..*at+size];*at+=size;value}
fn head(kind:u8,id:u32)->Vec<u8>{let mut out=vec![kind];out.extend(id.to_be_bytes());out}
fn status(id:u32,code:u32)->Vec<u8>{let mut out=head(101,id);out.extend(code.to_be_bytes());field(&mut out,b"");field(&mut out,b"");out}
#[derive(Clone)]struct Entry{mode:u32,bytes:Vec<u8>}
fn attributes(out:&mut Vec<u8>,entry:&Entry){out.extend(5u32.to_be_bytes());out.extend((entry.bytes.len()as u64).to_be_bytes());out.extend(entry.mode.to_be_bytes())}
#[derive(Default)]pub struct Seen{entries:BTreeMap<String,Entry>,ops:Vec<u8>,eof:bool,namespace_redirected:bool}
async fn work(mut stream:ChannelStream<server::Msg>,scenario:&str,counts:&Counts)->Seen{
    let mut seen=Seen::default();let mut handles=HashMap::new();let mut listed=HashSet::new();let mut next=0u32;
    if scenario=="root-conflict"{seen.entries.insert("/generated/Folder".into(),Entry{mode:0o100644,bytes:b"Keep existing root".to_vec()});}
    loop{
        let length=match stream.read_u32().await{Ok(v)=>v as usize,Err(_)=>{seen.eof=true;return seen}};
        assert!((1..=upload::MAX_CHUNK+17000).contains(&length));let mut bytes=vec![0;length];stream.read_exact(&mut bytes).await.unwrap();
        let kind=bytes[0];counts.requests.fetch_add(1,Ordering::SeqCst);seen.ops.push(kind);assert!(![13,15,18,20].contains(&kind));
        let id=if kind==1{0}else{u32::from_be_bytes(bytes[1..5].try_into().unwrap())};let mut at=5;
        let response=match kind{
            1=>{at=bytes.len();assert_eq!(bytes,[1,0,0,0,3]);let mut out=vec![2,0,0,0,3];if scenario!="no-sync"{field(&mut out,b"fsync@openssh.com");field(&mut out,b"1")}out},
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
                    if scenario=="stop-mkdir"||scenario=="timeout-mkdir"{if scenario=="stop-mkdir"{counts.upload_waiting.store(1,Ordering::Release)}let mut b=[0];seen.eof=stream.read(&mut b).await.unwrap_or(0)==0;return seen}
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
                    if flags==0x2b{seen.entries.insert(path.clone(),Entry{mode:0o100600,bytes:Vec::new()});if scenario=="lost-open"{return seen}}
                    assert!(seen.entries.contains_key(&path));next+=1;let handle=next.to_be_bytes().to_vec();handles.insert(handle.clone(),path);
                    let mut out=head(102,id);field(&mut out,&handle);out
                }
            },
            6=>{
                let handle=string(&bytes,&mut at).to_vec();let offset=number(&bytes,&mut at,8)as usize;let data=string(&bytes,&mut at);
                if scenario=="stop-write"{counts.upload_waiting.store(1,Ordering::Release);let mut b=[0];seen.eof=stream.read(&mut b).await.unwrap_or(0)==0;return seen}
                let entry=seen.entries.get_mut(handles.get(&handle).unwrap()).unwrap();assert_eq!(offset,entry.bytes.len());entry.bytes.extend(data);
                let mut out=status(if scenario=="wrong-id"{id+1}else{id},0);if scenario=="trailing-status"{out.push(0)}out
            },
            8=>{let handle=string(&bytes,&mut at);let mut out=head(105,id);attributes(&mut out,seen.entries.get(handles.get(handle).unwrap()).unwrap());out},
            5=>{
                let handle=string(&bytes,&mut at);let offset=number(&bytes,&mut at,8)as usize;let count=number(&bytes,&mut at,4)as usize;assert!((1..=32768).contains(&count));
                if scenario=="stop-readback"{counts.upload_waiting.store(3,Ordering::Release);let mut byte=[0];seen.eof=stream.read(&mut byte).await.unwrap_or(0)==0;return seen}
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
                if scenario=="stop-final-list"{counts.upload_waiting.store(1,Ordering::Release);let mut b=[0];seen.eof=stream.read(&mut b).await.unwrap_or(0)==0;return seen}
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

pub async fn serve(stream:ChannelStream<server::Msg>,scenario:String,counts:Arc<Counts>){
    let name=scenario.strip_prefix("fresh-").unwrap();
    let seen=work(stream,name,&counts).await;*counts.fresh_upload.lock().unwrap()=seen;
}
pub fn observation(seen:&Seen)->String{
    let entries:Vec<_>=seen.entries.iter().map(|(name,item)|{
        assert!(["/generated/Folder","/generated/Folder/A","/generated/Folder/A/Member","/generated/Folder/Empty"].contains(&name.as_str()));
        let digest=Sha256::digest(&item.bytes).iter().map(|v|format!("{v:02x}")).collect::<String>();
        format!("{{\"name\":\"{name}\",\"mode\":{},\"bytes\":{},\"sha256\":\"{digest}\"}}",item.mode,item.bytes.len())
    }).collect();
    format!("{{\"freshFolderObservation\":true,\"entries\":[{}],\"operations\":{:?},\"eof\":{},\"forbiddenMutations\":{}}}",entries.join(","),seen.ops,seen.eof,
        seen.ops.iter().filter(|&&v|[13,15,18,20].contains(&v)).count())
}
