//! Private bounded browser protocol. Never format input/credentials in errors.
use std::net::{IpAddr,SocketAddr,SocketAddrV6};
use super::catalog::Sort;

#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Issue {Invalid,IPC,Stop,Deadline,Remote,Authentication,Denied,Security,Storage,Quota,Close,ActionRefused}
impl Issue {pub fn name(self)->&'static str{match self{
    Self::Invalid=>"invalid",Self::IPC=>"ipc",Self::Stop=>"stopped",Self::Deadline=>"deadline",Self::Remote=>"remote",
    Self::Authentication=>"authentication",Self::Denied=>"denied",Self::Security=>"security",Self::Storage=>"storage",Self::Quota=>"quota",Self::Close=>"close",Self::ActionRefused=>"actionRefused"}}}
pub fn number<T:std::str::FromStr+ToString>(s:&str)->Result<T,Issue>{let n:T=s.parse().map_err(|_|Issue::Invalid)?;if n.to_string()==s{Ok(n)}else{Err(Issue::Invalid)}}
pub fn uuid(s:&str)->bool{s.len()==36&&s!="00000000-0000-0000-0000-000000000000"&&s.bytes().enumerate().all(|(i,c)|
    if [8,13,18,23].contains(&i){c==b'-'}else{c.is_ascii_digit()||(b'A'..=b'F').contains(&c)})}
pub fn generation(s:&str)->Result<[u8;16],Issue>{
    if !uuid(s){return Err(Issue::Invalid);}let raw=s.replace('-',"");let mut value=[0;16];
    for(i,n)in value.iter_mut().enumerate(){*n=u8::from_str_radix(&raw[i*2..i*2+2],16).map_err(|_|Issue::Invalid)?;}Ok(value)
}
fn bytes(s:&str,cap:usize,empty:bool)->Result<Vec<u8>,Issue>{
    if s=="-"&&empty{return Ok(vec![]);}
    if s.is_empty()||s.len()%2!=0||s.len()>cap*2||!s.bytes().all(|c|c.is_ascii_digit()||(b'a'..=b'f').contains(&c)){return Err(Issue::Invalid);}
    (0..s.len()).step_by(2).map(|i|u8::from_str_radix(&s[i..i+2],16).map_err(|_|Issue::Invalid)).collect()
}
pub fn text(s:&str,cap:usize,empty:bool)->Result<String,Issue>{
    let value=String::from_utf8(bytes(s,cap,empty)?).map_err(|_|Issue::Invalid)?;
    if value.chars().any(char::is_control){return Err(Issue::Invalid);}Ok(value)
}
pub fn component(s:&str)->Result<Vec<u16>,Issue>{
    let raw=bytes(s,4096,false)?;if raw.len()%2!=0{return Err(Issue::Invalid);}
    let wire:Vec<_>=raw.chunks_exact(2).map(|n|u16::from_be_bytes([n[0],n[1]])).collect();
    let name=String::from_utf16(&wire).map_err(|_|Issue::Invalid)?;
    if !super::common::permitted_name(&name){return Err(Issue::Invalid);}Ok(wire)
}
pub fn path(s:&str)->Result<Vec<u16>,Issue>{
    if s=="-"{return Ok(vec![]);}if s.len()>16384{return Err(Issue::Invalid);}
    let parts=s.split(',').collect::<Vec<_>>();if parts.len()>128{return Err(Issue::Invalid);}
    let mut result=vec![];
    for part in parts{if !result.is_empty(){result.push(b'\\' as u16);}result.extend(component(part)?);if result.len()>4096{return Err(Issue::Invalid);}}
    Ok(result)
}
pub struct Hello {pub session:String,pub encrypted:bool,pub destination:SocketAddr,pub host:String,pub share:String,pub store:String,pub quota:u64}
fn hostname(value:&str)->bool{
    if value.parse::<IpAddr>().is_ok(){return true;}
    !value.is_empty()&&value.len()<=253&&value.split('.').all(|part|!part.is_empty()&&part.len()<=63&&
        !part.starts_with('-')&&!part.ends_with('-')&&part.bytes().all(|c|c.is_ascii_alphanumeric()||c==b'-'))
}
pub fn hello(line:&str)->Result<Hello,Issue>{
    let f=line.split(' ').collect::<Vec<_>>();
    if f.len()!=11||f[0]!="MEXSMBB2"||f[1]!="START"||!uuid(f[2])||!["encrypted","signed"].contains(&f[3]){return Err(Issue::Invalid);}
    let ip:IpAddr=f[4].parse().map_err(|_|Issue::Invalid)?;if ip.to_string()!=f[4]||ip.is_unspecified()||ip.is_multicast(){return Err(Issue::Invalid);}
    let port=number::<u16>(f[5])?;let scope=number::<u32>(f[6])?;if port==0||scope>=0xfffffff0{return Err(Issue::Invalid);}
    let destination=match ip{
        IpAddr::V4(v)=>{if scope!=0||v.octets()[0]==0||v.octets()[0]>=224{return Err(Issue::Invalid);}SocketAddr::from((v,port))},
        IpAddr::V6(v)=>{if v.is_unicast_link_local()&&scope==0{return Err(Issue::Invalid);}SocketAddr::V6(SocketAddrV6::new(v,port,0,scope))},
    };
    let host=text(f[7],253,false)?;if !hostname(&host){return Err(Issue::Invalid);}
    if let Ok(literal)=host.parse::<IpAddr>(){if literal!=ip{return Err(Issue::Invalid);}}
    let share=String::from_utf16(&component(f[8])?).map_err(|_|Issue::Invalid)?;if share.len()>256{return Err(Issue::Invalid);}
    let store=text(f[9],4096,false)?;let path=std::path::Path::new(&store);
    if !path.is_absolute()||!store.ends_with("/catalog.sqlite")||store.contains("//")||store.contains("/./")||path.components().any(|p|matches!(p,std::path::Component::ParentDir|std::path::Component::CurDir)){return Err(Issue::Invalid);}
    let quota=number::<u64>(f[10])?;if !(1<<20..=512<<20).contains(&quota){return Err(Issue::Invalid);}
    Ok(Hello{session:f[2].into(),encrypted:f[3]=="encrypted",destination,host,share,store,quota})
}
pub struct Credentials{pub account:String,pub password:String,pub domain:String}
pub fn credentials(line:&str)->Result<Credentials,Issue>{
    let f=line.split(' ').collect::<Vec<_>>();if f.len()!=4||f[0]!="CREDENTIALS"{return Err(Issue::Invalid);}
    let account=text(f[1],256,false)?;if account.eq_ignore_ascii_case("guest")||account.eq_ignore_ascii_case("anonymous"){return Err(Issue::Invalid);}
    let password=String::from_utf8(bytes(f[2],4096,false)?).map_err(|_|Issue::Invalid)?;
    if password.contains('\0'){return Err(Issue::Invalid);}
    Ok(Credentials{account,password,domain:text(f[3],256,true)?})
}
#[derive(Debug)]
pub struct Page{pub token:String,pub number:u64,pub generation:String,pub revision:i64,pub offset:i64,pub sort:Sort,pub descending:bool,pub find:Option<String>}
pub struct Find{pub token:String,pub number:u64,pub generation:String,pub revision:i64,pub count:i64,pub folders:i64,pub state:u8,pub query:String}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct FolderSizeSelection{pub request:String,pub number:u64,pub generation:String,pub revision:i64,pub count:i64,pub folders:i64,pub state:u8,pub observation:i64}
pub enum Command{Read{number:u64,generation:String,path:Vec<u16>},Cancel(u64),Page(Page),Find(Find),SizeFolder(FolderSizeSelection),Download(super::download_wire::Command),Folder(super::folder_wire::Command),Upload(super::upload_wire::Command),Edit(super::edit_wire::Command),Action(super::action_wire::Command)}
pub fn command(line:&str)->Result<Command,Issue>{
    let f=line.split(' ').collect::<Vec<_>>();match f.first().copied(){
        Some("READ") if f.len()==4&&uuid(f[2])=>{let number=number::<u64>(f[1])?;if number==0{return Err(Issue::Invalid);}Ok(Command::Read{number,generation:f[2].into(),path:path(f[3])?})},
        Some("CANCEL") if f.len()==2=>Ok(Command::Cancel(number(f[1])?)),
        Some("PAGE") if (f.len()==8||f.len()==9)&&uuid(f[1])&&uuid(f[3])=>{
            let read_number=number(f[2])?;let revision=number::<i64>(f[4])?;let offset=number::<i64>(f[5])?;if revision<0||offset<0{return Err(Issue::Invalid);}
            let sort=match f[6]{"name"=>Sort::Name,"size"=>Sort::Size,"modified"=>Sort::Modified,_=>return Err(Issue::Invalid)};
            let descending=match f[7]{"0"=>false,"1"=>true,_=>return Err(Issue::Invalid)};
            let find=if f.len()==9{if !uuid(f[8]){return Err(Issue::Invalid)}Some(f[8].into())}else{None};
            Ok(Command::Page(Page{token:f[1].into(),number:read_number,generation:f[3].into(),revision,offset,sort,descending,find}))
        },
        Some("FIND") if f.len()==9&&uuid(f[1])&&uuid(f[3])=>{
            let read_number=number::<u64>(f[2])?;let revision=number::<i64>(f[4])?;
            let count=number::<i64>(f[5])?;let folders=number::<i64>(f[6])?;
            let state=number::<u8>(f[7])?;let query=String::from_utf8(bytes(f[8],2048,false)?).map_err(|_|Issue::Invalid)?;
            if read_number==0||revision<0||count<0||folders<0||folders>count||state>3||query.contains('\0'){return Err(Issue::Invalid)}
            Ok(Command::Find(Find{token:f[1].into(),number:read_number,generation:f[3].into(),revision,count,folders,state,query}))
        },
        Some("SIZE_FOLDER") if f.len()==9&&uuid(f[1])&&uuid(f[3])=>{
            let read_number=number::<u64>(f[2])?;let revision=number::<i64>(f[4])?;
            let count=number::<i64>(f[5])?;let folders=number::<i64>(f[6])?;
            let state=number::<u8>(f[7])?;let observation=number::<i64>(f[8])?;
            if read_number==0||revision<=0||count<0||folders<0||folders>count||state!=1||observation<=0{return Err(Issue::Invalid)}
            Ok(Command::SizeFolder(FolderSizeSelection{request:f[1].into(),number:read_number,generation:f[3].into(),revision,count,folders,state,observation}))
        },_=>Err(Issue::Invalid),
    }
}

#[cfg(test)] mod tests{
    use super::*;
    #[test]fn paths_preserve_spelling_and_refuse_escape(){
        assert_eq!(path("0046006f006c006400650072").unwrap(),"Folder".encode_utf16().collect::<Vec<_>>());
        assert_eq!(String::from_utf16(&path("0041,0042").unwrap()).unwrap(),"A\\B");
        for bad in ["","002e","002e002e","0041002f0042","0041005c0042","d800",",0041","0041,","004"]{assert!(path(bad).is_err());}
        assert_ne!(component("00430061006600e9").unwrap(),component("00430061006600650301").unwrap());
    }
    #[test]fn numeric_destination_is_frozen_and_scoped(){
        let h="MEXSMBB2 START 77777777-7777-4777-8777-777777777777 encrypted 127.0.0.1 445 0 73747564696f2e696e76616c6964 005300680061007200650064 2f612f636174616c6f672e73716c697465 67108864";
        assert!(hello(h).is_ok());
        assert!(hello(&h.replace("MEXSMBB2","MEXSMBB1")).is_err());
        for bad in [h.replace("127.0.0.1","server.invalid"),h.replace("127.0.0.1","0.0.0.0"),h.replace("445 0","445 1"),h.replace("encrypted","guest"),h.replace("67108864","536870913")]{assert!(hello(&bad).is_err());}
        let v=h.replace("127.0.0.1 445 0","fe80::1 445 7");assert_eq!(hello(&v).unwrap().destination.to_string(),"[fe80::1%7]:445");
        assert!(hello(&v.replace("445 7","445 0")).is_err());
    }
    #[test]fn credentials_and_commands_are_strict_and_bounded(){
        assert!(credentials("CREDENTIALS 67656e657261746564 70617373776f7264 -").is_ok());
        for bad in ["CREDENTIALS 6775657374 61 -","CREDENTIALS 61 00 -","CREDENTIALS 61 61 0a","CREDENTIALS 61 61 - extra"]{assert!(credentials(bad).is_err());}
        assert!(command("READ 65 77777777-7777-4777-8777-777777777777 -").is_ok());
        assert!(command("READ 065 77777777-7777-4777-8777-777777777777 -").is_err());
        assert!(command("PAGE 77777777-7777-4777-8777-777777777777 1 77777777-7777-4777-8777-777777777777 0 -1 name 0").is_err());
        let id="77777777-7777-4777-8777-777777777777";
        let page=format!("PAGE {id} 1 {id} 2 512 name 0 {id}");
        let Command::Page(filtered)=command(&page).unwrap()else{panic!("filtered PAGE")};
        assert_eq!(filtered.find.as_deref(),Some(id));
        let find=format!("FIND {id} 1 {id} 2 768 1 1 255f2773");
        let Command::Find(found)=command(&find).unwrap()else{panic!("FIND")};
        assert_eq!((found.query.as_str(),found.count,found.folders,found.state),("%_'s",768,1,1));
        assert!(command(&find.replace("255f2773","25_5f2773")).is_err());
        assert!(command(&find.replace("768 1 1","1 768 1")).is_err());
    }
    #[test]fn size_folder_uses_directory_metadata_in_each_existing_mode(){
        let request="77777777-7777-4777-8777-777777777777";
        let read="88888888-8888-4888-8888-888888888888";
        let line=format!("SIZE_FOLDER {request} 1 {read} 7 768 3 1 99");
        for mode in [Mode::Metadata,Mode::File,Mode::Folder,Mode::Upload]{
            assert!(matches!(command_policy(&line,mode),Ok(Command::SizeFolder(FolderSizeSelection{number:1,revision:7,count:768,folders:3,state:1,observation:99,..}))));
        }
        for bad in [line.replace(" 768 3 1 "," 3 768 1 "),line.replace(" 3 1 99"," 3 2 99"),
            line.replace(" 7 768"," 0 768"),line.replace(" 1 99"," 1 0"),format!("{line} extra")]{
            assert!(command_policy(&bad,Mode::Metadata).is_err());
        }
        assert!(command_policy(&format!("PREPARE_FOLDER {request} 1 1 {read} 7 99"),Mode::Metadata).is_err());
    }
}

pub fn hello_mode(line:&str,download:bool)->Result<Hello,Issue>{
    if !download{return hello(line);}
    let rest=line.strip_prefix("MEXSMBD1 START ").ok_or(Issue::Invalid)?;
    hello(&("MEXSMBB2 START ".to_owned()+rest))
}
pub fn command_mode(line:&str,download:bool)->Result<Command,Issue>{
    if line.starts_with("PREPARE_DOWNLOAD ")||line.starts_with("BEGIN_DOWNLOAD ")||line.starts_with("ACK_DOWNLOAD ")||line.starts_with("RELEASE_DOWNLOAD "){
        if !download{return Err(Issue::Invalid);}return super::download_wire::command(line).map(Command::Download);
    }
    command(line)
}

#[derive(Clone,Copy,PartialEq,Eq)]pub enum Mode{Metadata,File,Folder,Upload}
impl Mode{
    pub fn magic(self)->&'static str{match self{Self::Metadata=>"MEXSMBB2",Self::File=>"MEXSMBD1",Self::Folder=>"MEXSMBF1",Self::Upload=>"MEXSMBU1"}}
    pub fn framed(self)->bool{self!=Self::Metadata}
    pub fn allows_folder(self)->bool{matches!(self,Self::Folder|Self::Upload)}
}
pub fn hello_policy(line:&str,mode:Mode)->Result<Hello,Issue>{
    let prefix=format!("{} START ",mode.magic());let rest=line.strip_prefix(&prefix).ok_or(Issue::Invalid)?;
    let parsed=hello(&("MEXSMBB2 START ".to_owned()+rest))?;
    if mode==Mode::Upload&&!parsed.encrypted{return Err(Issue::Security);}Ok(parsed)
}
pub fn command_policy(line:&str,mode:Mode)->Result<Command,Issue>{
    if line.starts_with("PREPARE_EDIT ")||line.starts_with("PREPARE_EDIT_V2 ")
        ||line.starts_with("PREPARE_EDIT_V3 ")||line.starts_with("PREPARE_EDIT_SOURCE ")
        ||line.starts_with("PREPARE_EDIT_SOURCE_V2 ")||line.starts_with("PREPARE_EDIT_SOURCE_V3 ")
        ||line.starts_with("AUTHORIZE_EDIT "){
        if mode!=Mode::Upload{return Err(Issue::Invalid);}
        return super::edit_wire::command(line).map(Command::Edit);
    }
    if line.starts_with("PREPARE_ACTION ")||line.starts_with("BEGIN_ACTION "){
        if mode!=Mode::Upload{return Err(Issue::Invalid);}
        return super::action_wire::command(line).map(Command::Action);
    }
    if ["PREPARE_UPLOAD ","BEGIN_UPLOAD ","UPLOAD_DIGEST ","COMMIT_UPLOAD ",
        "PREPARE_FOLDER_UPLOAD ","BEGIN_FOLDER_UPLOAD ","FOLDER_ROOT_ACK ",
        "FOLDER_FILE_DIGEST ","FOLDER_FILE_ACK ","COMMIT_FOLDER_UPLOAD "]
        .iter().any(|prefix|line.starts_with(prefix)){
        if mode!=Mode::Upload{return Err(Issue::Invalid);}return super::upload_wire::command(line).map(Command::Upload);
    }
    if line.starts_with("PREPARE_FOLDER ")||line.starts_with("BEGIN_FOLDER ")||line.starts_with("ACK_FOLDER ")||line.starts_with("RELEASE_FOLDER "){
        if !mode.allows_folder(){return Err(Issue::Invalid);}return super::folder_wire::command(line).map(Command::Folder);
    }
    if line.starts_with("PREPARE_EDIT_OPEN ")||line.starts_with("RELEASE_EDIT_SOURCE "){
        if mode!=Mode::Upload{return Err(Issue::Invalid);}
        return super::download_wire::command(line).map(Command::Download);
    }
    command_mode(line,mode.framed())
}
#[cfg(test)]mod folder_modes{
    use super::*;
    #[test]fn exact_modes_do_not_inherit_authority(){let p=" START 77777777-7777-4777-8777-777777777777 encrypted 127.0.0.1 445 0 73747564696f2e696e76616c6964 005300680061007200650064 2f612f636174616c6f672e73716c697465 67108864";
        for mode in[Mode::Metadata,Mode::File,Mode::Folder]{for magic in["MEXSMBB2","MEXSMBD1","MEXSMBF1","INVALID"]{assert_eq!(hello_policy(&(magic.to_owned()+p),mode).is_ok(),magic==mode.magic());}}
        let cmd="PREPARE_FOLDER 77777777-7777-4777-8777-777777777777 1 1 88888888-8888-4888-8888-888888888888 1 1";
        assert!(command_policy(cmd,Mode::Folder).is_ok());assert!(command_policy(cmd,Mode::File).is_err());assert!(command_policy(cmd,Mode::Metadata).is_err());
    }
}
