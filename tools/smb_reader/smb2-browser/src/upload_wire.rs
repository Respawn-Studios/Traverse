//! U1: one bounded parent-to-worker body frame and exact text commands.
use super::wire::{self,Issue};
pub const MAGIC:&str="MEXSMBU1";
pub const MAX_FRAME:usize=32768+77;

#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Selection {pub token:String,pub ordinal:u64,pub number:u64,pub generation:String,pub revision:i64,
    pub parent:Vec<u16>,pub name:Vec<u16>,pub stage:Vec<u16>,pub size:u64}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct FolderSelection {pub token:String,pub ordinal:u64,pub number:u64,pub generation:String,pub revision:i64,
    pub parent:Vec<u16>,pub name:Vec<u16>,pub stage:Vec<u16>,pub files:usize,pub folders:usize,
    pub size:u64,pub manifest_len:usize,pub manifest_digest:[u8;32]}
#[derive(Debug,PartialEq,Eq)]
pub enum Command {Prepare(Selection),Begin{token:String,ordinal:u64},Digest{token:String,ordinal:u64,digest:[u8;32]},
    Commit{token:String,ordinal:u64},Data{token:String,ordinal:u64,sequence:u64,offset:u64,bytes:Vec<u8>},
    PrepareFolder(FolderSelection),BeginFolder{token:String,ordinal:u64},FolderRootAck{token:String,ordinal:u64},
    FolderManifest{token:String,ordinal:u64,offset:u64,bytes:Vec<u8>},
    FolderData{token:String,ordinal:u64,node:u32,sequence:u64,offset:u64,bytes:Vec<u8>},
    FolderFileDigest{token:String,ordinal:u64,node:u32,digest:[u8;32]},
    FolderFileAck{token:String,ordinal:u64,node:u32,files:usize,bytes:u64},
    CommitFolder{token:String,ordinal:u64,digest:[u8;32]}}
fn digest(raw:&str)->Result<[u8;32],Issue>{
    if raw.len()!=64||!raw.bytes().all(|b|b.is_ascii_digit()||(b'a'..=b'f').contains(&b)){return Err(Issue::Invalid);}
    let mut out=[0;32];for(i,v)in out.iter_mut().enumerate(){*v=u8::from_str_radix(&raw[i*2..i*2+2],16).map_err(|_|Issue::Invalid)?;}Ok(out)
}
pub(crate) fn safe_upload_component(name:&[u16])->bool{
    let Ok(value)=String::from_utf16(name)else{return false};
    !name.is_empty()&&name.len()<=255&&name!=[46]&&name!=[46,46]&&!matches!(name.last(),Some(32|46))
        &&!name.iter().any(|unit|*unit<32||matches!(*unit,47|58|92|42|63|34|60|62|124))
        &&!value.chars().any(|ch|ch.is_control()||matches!(ch as u32,0x061c|0x200e|0x200f|0x202a..=0x202e|0x2066..=0x2069))
}
pub fn command(line:&str)->Result<Command,Issue>{
    let p=line.split(' ').collect::<Vec<_>>();match p.first().copied(){
        Some("PREPARE_UPLOAD")if p.len()==9&&wire::uuid(p[1])&&wire::uuid(p[4])=>{
            let ordinal=wire::number(p[2])?;let number=wire::number(p[3])?;let revision=wire::number(p[5])?;
            let parent=wire::path(p[6])?;let name=wire::component(p[7])?;let size=wire::number(p[8])?;
            if ordinal==0||number==0||revision<=0||size>1u64<<30||!safe_upload_component(&name)
                ||(!parent.is_empty()&&!parent.split(|unit|*unit==92).all(safe_upload_component)){return Err(Issue::Invalid);}
            let stage:Vec<u16>=format!(".traverse-smb-upload-{}.part",p[1].replace('-',"").to_ascii_lowercase()).encode_utf16().collect();
            let separator=usize::from(!parent.is_empty());
            if parent.len()>1920||parent.len()+separator+name.len()>2048||parent.len()+separator+stage.len()>2048
                ||String::from_utf16(&name).is_ok_and(|value|value.to_ascii_lowercase().starts_with(".traverse-smb-upload-")){
                return Err(Issue::Invalid);
            }
            Ok(Command::Prepare(Selection{token:p[1].into(),ordinal,number,generation:p[4].into(),revision,parent,name,stage,size}))
        },
        Some("BEGIN_UPLOAD"|"COMMIT_UPLOAD")if p.len()==3&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(if p[0]=="BEGIN_UPLOAD"{Command::Begin{token:p[1].into(),ordinal}}else{Command::Commit{token:p[1].into(),ordinal}})
        },
        Some("UPLOAD_DIGEST")if p.len()==4&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(Command::Digest{token:p[1].into(),ordinal,digest:digest(p[3])?})
        },
        Some("PREPARE_FOLDER_UPLOAD")if p.len()==13&&wire::uuid(p[1])&&wire::uuid(p[4])=>{
            let ordinal=wire::number(p[2])?;let number=wire::number(p[3])?;let revision=wire::number(p[5])?;
            let parent=wire::path(p[6])?;let name=wire::component(p[7])?;
            let files=wire::number::<usize>(p[8])?;let folders=wire::number::<usize>(p[9])?;
            let size=wire::number::<u64>(p[10])?;let manifest_len=wire::number::<usize>(p[11])?;
            if ordinal==0||number==0||revision<=0||files>1024||folders>2047||files+folders+1>2048
                ||size>1u64<<30||!(22..=512<<10).contains(&manifest_len)||!safe_upload_component(&name)
                ||(!parent.is_empty()&&!parent.split(|unit|*unit==92).all(safe_upload_component)){return Err(Issue::Invalid);}
            let stage:Vec<u16>=format!(".traverse-smb-upload-{}.part",p[1].replace('-',"").to_ascii_lowercase()).encode_utf16().collect();
            let separator=usize::from(!parent.is_empty());
            if parent.len()>1920||parent.len()+separator+name.len()>2048||parent.len()+separator+stage.len()>2048
                ||String::from_utf16(&name).is_ok_and(|value|value.to_ascii_lowercase().starts_with(".traverse-smb-upload-")){
                return Err(Issue::Invalid);
            }
            Ok(Command::PrepareFolder(FolderSelection{token:p[1].into(),ordinal,number,generation:p[4].into(),revision,
                parent,name,stage,files,folders,size,manifest_len,manifest_digest:digest(p[12])?}))
        },
        Some("BEGIN_FOLDER_UPLOAD"|"FOLDER_ROOT_ACK")if p.len()==3&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(if p[0]=="BEGIN_FOLDER_UPLOAD"{Command::BeginFolder{token:p[1].into(),ordinal}}
                else{Command::FolderRootAck{token:p[1].into(),ordinal}})
        },
        Some("FOLDER_FILE_DIGEST")if p.len()==5&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;let node=wire::number(p[3])?;
            if ordinal==0||node==0{return Err(Issue::Invalid);}
            Ok(Command::FolderFileDigest{token:p[1].into(),ordinal,node,digest:digest(p[4])?})
        },
        Some("FOLDER_FILE_ACK")if p.len()==6&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;let node=wire::number(p[3])?;
            let files=wire::number(p[4])?;let bytes=wire::number(p[5])?;
            if ordinal==0||node==0||files>1024||bytes>1u64<<30{return Err(Issue::Invalid);}
            Ok(Command::FolderFileAck{token:p[1].into(),ordinal,node,files,bytes})
        },
        Some("COMMIT_FOLDER_UPLOAD")if p.len()==4&&wire::uuid(p[1])=>{
            let ordinal=wire::number(p[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(Command::CommitFolder{token:p[1].into(),ordinal,digest:digest(p[3])?})
        },_=>Err(Issue::Invalid),
    }
}
pub fn binary(payload:&[u8])->Result<Command,Issue>{
    if payload.len()<74||payload.len()>MAX_FRAME||&payload[1..9]!=MAGIC.as_bytes(){return Err(Issue::Invalid);}
    let token=std::str::from_utf8(&payload[9..45]).map_err(|_|Issue::Invalid)?;
    if !wire::uuid(token){return Err(Issue::Invalid);}
    let ordinal=u64::from_be_bytes(payload[45..53].try_into().unwrap());
    if payload[0]==3||payload[0]==4{
        if payload.len()<78{return Err(Issue::Invalid);}
        let node=u32::from_be_bytes(payload[53..57].try_into().unwrap());
        let sequence=u64::from_be_bytes(payload[57..65].try_into().unwrap());
        let offset=u64::from_be_bytes(payload[65..73].try_into().unwrap());
        let count=u32::from_be_bytes(payload[73..77].try_into().unwrap()) as usize;
        if ordinal==0||count==0||count>32768||payload.len()!=77+count
            ||offset.checked_add(count as u64).is_none_or(|end|end>1u64<<30){return Err(Issue::Invalid);}
        return if payload[0]==3&&node==0&&sequence==0&&offset+count as u64<=512<<10{
            Ok(Command::FolderManifest{token:token.into(),ordinal,offset,bytes:payload[77..].to_vec()})
        }else if payload[0]==4&&node>0{
            Ok(Command::FolderData{token:token.into(),ordinal,node,sequence,offset,bytes:payload[77..].to_vec()})
        }else{Err(Issue::Invalid)};
    }
    if payload[0]!=2{return Err(Issue::Invalid);}
    let sequence=u64::from_be_bytes(payload[53..61].try_into().unwrap());
    let offset=u64::from_be_bytes(payload[61..69].try_into().unwrap());
    let count=u32::from_be_bytes(payload[69..73].try_into().unwrap()) as usize;
    if ordinal==0||count==0||count>32768||payload.len()!=73+count||offset.checked_add(count as u64).is_none_or(|end|end>1u64<<30){return Err(Issue::Invalid);}
    Ok(Command::Data{token:token.into(),ordinal,sequence,offset,bytes:payload[73..].to_vec()})
}
#[cfg(test)]mod tests{
    use super::*;
    const A:&str="77777777-7777-4777-8777-777777777777";const B:&str="88888888-8888-4888-8888-888888888888";
    #[test]fn parse_upload_without_implicit_path_or_overwrite(){
        let c=command(&format!("PREPARE_UPLOAD {A} 1 2 {B} 3 - 00660069006c0065 4")).unwrap();
        let Command::Prepare(s)=c else{panic!()};
        assert!(s.parent.is_empty());assert_eq!(s.stage,String::from(".traverse-smb-upload-77777777777747778777777777777777.part").encode_utf16().collect::<Vec<_>>());
        for bad in [format!("PREPARE_UPLOAD {A} 1 2 {B} 3 - 00660069006c0065 1073741825"),format!("PREPARE_UPLOAD {A} 1 2 {B} 3 002e002e 0066 4"),
            format!("PREPARE_UPLOAD {A} 1 2 {B} 3 - 0066 4 extra"),format!("UPLOAD_DIGEST {A} 1 {}","F".repeat(64))]{assert!(command(&bad).is_err());}
    }
    #[test]fn binary_data_is_exact_and_bounded(){
        let mut frame=vec![2];frame.extend(MAGIC.as_bytes());frame.extend(A.as_bytes());frame.extend(1u64.to_be_bytes());frame.extend(0u64.to_be_bytes());frame.extend(0u64.to_be_bytes());frame.extend(1u32.to_be_bytes());frame.push(42);
        assert!(matches!(binary(&frame),Ok(Command::Data{bytes,..})if bytes==[42]));
        frame[69..73].copy_from_slice(&2u32.to_be_bytes());assert!(binary(&frame).is_err());
    }
    #[test]fn upload_preflight_rejects_impossible_paths_and_reserved_targets(){
        let hex=|name:&str|name.encode_utf16().map(|unit|format!("{unit:04x}")).collect::<String>();
        let one=hex(&"a".repeat(255));let tail=hex(&"b".repeat(110));
        let parent=std::iter::repeat_n(one.as_str(),7).chain(std::iter::once(tail.as_str())).collect::<Vec<_>>().join(",");
        let reserved=hex(".traverse-smb-upload-impostor");
        for (path,name) in [(parent.as_str(),one.as_str()),("-",reserved.as_str())]{
            assert!(command(&format!("PREPARE_UPLOAD {A} 1 2 {B} 3 {path} {name} 4")).is_err());
        }
        let bad_name_dot=hex("bad.");let bad_parent_dot=hex("parent.");let safe_name=hex("safe.bin");
        let bad_name_colon=hex("bad:name");let bad_name_bidi=hex("bad\u{202e}name");
        for (path,name) in [("-",bad_name_dot.as_str()),(bad_parent_dot.as_str(),safe_name.as_str()),
            ("-",bad_name_colon.as_str()),("-",bad_name_bidi.as_str())]{
            assert!(command(&format!("PREPARE_UPLOAD {A} 1 2 {B} 3 {path} {name} 4")).is_err());
        }
        assert!(command(&format!("PREPARE_UPLOAD {A} 1 2 {B} 3 - {} 4",hex("safe.bin"))).is_ok());
    }
    #[test]fn upload_authority_requires_its_own_encrypted_mode(){
        let hello=format!("MEXSMBU1 START {A} encrypted 127.0.0.1 445 0 3132372e302e302e31 005300680061007200650064 2f612f636174616c6f672e73716c697465 67108864");
        assert!(wire::hello_policy(&hello,wire::Mode::Upload).is_ok());
        assert!(matches!(wire::hello_policy(&hello.replace("encrypted","signed"),wire::Mode::Upload),Err(Issue::Security)));
        let prepare=format!("PREPARE_UPLOAD {A} 1 2 {B} 3 - 0066 4");
        assert!(wire::command_policy(&prepare,wire::Mode::Upload).is_ok());
        for mode in [wire::Mode::Metadata,wire::Mode::File,wire::Mode::Folder]{
            assert!(wire::command_policy(&prepare,mode).is_err());
        }
    }
    #[test]fn folder_upload_commands_and_binary_frames_are_exact_and_bounded(){
        let name="Tree".encode_utf16().map(|unit|format!("{unit:04x}")).collect::<String>();
        let prepare=format!("PREPARE_FOLDER_UPLOAD {A} 1 2 {B} 3 - {name} 1 0 3 49 {}","00".repeat(32));
        assert!(matches!(command(&prepare),Ok(Command::PrepareFolder(s))if s.files==1&&s.folders==0&&s.size==3&&s.manifest_len==49));
        assert!(command(&prepare.replace(" 49 "," 524289 ")).is_err());
        assert!(command(&prepare.replace(" 1 0 3 "," 1025 0 3 ")).is_err());
        assert!(command(&format!("FOLDER_FILE_DIGEST {A} 1 1 {}","ab".repeat(32))).is_ok());
        assert!(command(&format!("FOLDER_FILE_ACK {A} 1 1 1 3")).is_ok());
        assert!(command(&format!("COMMIT_FOLDER_UPLOAD {A} 1 {}","ab".repeat(32))).is_ok());
        let mut body=vec![3];body.extend(MAGIC.as_bytes());body.extend(A.as_bytes());
        body.extend(1u64.to_be_bytes());body.extend(0u32.to_be_bytes());body.extend(0u64.to_be_bytes());
        body.extend(0u64.to_be_bytes());body.extend(1u32.to_be_bytes());body.push(42);
        assert!(matches!(binary(&body),Ok(Command::FolderManifest{offset:0,bytes,..})if bytes==[42]));
        body[0]=4;body[53..57].copy_from_slice(&1u32.to_be_bytes());
        assert!(matches!(binary(&body),Ok(Command::FolderData{node:1,offset:0,bytes,..})if bytes==[42]));
        body[73..77].copy_from_slice(&2u32.to_be_bytes());assert!(binary(&body).is_err());
    }
}
