//! F1 is deliberately a separate, bounded selected-tree conversation.
use super::{download_wire::Selection,wire::{self,Issue}};
pub const MAGIC:&str="MEXSMBF1";
pub const MAX_FRAME:usize=32768+101;
#[derive(Debug,PartialEq,Eq)]
pub enum Command{Prepare(Selection),Begin{token:String,ordinal:u64},Release{token:String,ordinal:u64},Ack{token:String,ordinal:u64,member:usize,sequence:u64,offset:u64}}
pub fn command(line:&str)->Result<Command,Issue>{
    let p=line.split(' ').collect::<Vec<_>>();
    match p.first().copied(){
        Some("PREPARE_FOLDER")if p.len()==7=>{
            let original=line.replacen("PREPARE_FOLDER","PREPARE_DOWNLOAD",1);
            match super::download_wire::command(&original)?{super::download_wire::Command::Prepare(s)=>Ok(Command::Prepare(s)),_=>Err(Issue::Invalid)}
        },
        Some(kind@("BEGIN_FOLDER"|"RELEASE_FOLDER"))if p.len()==3&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(if kind=="BEGIN_FOLDER"{Command::Begin{token:p[1].into(),ordinal}}else{Command::Release{token:p[1].into(),ordinal}})
        },
        Some("ACK_FOLDER")if p.len()==6&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;let member=wire::number(p[3])?;let sequence=wire::number(p[4])?;let offset=wire::number(p[5])?;
            if ordinal==0||member==0||member>=2048||offset==0||offset>256<<20{return Err(Issue::Invalid);}
            Ok(Command::Ack{token:p[1].into(),ordinal,member,sequence,offset})
        },_=>Err(Issue::Invalid),
    }
}
pub fn framed(payload:&[u8])->Result<Vec<u8>,Issue>{
    if payload.is_empty()||payload.len()>MAX_FRAME{return Err(Issue::Invalid);}
    let mut bytes=Vec::with_capacity(payload.len()+4);bytes.extend((payload.len()as u32).to_be_bytes());bytes.extend(payload);Ok(bytes)
}
pub fn data(session:&str,global:u64,selection:&Selection,member:usize,sequence:u64,offset:u64,bytes:&[u8])->Result<Vec<u8>,Issue>{
    if member==0||member>=2048||offset.checked_add(bytes.len()as u64).is_none_or(|v|v>256<<20){return Err(Issue::Invalid);}
    let old=super::download_wire::data(session,global,&selection.token,selection.ordinal,sequence,offset,bytes)?;
    let mut out=Vec::with_capacity(old.len()+4);out.push(1);out.extend(MAGIC.as_bytes());out.extend(&old[9..77]);out.extend((member as u32).to_be_bytes());out.extend(&old[77..]);Ok(out)
}
#[cfg(test)]mod tests{
    use super::*;
    const A:&str="77777777-7777-4777-8777-777777777777";const B:&str="88888888-8888-4888-8888-888888888888";
    #[test]fn strict_folder_commands(){
        assert!(matches!(command(&format!("PREPARE_FOLDER {A} 1 1 {B} 2 9")),Ok(Command::Prepare(_))));
        assert!(command(&format!("ACK_FOLDER {A} 1 1 0 1")).is_ok());
        for bad in [format!("PREPARE_DOWNLOAD {A} 1 1 {B} 2 9"),format!("PREPARE_FOLDER {A} 01 1 {B} 2 9"),format!("ACK_FOLDER {A} 1 0 0 1"),format!("ACK_FOLDER {A} 1 2048 0 1"),format!("ACK_FOLDER {A} 1 1 0 268435457"),format!("BEGIN_FOLDER {A} 1 extra")]{assert!(command(&bad).is_err());}
    }
    #[test]fn member_binary_extent(){
        let selection=Selection{token:B.into(),ordinal:2,number:1,generation:A.into(),revision:1,observation:1};
        for count in [1,32768]{let bytes=data(A,7,&selection,19,3,9,&vec![0x81;count]).unwrap();assert_eq!(bytes.len(),101+count);assert_eq!(&bytes[..9],b"\x01MEXSMBF1");assert_eq!(&bytes[77..81],&19u32.to_be_bytes());assert_eq!(&bytes[81..89],&3u64.to_be_bytes());assert_eq!(&bytes[89..97],&9u64.to_be_bytes());assert_eq!(&bytes[97..101],&(count as u32).to_be_bytes());assert!(framed(&bytes).is_ok());}
        assert!(data(A,0,&selection,0,0,0,&[1]).is_err());assert!(data(A,0,&selection,1,0,256<<20,&[1]).is_err());assert!(framed(&vec![0;MAX_FRAME+1]).is_err());
    }
}
