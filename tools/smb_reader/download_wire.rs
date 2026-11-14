//! Bounded explicitly selected transfer protocol, used only by the new mode.
use super::wire::{self,Issue};
pub const MAGIC:&str="MEXSMBD1";
pub const MAX_FRAME:usize=32768+97;
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Selection {pub token:String,pub ordinal:u64,pub number:u64,pub generation:String,pub revision:i64,pub observation:i64}
#[derive(Debug,PartialEq,Eq)]
pub enum Command {Prepare(Selection),Begin{token:String,ordinal:u64},Ack{token:String,ordinal:u64,sequence:u64,offset:u64},Release{token:String,ordinal:u64}}
pub fn command(line:&str)->Result<Command,Issue>{
    let f=line.split(' ').collect::<Vec<_>>();
    match f.first().copied(){
        Some("PREPARE_DOWNLOAD")if f.len()==7&&wire::uuid(f[1])&&wire::uuid(f[4])=>{
            let ordinal=wire::number(f[2])?;let number=wire::number(f[3])?;let revision=wire::number(f[5])?;let observation=wire::number(f[6])?;
            if ordinal==0||number==0||revision<0||observation<=0{return Err(Issue::Invalid);}
            Ok(Command::Prepare(Selection{token:f[1].into(),ordinal,number,generation:f[4].into(),revision,observation}))
        },
        Some(kind @("BEGIN_DOWNLOAD"|"RELEASE_DOWNLOAD"))if f.len()==3&&wire::uuid(f[1])=>{
            let ordinal=wire::number(f[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(if kind=="BEGIN_DOWNLOAD"{Command::Begin{token:f[1].into(),ordinal}}else{Command::Release{token:f[1].into(),ordinal}})
        },
        Some("ACK_DOWNLOAD")if f.len()==5&&wire::uuid(f[1])=>{
            let ordinal=wire::number(f[2])?;let sequence=wire::number(f[3])?;let offset=wire::number::<u64>(f[4])?;
            if ordinal==0||offset==0||offset>1<<30{return Err(Issue::Invalid);}
            Ok(Command::Ack{token:f[1].into(),ordinal,sequence,offset})
        },_=>Err(Issue::Invalid),
    }
}
/// Binary bytes never pass through a text/log formatter. Sequence is global.
/// Fixed header: tag+magic(9), session(36), global/chunk sequences and offset,
/// request UUID(16), length(4), then the bounded data.
pub fn data(session:&str,global:u64,token:&str,ordinal:u64,sequence:u64,offset:u64,bytes:&[u8])->Result<Vec<u8>,Issue>{
    if !wire::uuid(session)||!wire::uuid(token)||ordinal==0||bytes.is_empty()||bytes.len()>32768||offset.checked_add(bytes.len()as u64).is_none_or(|v|v>1<<30){return Err(Issue::Invalid);}
    let mut out=Vec::with_capacity(97+bytes.len());out.push(0);out.extend(MAGIC.as_bytes());out.extend(session.as_bytes());
    out.extend(global.to_be_bytes());out.extend(wire::generation(token)?);out.extend(ordinal.to_be_bytes());out.extend(sequence.to_be_bytes());out.extend(offset.to_be_bytes());
    out.extend((bytes.len()as u32).to_be_bytes());out.extend(bytes);Ok(out)
}
pub fn framed(payload:&[u8])->Result<Vec<u8>,Issue>{
    if payload.is_empty()||payload.len()>MAX_FRAME{return Err(Issue::Invalid);}
    let mut out=Vec::with_capacity(4+payload.len());out.extend((payload.len()as u32).to_be_bytes());out.extend(payload);Ok(out)
}
#[cfg(test)]mod tests{
    use super::*;
    const A:&str="77777777-7777-4777-8777-777777777777";
    const B:&str="88888888-8888-4888-8888-888888888888";
    #[test]fn exact_commands_keep_selection_typed(){
        assert_eq!(command(&format!("PREPARE_DOWNLOAD {A} 1 1 {B} 2 9")).unwrap(),Command::Prepare(Selection{token:A.into(),ordinal:1,number:1,generation:B.into(),revision:2,observation:9}));
        for bad in [format!("PREPARE_DOWNLOAD {A} 01 1 {B} 2 9"),format!("PREPARE_DOWNLOAD {A} 1 1 {B} -1 9"),format!("PREPARE_DOWNLOAD {A} 1 1 {B} 2 0"),format!("PREPARE_DOWNLOAD {A} 1 1 {B} 2 9 extra"),
            format!("ACK_DOWNLOAD {A} 1 0 0"),format!("ACK_DOWNLOAD {A} 1 0 1073741825"),format!("BEGIN_DOWNLOAD {A} 1 extra")]{assert!(command(&bad).is_err());}
        assert_eq!(command(&format!("ACK_DOWNLOAD {A} 1 0 1")).unwrap(),Command::Ack{token:A.into(),ordinal:1,sequence:0,offset:1});
    }
    #[test]fn binary_extents_are_fixed_bounded_and_not_text(){
        for size in [1,32767,32768]{let bytes=vec![0xff;size];let frame=data(A,3,B,1,0,0,&bytes).unwrap();
            assert_eq!(frame.len(),97+size);assert_eq!(&frame[..9],b"\0MEXSMBD1");assert_eq!(&frame[9..45],A.as_bytes());
            assert_eq!(&frame[45..53],&3u64.to_be_bytes());assert_eq!(&frame[53..69],&wire::generation(B).unwrap());
            assert_eq!(&frame[69..77],&1u64.to_be_bytes());assert_eq!(&frame[77..85],&0u64.to_be_bytes());assert_eq!(&frame[85..93],&0u64.to_be_bytes());assert_eq!(&frame[93..97],&(size as u32).to_be_bytes());
            let outer=framed(&frame).unwrap();assert_eq!(&outer[..4],&(frame.len()as u32).to_be_bytes());
        }
        for bytes in [vec![],vec![0;32769]]{assert!(data(A,0,B,1,0,0,&bytes).is_err());}
        assert!(data(A,0,B,1,0,u64::MAX,&[1]).is_err());assert!(framed(&vec![0;MAX_FRAME+1]).is_err());
    }
}
