//! Two-phase selected-file action. BEGIN is sent only after a durable intent.
use super::wire::{self,Issue};
#[derive(Clone,Debug,PartialEq,Eq)]
pub enum Kind{Rename(Vec<u16>),Delete,RenameDirectory(Vec<u16>),DeleteEmptyDirectory,
    Move(Vec<u16>),MoveDirectory(Vec<u16>),Copy{parent:Vec<u16>,name:Vec<u16>}}
impl Kind{
    pub fn is_directory(&self)->bool{matches!(self,Self::RenameDirectory(_)|Self::DeleteEmptyDirectory|Self::MoveDirectory(_))}
    pub fn destination_parent(&self)->Option<&[u16]>{match self{
        Self::Move(parent)|Self::MoveDirectory(parent)|Self::Copy{parent,..}=>Some(parent),_=>None}}
    pub fn is_copy(&self)->bool{matches!(self,Self::Copy{..})}
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Selection{
    pub token:String,pub ordinal:u64,pub number:u64,pub generation:String,
    pub revision:i64,pub observation:i64,pub kind:Kind,
}
#[derive(Debug,PartialEq,Eq)]
pub enum Command{Prepare(Selection),Begin{token:String,ordinal:u64}}
pub fn case_only_rename(kind:&Kind,source:&[u16])->bool{
    fn fold(unit:u16)->u16{if (65..=90).contains(&unit){unit+32}else{unit}}
    match kind{
        Kind::Rename(target)|Kind::RenameDirectory(target)=>target!=source&&target.len()==source.len()
            &&target.iter().zip(source).all(|(a,b)|fold(*a)==fold(*b)),
        Kind::Delete|Kind::DeleteEmptyDirectory|Kind::Move(_)|Kind::MoveDirectory(_)|Kind::Copy{..}=>false,
    }
}
fn move_parent(value:&str)->Result<Vec<u16>,Issue>{
    let parent=wire::path(value)?;
    if parent.len()>1792||(!parent.is_empty()&&parent.split(|unit|*unit==92).count()>32){return Err(Issue::Invalid);}
    Ok(parent)
}
pub fn command(line:&str)->Result<Command,Issue>{
    let f=line.split(' ').collect::<Vec<_>>();
    match f.first().copied(){
        Some("PREPARE_ACTION")if f.len()==9&&wire::uuid(f[1])&&wire::uuid(f[4])=>{
            let ordinal=wire::number(f[2])?;let number=wire::number(f[3])?;
            let revision=wire::number(f[5])?;let observation=wire::number(f[6])?;
            if ordinal==0||number==0||revision<0||observation<=0{return Err(Issue::Invalid);}
            let kind=match(f[7],f[8]){
                ("delete","-")=>Kind::Delete,
                ("rename",value)=>Kind::Rename(wire::component(value)?),
                ("deleteEmptyDirectory","-")=>Kind::DeleteEmptyDirectory,
                ("renameDirectory",value)=>Kind::RenameDirectory(wire::component(value)?),
                ("move",value)=>Kind::Move(move_parent(value)?),
                ("moveDirectory",value)=>Kind::MoveDirectory(move_parent(value)?),
                ("copy",value)=>{
                    let(parent,name)=value.split_once(';').ok_or(Issue::Invalid)?;
                    if name.contains(';'){return Err(Issue::Invalid);}
                    Kind::Copy{parent:move_parent(parent)?,name:wire::component(name)?}
                },
                _=>return Err(Issue::Invalid),
            };
            Ok(Command::Prepare(Selection{token:f[1].into(),ordinal,number,generation:f[4].into(),revision,observation,kind}))
        },
        Some("BEGIN_ACTION")if f.len()==3&&wire::uuid(f[1])=>{
            let ordinal=wire::number(f[2])?;if ordinal==0{return Err(Issue::Invalid);}
            Ok(Command::Begin{token:f[1].into(),ordinal})
        },_=>Err(Issue::Invalid),
    }
}
#[cfg(test)]mod tests{
    use super::*;
    const A:&str="77777777-7777-4777-8777-777777777777";
    const B:&str="88888888-8888-4888-8888-888888888888";
    #[test]fn only_exact_typed_action_commands(){
        assert!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 delete -")).is_ok());
        assert!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 rename 0041")).is_ok());
        assert!(matches!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 deleteEmptyDirectory -")),Ok(Command::Prepare(Selection{kind:Kind::DeleteEmptyDirectory,..}))));
        assert!(matches!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 renameDirectory 0041")),Ok(Command::Prepare(Selection{kind:Kind::RenameDirectory(_),..}))));
        assert!(matches!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 move -")),Ok(Command::Prepare(Selection{kind:Kind::Move(path),..}))if path.is_empty()));
        assert!(matches!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 moveDirectory 0041,0042")),Ok(Command::Prepare(Selection{kind:Kind::MoveDirectory(path),..}))if path=="A\\B".encode_utf16().collect::<Vec<_>>()));
        assert!(matches!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 copy -;0042")),
            Ok(Command::Prepare(Selection{kind:Kind::Copy{parent,name},..}))if parent.is_empty()&&name==vec![66]));
        assert!(matches!(command(&format!("PREPARE_ACTION {A} 1 2 {B} 4 9 copy 0041,0042;0043")),
            Ok(Command::Prepare(Selection{kind:Kind::Copy{parent,name},..}))if parent=="A\\B".encode_utf16().collect::<Vec<_>>()&&name==vec![67]));
        for bad in[
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 delete 0041"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 rename -"),
            format!("PREPARE_ACTION {A} 01 2 {B} 4 9 delete -"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 rename 002e002e"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 delete - extra"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 deleteEmptyDirectory 0041"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 renameDirectory -"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 deleteTree -"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 move 002e002e"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 move 0041,,0042"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 copy -"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 copy -;"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 copy -;0041;0042"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 copy 002e002e;0041"),
            format!("PREPARE_ACTION {A} 1 2 {B} 4 9 move {}","0041,".repeat(32)+"0041"),
            format!("BEGIN_ACTION {A} 0"),
        ]{assert!(command(&bad).is_err(),"{bad}");}
        assert!(case_only_rename(&Kind::Rename("source.txt".encode_utf16().collect()),
            &"Source.txt".encode_utf16().collect::<Vec<_>>()));
        assert!(case_only_rename(&Kind::RenameDirectory("source".encode_utf16().collect()),
            &"Source".encode_utf16().collect::<Vec<_>>()));
        assert!(!case_only_rename(&Kind::Rename("Source.txt".encode_utf16().collect()),
            &"Source.txt".encode_utf16().collect::<Vec<_>>()));
        assert!(!case_only_rename(&Kind::Rename("Å.txt".encode_utf16().collect()),
            &"å.txt".encode_utf16().collect::<Vec<_>>()));
    }
}
