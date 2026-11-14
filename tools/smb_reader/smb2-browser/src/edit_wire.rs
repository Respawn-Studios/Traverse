//! E1: one bounded original-file edit on U1's encrypted, serial lane.
use super::wire::{self,Issue};
use smb2::client::selected_download::FileSnapshot;
use smb2::client::selected_edit::EditAttributeContract;

pub const MAX_FRAME:usize=32768+73;
/// Mirror the native bounded text value at the last worker boundary. The
/// application transmits encoded bytes, including an optional leading BOM.
pub fn valid_text(bytes:&[u8])->bool{
    if bytes.len()>1<<20 || std::str::from_utf8(bytes).is_err(){return false;}
    let content=bytes.strip_prefix(&[0xef,0xbb,0xbf]).unwrap_or(bytes);
    let mut index=0usize;let(mut lines,mut width,mut lf,mut crlf)=(1usize,0usize,0usize,0usize);
    while index<content.len(){
        let byte=content[index];
        if byte==0 || content[index..].starts_with(&[0xc2,0x85])
            || content[index..].starts_with(&[0xe2,0x80,0xa8])
            || content[index..].starts_with(&[0xe2,0x80,0xa9]){return false;}
        if byte==13 {
            if content.get(index+1)!=Some(&10){return false;}
            crlf+=1;lines+=1;width=0;index+=2;
        }else if byte==10 {lf+=1;lines+=1;width=0;index+=1;}
        else {width+=1;index+=1;}
        if lines>20000 || width>65536{return false;}
    }
    lf==0 || crlf==0
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Selection {
    pub token:String,pub ordinal:u64,pub number:u64,pub generation:String,pub revision:i64,pub observation:i64,
    pub baseline:FileSnapshot,pub before:[u8;32],pub edited_len:u64,pub edited:[u8;32],
    pub attribute_contract:EditAttributeContract,
    /// The completed private Open UUID. Older edit commands retain their
    /// current-catalog semantics and never infer this authority.
    pub source:Option<String>,
}
#[derive(Debug,PartialEq,Eq)]
pub enum Command {
    Prepare(Selection),
    Data{token:String,ordinal:u64,sequence:u64,offset:u64,bytes:Vec<u8>},
    Authorize{token:String,ordinal:u64},
}
fn digest(value:&str)->Result<[u8;32],Issue>{
    if value.len()!=64 || !value.bytes().all(|b|b.is_ascii_digit()||(b'a'..=b'f').contains(&b)){return Err(Issue::Invalid);}
    let mut out=[0;32];
    for (at,byte) in out.iter_mut().enumerate(){*byte=u8::from_str_radix(&value[at*2..at*2+2],16).map_err(|_|Issue::Invalid)?;}
    Ok(out)
}
pub fn command(line:&str)->Result<Command,Issue>{
    let p=line.split(' ').collect::<Vec<_>>();
    match p.first().copied(){
        Some("PREPARE_EDIT"|"PREPARE_EDIT_V2"|"PREPARE_EDIT_V3"|
            "PREPARE_EDIT_SOURCE"|"PREPARE_EDIT_SOURCE_V2"|"PREPARE_EDIT_SOURCE_V3")
            if (p.len()==20 && !p[0].starts_with("PREPARE_EDIT_SOURCE")
                || p.len()==21 && p[0].starts_with("PREPARE_EDIT_SOURCE") && wire::uuid(p[20]))
                && wire::uuid(p[1]) && wire::uuid(p[4])=>{
            let attribute_contract=match p[0]{
                "PREPARE_EDIT_V2"|"PREPARE_EDIT_SOURCE_V2"=>EditAttributeContract::ArchiveWriteV2,
                "PREPARE_EDIT_V3"|"PREPARE_EDIT_SOURCE_V3"=>EditAttributeContract::ArchiveWriteCreationApproxV3,
                _=>EditAttributeContract::ExactV1,
            };
            let ordinal=wire::number(p[2])?;
            let number=wire::number(p[3])?;
            let revision=wire::number(p[5])?;
            let observation=wire::number(p[6])?;
            let baseline=FileSnapshot{
                size:wire::number(p[7])?,allocated:wire::number(p[8])?,created:wire::number(p[9])?,
                modified:wire::number(p[10])?,changed:wire::number(p[11])?,attributes:wire::number(p[12])?,
                links:wire::number(p[13])?,index:wire::number(p[14])?,volume_created:wire::number(p[15])?,
                volume_serial:wire::number(p[16])?,
            };
            let before=digest(p[17])?;
            let edited_len=wire::number(p[18])?;
            let edited=digest(p[19])?;
            if ordinal==0 || number==0 || revision<=0 || observation<=0 || baseline.size>1<<20
                || edited_len>1<<20 || baseline.links!=1 || baseline.attributes&0x451!=0
                || baseline.index==0 || baseline.index==u64::MAX || baseline.volume_serial==0 {
                return Err(Issue::Invalid);
            }
            Ok(Command::Prepare(Selection{token:p[1].into(),ordinal,number,generation:p[4].into(),
                revision,observation,baseline,before,edited_len,edited,attribute_contract,
                source:(p.len()==21).then(||p[20].into())}))
        },
        Some("AUTHORIZE_EDIT") if p.len()==3 && wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(Command::Authorize{token:p[1].into(),ordinal})
        },
        _=>Err(Issue::Invalid),
    }
}
pub fn binary(payload:&[u8])->Result<Command,Issue>{
    if payload.len()<74 || payload.len()>MAX_FRAME || payload[0]!=5 || &payload[1..9]!=super::upload_wire::MAGIC.as_bytes(){
        return Err(Issue::Invalid);
    }
    let token=std::str::from_utf8(&payload[9..45]).map_err(|_|Issue::Invalid)?;
    if !wire::uuid(token){return Err(Issue::Invalid);}
    let ordinal=u64::from_be_bytes(payload[45..53].try_into().map_err(|_|Issue::Invalid)?);
    let sequence=u64::from_be_bytes(payload[53..61].try_into().map_err(|_|Issue::Invalid)?);
    let offset=u64::from_be_bytes(payload[61..69].try_into().map_err(|_|Issue::Invalid)?);
    let count=u32::from_be_bytes(payload[69..73].try_into().map_err(|_|Issue::Invalid)?) as usize;
    if ordinal==0 || count==0 || count>32768 || payload.len()!=73+count
        || offset.checked_add(count as u64).is_none_or(|end|end>1<<20){return Err(Issue::Invalid);}
    Ok(Command::Data{token:token.into(),ordinal,sequence,offset,bytes:payload[73..].to_vec()})
}
#[cfg(test)]mod tests{
    use super::*;
    const A:&str="77777777-7777-4777-8777-777777777777";
    const B:&str="88888888-8888-4888-8888-888888888888";
    #[test]fn edit_command_requires_single_link_bounded_identity_and_digest(){
        let line=format!("PREPARE_EDIT {A} 1 1 {B} 2 9 0 0 1 2 3 32 1 4 5 6 {} 0 {}", "ab".repeat(32),"cd".repeat(32));
        assert!(matches!(command(&line),Ok(Command::Prepare(_))));
        let v2=line.replacen("PREPARE_EDIT ","PREPARE_EDIT_V2 ",1);
        assert!(matches!(command(&v2),Ok(Command::Prepare(Selection{
            attribute_contract:EditAttributeContract::ArchiveWriteV2,..}))));
        assert!(matches!(wire::command_policy(&v2,wire::Mode::Upload),Ok(wire::Command::Edit(Command::Prepare(_)))));
        assert!(wire::command_policy(&v2,wire::Mode::Metadata).is_err());
        assert!(matches!(command(&line),Ok(Command::Prepare(Selection{
            attribute_contract:EditAttributeContract::ExactV1,..}))));
        let v3=v2.replacen("PREPARE_EDIT_V2 ","PREPARE_EDIT_V3 ",1);
        assert!(matches!(command(&v3),Ok(Command::Prepare(Selection{
            attribute_contract:EditAttributeContract::ArchiveWriteCreationApproxV3,..}))));
        let retained=format!("{} {A}",v3.replacen("PREPARE_EDIT_V3 ","PREPARE_EDIT_SOURCE_V3 ",1));
        assert!(matches!(command(&retained),Ok(Command::Prepare(Selection{
            source:Some(token),attribute_contract:EditAttributeContract::ArchiveWriteCreationApproxV3,..}))if token==A));
        assert!(wire::command_policy(&retained,wire::Mode::File).is_err());
        assert!(command(&format!("{v3} {A}")).is_err());
        assert!(matches!(wire::command_policy(&v3,wire::Mode::Upload),Ok(wire::Command::Edit(Command::Prepare(_)))));
        assert!(wire::command_policy(&v3,wire::Mode::Metadata).is_err());
        assert!(command(&v3.replace("PREPARE_EDIT_V3 ","PREPARE_EDIT_V4 ")).is_err());
        assert!(command(&line.replace(" 32 1 4 "," 32 2 4 ")).is_err());
        assert!(command(&line.replace(" 0 0 1 2 "," 1048577 0 1 2 ")).is_err());
        assert!(command(&line.replace(" 0 0 1 2 "," 0 0 1 2 ").replace("cdcd","CDCD")).is_err());
        assert!(command(&format!("AUTHORIZE_EDIT {A} 1")).is_ok());
        assert!(command(&format!("AUTHORIZE_EDIT {A} 0")).is_err());
    }
    #[test]fn edited_body_requires_same_bounded_utf8_profile_as_native_text(){
        assert!(valid_text(b""));assert!(valid_text(b"a\nb"));
        assert!(valid_text(b"\xef\xbb\xbfa\r\nb"));
        assert!(!valid_text(b"a\0b"));assert!(!valid_text(b"a\rb"));
        assert!(!valid_text(b"a\nb\r\n"));assert!(!valid_text(&[0xc2,0x85]));
        assert!(!valid_text(&vec![b'a';65537]));
    }
    #[test]fn archive_attribute_contract_only_admits_the_documented_write_transition(){
        let v1=EditAttributeContract::ExactV1;
        let v2=EditAttributeContract::ArchiveWriteV2;
        assert!(!v1.permits_first_postwrite(0x80,0x20));
        for (before,after) in [(0x80,0x20),(0x02,0x22),(0x02,0x02),(0x20,0x20)]{
            assert!(v2.permits_first_postwrite(before,after));
        }
        for (before,after) in [(0x80,0xa0),(0x22,0x02),(0x02,0x20),(0,0x20),
            (0x01,0x02),(0x20,0)]{
            assert!(!v2.permits_first_postwrite(before,after));
        }
    }
}
