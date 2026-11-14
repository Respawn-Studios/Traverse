//! Private parent/worker protocol. Parse only after a bounded frame is read.
//! Errors never retain or format untrusted fields, paths or credentials.
use crate::ssh::{Action,Key,Peer};
use std::net::{IpAddr,SocketAddr,SocketAddrV6};
use zeroize::Zeroizing;
pub const MAGIC:&[u8;8]=b"MEXSFTP1";
pub const PAGED_MAGIC:&[u8;8]=b"MEXSFTP2";
#[derive(Clone,Copy,PartialEq,Eq)]pub enum Mode{Batches,Catalog,#[cfg(feature="download-qualification")]TransferCatalog,
    #[cfg(feature="upload-qualification")]UploadCatalog,KeyCatalog,
    #[cfg(feature="download-qualification")]KeyTransferCatalog,
    #[cfg(feature="upload-qualification")]KeyUploadCatalog,InteractiveCatalog,
    #[cfg(feature="download-qualification")]InteractiveTransferCatalog,
    #[cfg(feature="upload-qualification")]InteractiveUploadCatalog,JumpCatalog,RememberedJumpCatalog,
    #[cfg(feature="folder-download-qualification")]FolderCatalog,
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderUploadCatalog,
    #[cfg(feature="folder-download-qualification")]RoutedFolderCatalog,
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]ExclusiveUploadCatalog,
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FreshFolderUploadCatalog,
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]RoutedExclusiveUploadCatalog,
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]RoutedFreshFolderUploadCatalog,
    #[cfg(feature="original-edit-qualification")]OriginalEditCatalog,
    #[cfg(feature="original-edit-qualification")]RoutedOriginalEditCatalog,
    #[cfg(feature="inplace-edit-v1")]InPlaceEditCatalog,
    #[cfg(feature="inplace-edit-v1")]RoutedInPlaceEditCatalog,
    #[cfg(feature="remote-action-qualification")]RemoteActionCatalog,
    #[cfg(feature="remote-action-qualification")]RoutedRemoteActionCatalog,
    #[cfg(feature="agent-qualification")]AgentCatalog}
impl Mode{
    pub fn magic(self)->&'static[u8;8]{match self{Self::Batches=>MAGIC,Self::Catalog=>PAGED_MAGIC,
        #[cfg(feature="download-qualification")]Self::TransferCatalog=>b"MEXSFTP3",
        #[cfg(feature="upload-qualification")]Self::UploadCatalog=>b"MEXSFTP4",Self::KeyCatalog=>b"MEXSFTP5",
        #[cfg(feature="download-qualification")]Self::KeyTransferCatalog=>b"MEXSFTP6",
        #[cfg(feature="upload-qualification")]Self::KeyUploadCatalog=>b"MEXSFTP7",Self::InteractiveCatalog=>b"MEXSFTP8",
        #[cfg(feature="download-qualification")]Self::InteractiveTransferCatalog=>b"MEXSFTP9",
        #[cfg(feature="upload-qualification")]Self::InteractiveUploadCatalog=>b"MEXSFTPA",Self::JumpCatalog=>b"MEXSFTPB",
        Self::RememberedJumpCatalog=>b"MEXSFTPC",
        #[cfg(feature="folder-download-qualification")]Self::FolderCatalog=>b"MEXSFTPD",
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]Self::FolderUploadCatalog=>b"MEXSFTPE",
        #[cfg(feature="folder-download-qualification")]Self::RoutedFolderCatalog=>b"MEXSFTPF",
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]Self::ExclusiveUploadCatalog=>b"MEXSFTPG",
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]Self::FreshFolderUploadCatalog=>b"MEXSFTPH",
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]Self::RoutedExclusiveUploadCatalog=>b"MEXSFTPI",
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]Self::RoutedFreshFolderUploadCatalog=>b"MEXSFTPJ",
        #[cfg(feature="original-edit-qualification")]Self::OriginalEditCatalog=>b"MEXSFTPK",
        #[cfg(feature="original-edit-qualification")]Self::RoutedOriginalEditCatalog=>b"MEXSFTPL",
        #[cfg(feature="inplace-edit-v1")]Self::InPlaceEditCatalog=>b"MEXSFTPM",
        #[cfg(feature="inplace-edit-v1")]Self::RoutedInPlaceEditCatalog=>b"MEXSFTPN",
        #[cfg(feature="remote-action-qualification")]Self::RemoteActionCatalog=>b"MEXSFTPO",
        #[cfg(feature="remote-action-qualification")]Self::RoutedRemoteActionCatalog=>b"MEXSFTPP",
        #[cfg(feature="agent-qualification")]Self::AgentCatalog=>b"MEXSFTPQ"}}
    pub fn agent(self)->bool{
        #[cfg(feature="agent-qualification")]if self==Self::AgentCatalog{return true}false
    }
    pub fn actions(self)->bool{
        #[cfg(feature="remote-action-qualification")]if matches!(self,Self::RemoteActionCatalog|Self::RoutedRemoteActionCatalog){return true}false
    }
    pub fn inplace(self)->bool{
        #[cfg(feature="inplace-edit-v1")]if matches!(self,Self::InPlaceEditCatalog|Self::RoutedInPlaceEditCatalog){return true}false
    }
    pub fn original(self)->bool{
        #[cfg(feature="original-edit-qualification")]if matches!(self,Self::OriginalEditCatalog|Self::RoutedOriginalEditCatalog){return true}false
    }
    pub fn folders(self)->bool{
        #[cfg(feature="folder-download-qualification")]if matches!(self,Self::FolderCatalog|Self::RoutedFolderCatalog){return true}
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]if matches!(self,Self::FolderUploadCatalog|Self::ExclusiveUploadCatalog|Self::FreshFolderUploadCatalog|Self::RoutedExclusiveUploadCatalog|Self::RoutedFreshFolderUploadCatalog){return true}false
    }
    pub fn jump(self)->bool{
        #[cfg(feature="remote-action-qualification")]if self==Self::RoutedRemoteActionCatalog{return true}
        #[cfg(feature="inplace-edit-v1")]if self==Self::RoutedInPlaceEditCatalog{return true}
        #[cfg(feature="original-edit-qualification")]if self==Self::RoutedOriginalEditCatalog{return true}
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]if matches!(self,Self::RoutedExclusiveUploadCatalog|Self::RoutedFreshFolderUploadCatalog){return true}
        #[cfg(feature="folder-download-qualification")]if self==Self::RoutedFolderCatalog{return true}
        matches!(self,Self::JumpCatalog|Self::RememberedJumpCatalog)
    }
    /// The optional-prior-key/role-bound route contract, independent of whether
    /// a particular connection is actually saved. Legacy B stays connect-once.
    pub fn remembered_jump(self)->bool{
        #[cfg(feature="remote-action-qualification")]if self==Self::RoutedRemoteActionCatalog{return true}
        #[cfg(feature="inplace-edit-v1")]if self==Self::RoutedInPlaceEditCatalog{return true}
        #[cfg(feature="original-edit-qualification")]if self==Self::RoutedOriginalEditCatalog{return true}
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]if matches!(self,Self::RoutedExclusiveUploadCatalog|Self::RoutedFreshFolderUploadCatalog){return true}
        #[cfg(feature="folder-download-qualification")]if self==Self::RoutedFolderCatalog{return true}
        self==Self::RememberedJumpCatalog
    }
    pub fn catalog(self)->bool{self!=Self::Batches}
    pub fn interactive(self)->bool{if self.folders()||self.original()||self.inplace()||self.actions(){return true}match self{Self::InteractiveCatalog|Self::JumpCatalog|Self::RememberedJumpCatalog=>true,
        #[cfg(feature="download-qualification")]Self::InteractiveTransferCatalog=>true,
        #[cfg(feature="upload-qualification")]Self::InteractiveUploadCatalog=>true,_=>false}}
    pub fn key_auth(self)->bool{if self.interactive()||self.agent(){return true}match self{Self::KeyCatalog=>true,
        #[cfg(feature="download-qualification")]Self::KeyTransferCatalog=>true,
        #[cfg(feature="upload-qualification")]Self::KeyUploadCatalog=>true,_=>false}}
    pub fn uploads(self)->bool{
        // Only explicit exclusive-final modes mutate. Old staged-rename parents
        // cannot silently receive different publication/recovery semantics.
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]if matches!(self,Self::ExclusiveUploadCatalog|Self::FreshFolderUploadCatalog|Self::RoutedExclusiveUploadCatalog|Self::RoutedFreshFolderUploadCatalog){return true}false
    }
    pub fn folder_uploads(self)->bool{
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]if matches!(self,Self::FreshFolderUploadCatalog|Self::RoutedFreshFolderUploadCatalog){return true}false
    }
    pub fn transfers(self)->bool{
        if self.folders(){return true}
        #[cfg(feature="download-qualification")]if matches!(self,Self::TransferCatalog|Self::KeyTransferCatalog|Self::InteractiveTransferCatalog){return true}
        #[cfg(feature="upload-qualification")]if matches!(self,Self::UploadCatalog|Self::KeyUploadCatalog|Self::InteractiveUploadCatalog){return true}
        false
    }
}
pub const MAX_FRAME:usize=65536;
pub const HEADER:usize=33;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub enum Failure{Length,Header,Sequence,Field,Phase}
type Result<T>=std::result::Result<T,Failure>;
pub struct Store{pub path:String,pub quota:u64}
pub struct Jump{pub peer:Peer,pub nonce:[u8;16],pub previous:Option<Key>}
pub struct Start{pub session:[u8;16],pub peer:Peer,pub address:SocketAddr,pub previous:Option<Key>,pub store:Option<Store>,pub jump:Option<Jump>}
pub enum JumpAuthentication{
    Password{account:String,password:Zeroizing<String>},
    Key{account:String,key:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,expected:Option<Key>,interactive:bool},
    Interactive{account:String},
}
impl JumpAuthentication{pub fn command(self)->Command{match self{
    Self::Password{account,password}=>Command::Credentials{account,password},
    Self::Key{account,key,passphrase,expected,interactive}=>Command::KeyCredentials{account,key,passphrase,expected,interactive},
    Self::Interactive{account}=>Command::InteractiveStart{account},
}}}
pub struct Page{pub request:[u8;16],pub generation:[u8;16],pub revision:i64,pub offset:i64,pub limit:usize,pub sort:u8,pub descending:bool,pub find:Option<[u8;16]>}
pub struct Find{pub request:[u8;16],pub generation:[u8;16],pub read:i64,pub revision:i64,
    pub count:i64,pub folders:i64,pub state:u8,pub query:String}
#[cfg(feature="remote-action-qualification")]
pub struct RemoteAction{pub request:[u8;16],pub generation:[u8;16],pub read:i64,pub revision:i64,
    pub kind:u8,pub observation:i64,pub name:String,pub destination:Option<String>,
    pub destination_parent:Option<String>,pub size:u64,pub modified:u32,pub permissions:u32}
pub enum Command{
    #[cfg(feature="agent-qualification")]AgentList{socket:String},
    #[cfg(feature="agent-qualification")]AgentSelect{account:String,digest:[u8;32]},
    #[cfg(feature="remote-action-qualification")]ActionPrepare(RemoteAction),
    #[cfg(feature="remote-action-qualification")]ActionPermit{request:[u8;16]},
    #[cfg(feature="inplace-edit-v1")]BeginInPlace{request:[u8;16],generation:[u8;16],revision:i64,observation:i64},
    #[cfg(feature="inplace-edit-v1")]AcceptInPlace{request:[u8;16],digest:[u8;32]},
    #[cfg(feature="inplace-edit-v1")]SaveInPlace{request:[u8;16],token:[u8;16],revision:u64,generation:[u8;16],size:u64,digest:[u8;32]},
    #[cfg(feature="inplace-edit-v1")]InPlaceBytes{request:[u8;16],offset:u64,bytes:Zeroizing<Vec<u8>>},
    #[cfg(feature="inplace-edit-v1")]InPlacePermit{request:[u8;16],sequence:u8,kind:u8,offset:u64,count:u32,digest:[u8;32]},
    #[cfg(feature="inplace-edit-v1")]ReleaseInPlace{request:[u8;16],token:[u8;16],revision:u64},
    #[cfg(feature="original-edit-qualification")]BeginEdit{request:[u8;16],generation:[u8;16],revision:i64,observation:i64},
    #[cfg(feature="original-edit-qualification")]AcceptBaseline{request:[u8;16],digest:[u8;32]},
    #[cfg(feature="original-edit-qualification")]SaveOriginal{request:[u8;16],token:[u8;16],revision:u64,operation:[u8;16],generation:[u8;16],size:u64,digest:[u8;32]},
    #[cfg(feature="original-edit-qualification")]EditBytes{request:[u8;16],offset:u64,bytes:Zeroizing<Vec<u8>>},
    #[cfg(feature="original-edit-qualification")]EditPermit{request:[u8;16],edge:u8,requested:u8,acknowledged:u8,roles:[u8;32],digest:[u8;32]},
    #[cfg(feature="original-edit-qualification")]ReleaseBaselineV1{request:[u8;16],token:[u8;16],revision:u64},
    Start(Start),Approve{action:Action,key:Option<Key>},
    Find(Find),
    Credentials{account:String,password:Zeroizing<String>},
    KeyCredentials{account:String,key:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,expected:Option<Key>,interactive:bool},
    CertificateCredentials{account:String,key:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>,expected:Option<Key>,
        certificate:Zeroizing<Vec<u8>>,interactive:bool},
    InteractiveStart{account:String},InteractiveAnswers{round:u8,answers:Zeroizing<Vec<String>>},
    JumpApprove{nonce:[u8;16],action:Action,key:Option<Key>},
    JumpCredentials{nonce:[u8;16],authentication:JumpAuthentication},
    JumpAnswers{nonce:[u8;16],round:u8,answers:Zeroizing<Vec<String>>},
    Directory{generation:[u8;16],path:String},Next([u8;16]),Page(Page),Stop,DirectoryRecovery,
    #[cfg(feature="download-qualification")]Download{request:[u8;16],generation:[u8;16],observation:i64},
    #[cfg(feature="folder-download-qualification")]PrepareFolder{request:[u8;16],generation:[u8;16],read:i64,revision:i64,observation:i64},
    #[cfg(feature="folder-download-qualification")]ReceiveFolder{request:[u8;16]},
    #[cfg(feature="folder-download-qualification")]ReleaseFolder{request:[u8;16]},
    #[cfg(feature="folder-download-qualification")]SummarizeFolder{request:[u8;16],generation:[u8;16],read:i64,revision:i64,count:i64,folders:i64,state:u8,observation:i64},
    #[cfg(feature="upload-qualification")]Upload{request:[u8;16],generation:[u8;16],revision:i64,name:String,size:u64},
    #[cfg(feature="upload-qualification")]SourceBytes{request:[u8;16],offset:u64,bytes:Zeroizing<Vec<u8>>},
    #[cfg(feature="upload-qualification")]PublicationPermit{request:[u8;16],digest:[u8;32]},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderUpload{request:[u8;16],generation:[u8;16],revision:i64,name:String,length:u32,digest:[u8;32],files:u32,folders:u32,bytes:u64},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderManifestBytes{request:[u8;16],offset:u32,bytes:Zeroizing<Vec<u8>>},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderSourceBytes{request:[u8;16],node:u32,offset:u64,bytes:Zeroizing<Vec<u8>>},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderFilePermit{request:[u8;16],node:u32,digest:[u8;32]},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderRootAcknowledged{request:[u8;16]},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderProgressAcknowledged{request:[u8;16],node:u32,files:u32,bytes:u64},
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]FolderFinalPermit{request:[u8;16],digest:[u8;32]},
}
pub struct Decoder{session:Option<[u8;16]>,next:u64,valid:bool,mode:Mode,original_enabled:bool,inplace_enabled:bool,inplace_transfers:u8,
    #[cfg(feature="agent-qualification")]agent_listed:bool,#[cfg(feature="agent-qualification")]agent_selected:bool}
impl Default for Decoder{fn default()->Self{Self::new(Mode::Batches)}}
impl Decoder{
    pub fn new(mode:Mode)->Self{Self{session:None,next:0,valid:true,mode,original_enabled:false,inplace_enabled:false,inplace_transfers:0,
        #[cfg(feature="agent-qualification")]agent_listed:false,#[cfg(feature="agent-qualification")]agent_selected:false}}
    /// Captured once from the exact combined startup. The actual worker must
    /// enforce the SAME mask independently of parser acceptance.
    pub fn transfer_capabilities(&self)->u8{self.inplace_transfers}
    pub fn inplace_enabled(&self)->bool{self.inplace_enabled}
    fn allows_downloads(&self)->bool{self.mode.transfers()||(self.mode.inplace()||self.mode.actions())&&self.inplace_transfers&1!=0}
    fn allows_folders(&self)->bool{self.mode.folders()||(self.mode.inplace()||self.mode.actions())&&self.inplace_transfers&2!=0}
    fn allows_uploads(&self)->bool{self.mode.uploads()||(self.mode.inplace()||self.mode.actions())&&self.inplace_transfers&4!=0}
    fn allows_folder_uploads(&self)->bool{self.mode.folder_uploads()||(self.mode.inplace()||self.mode.actions())&&self.inplace_transfers&8!=0}
    pub fn consume(&mut self,bytes:&[u8])->Result<Command>{
        if !self.valid{return Err(Failure::Phase)}self.valid=false;
        if !(HEADER..=MAX_FRAME).contains(&bytes.len()){return Err(Failure::Length)}
        let mut c=Cursor{bytes,position:0};if c.take(8)?!=self.mode.magic(){return Err(Failure::Header)}
        let session=c.token()?;let sequence=c.u64()?;
        if sequence!=self.next||self.session.is_some_and(|s|s!=session){return Err(Failure::Sequence)}
        let tag=c.u8()?;
        let command=match tag{
            1 if !self.mode.jump()&&self.session.is_none()&&sequence==0=>{
                let host=c.string(253,false)?;let ip=c.string(45,false)?;let port=c.u16()?;let scope=c.u32()?;
                let ip:IpAddr=ip.parse().map_err(|_|Failure::Field)?;
                if ip.is_unspecified()||ip.is_multicast()||port==0||scope>=0xfffffff0{return Err(Failure::Field)}
                let address=match ip{
                    IpAddr::V4(ip)=>{if scope!=0||ip.octets()[0]==0||ip.is_broadcast(){return Err(Failure::Field)}SocketAddr::from((ip,port))},
                    IpAddr::V6(ip)=>{if ip.is_unicast_link_local()&&scope==0{return Err(Failure::Field)}SocketAddr::V6(SocketAddrV6::new(ip,port,0,scope))},
                };
                if host.parse::<IpAddr>().is_ok_and(|literal|literal!=ip){return Err(Failure::Field)}
                let peer=Peer::new(&host,port,session).map_err(|_|Failure::Field)?;
                let previous=c.optional_key()?;
                let store=if self.mode.catalog(){let path=c.string(4095,true)?;let quota=c.u64()?;
                    if !path.starts_with('/')||!path.ends_with("/catalog.sqlite")||!(1<<20..=512<<20).contains(&quota){return Err(Failure::Field)}
                    Some(Store{path,quota})}else{None};
                Command::Start(Start{session,peer,address,previous,store,jump:None})
            },
            16 if self.mode.jump()&&self.session.is_none()&&sequence==0=>{
                let host=c.string(253,false)?;let port=c.u16()?;
                let peer=Peer::new(&host,port,session).map_err(|_|Failure::Field)?;
                let outer_host=c.string(253,false)?;let ip=c.string(45,false)?;let outer_port=c.u16()?;let scope=c.u32()?;
                let nonce=c.token()?;if nonce==session{return Err(Failure::Field)}
                let outer=Peer::new(&outer_host,outer_port,nonce).map_err(|_|Failure::Field)?;
                let ip:IpAddr=ip.parse().map_err(|_|Failure::Field)?;
                if ip.is_unspecified()||ip.is_multicast()||scope>=0xfffffff0{return Err(Failure::Field)}
                let address=match ip{
                    IpAddr::V4(ip)=>{if scope!=0||ip.octets()[0]==0||ip.is_broadcast(){return Err(Failure::Field)}SocketAddr::from((ip,outer_port))},
                    IpAddr::V6(ip)=>{if ip.is_unicast_link_local()&&scope==0{return Err(Failure::Field)}SocketAddr::V6(SocketAddrV6::new(ip,outer_port,0,scope))},
                };
                if outer_host.parse::<IpAddr>().is_ok_and(|literal|literal!=ip){return Err(Failure::Field)}
                let (outer_previous,previous)=if self.mode.remembered_jump(){(c.optional_key()?,c.optional_key()?)}else{(None,None)};
                let path=c.string(4095,true)?;let quota=c.u64()?;
                if !path.starts_with('/')||!path.ends_with("/catalog.sqlite")||!(1<<20..=512<<20).contains(&quota){return Err(Failure::Field)}
                Command::Start(Start{session,peer,address,previous,store:Some(Store{path,quota}),jump:Some(Jump{peer:outer,nonce,previous:outer_previous})})
            },
            17 if self.mode.jump()&&self.session.is_some()=>{
                let nonce=c.token()?;let action=match c.u8()?{0=>Action::Reject,1=>Action::ConnectOnce,
                    3 if self.mode.remembered_jump()=>Action::UseMatching,4 if self.mode.remembered_jump()=>Action::ReplaceVerified,_=>return Err(Failure::Field)};
                let key=c.optional_key()?;if action!=Action::Reject&&key.is_none(){return Err(Failure::Field)}
                Command::JumpApprove{nonce,action,key}
            },
            18 if self.mode.jump()&&self.session.is_some()=>{
                let nonce=c.token()?;let method=c.u8()?;let account=c.string(256,false)?;
                let authentication=match method{
                    0=>{let value=std::str::from_utf8(c.field(4096)?).map_err(|_|Failure::Field)?;
                        if value.is_empty()||value.contains('\0'){return Err(Failure::Field)}
                        JumpAuthentication::Password{account,password:Zeroizing::new(value.to_owned())}},
                    1|3=>{let key=Zeroizing::new(c.field(crate::key_auth::MAXIMUM_KEY_BYTES)?.to_vec());
                        let phrase=std::str::from_utf8(c.field(crate::key_auth::MAXIMUM_PASSPHRASE_BYTES)?).map_err(|_|Failure::Field)?;
                        if key.is_empty()||key.contains(&0)||phrase.contains('\0'){return Err(Failure::Field)}
                        let expected=if self.mode.remembered_jump(){c.optional_key()?}else{None};
                        JumpAuthentication::Key{account,key,passphrase:Zeroizing::new(phrase.to_owned()),expected,interactive:method==3}},
                    2=>JumpAuthentication::Interactive{account},_=>return Err(Failure::Field),
                };Command::JumpCredentials{nonce,authentication}
            },
            19 if self.mode.jump()&&self.session.is_some()=>{
                let nonce=c.token()?;let round=c.u8()?;let count=c.u8()?as usize;
                if !(1..=crate::interactive::MAX_ROUNDS).contains(&round)||count>crate::interactive::MAX_PROMPTS{return Err(Failure::Field)}
                let mut answers=Zeroizing::new(Vec::with_capacity(count));
                for _ in 0..count{let text=std::str::from_utf8(c.field(crate::interactive::MAX_ANSWER)?).map_err(|_|Failure::Field)?;
                    if text.contains('\0'){return Err(Failure::Field)}answers.push(text.to_owned());}
                Command::JumpAnswers{nonce,round,answers:crate::interactive::answers(answers,count).map_err(|_|Failure::Field)?}
            },
            2 if self.session.is_some()=>{
                let action=match c.u8()?{0=>Action::Reject,1=>Action::ConnectOnce,2=>Action::Remember,
                    3=>Action::UseMatching,4=>Action::ReplaceVerified,_=>return Err(Failure::Field)};
                let key=c.optional_key()?;if action!=Action::Reject&&key.is_none(){return Err(Failure::Field)}
                Command::Approve{action,key}
            },
            3 if self.session.is_some()&&!self.mode.agent()=>{
                let account=c.string(256,false)?;
                let password=std::str::from_utf8(c.field(4096)?).map_err(|_|Failure::Field)?;
                if password.is_empty()||password.contains('\0'){return Err(Failure::Field)}
                Command::Credentials{account,password:Zeroizing::new(password.to_owned())}
            },
            30 if self.mode.catalog()&&self.session.is_some()=>{
                if c.u8()?!=1{return Err(Failure::Field)}Command::DirectoryRecovery
            },
            12|15 if self.mode.key_auth()&&!self.mode.agent()&&self.session.is_some()&&(tag!=15||self.mode.interactive())=>{
                let account=c.string(256,false)?;
                let key=Zeroizing::new(c.field(crate::key_auth::MAXIMUM_KEY_BYTES)?.to_vec());
                let passphrase=std::str::from_utf8(c.field(crate::key_auth::MAXIMUM_PASSPHRASE_BYTES)?).map_err(|_|Failure::Field)?;
                if key.is_empty()||key.contains(&0)||passphrase.contains('\0'){return Err(Failure::Field)}
                let passphrase=Zeroizing::new(passphrase.to_owned());let expected=c.optional_key()?;
                Command::KeyCredentials{account,key,passphrase,expected,interactive:tag==15}
            },
            33|34 if self.mode.key_auth()&&!self.mode.agent()&&!self.mode.jump()&&self.session.is_some()
                &&(tag!=34||self.mode.interactive())=>{
                let account=c.string(256,false)?;
                let key=Zeroizing::new(c.field(crate::key_auth::MAXIMUM_KEY_BYTES)?.to_vec());
                let passphrase=std::str::from_utf8(c.field(crate::key_auth::MAXIMUM_PASSPHRASE_BYTES)?).map_err(|_|Failure::Field)?;
                if key.is_empty()||key.contains(&0)||passphrase.contains('\0'){return Err(Failure::Field)}
                let expected=c.optional_key()?;
                let certificate=Zeroizing::new(c.field(crate::key_auth::MAXIMUM_CERTIFICATE_BYTES)?.to_vec());
                if certificate.is_empty()||certificate.contains(&0){return Err(Failure::Field)}
                Command::CertificateCredentials{account,key,passphrase:Zeroizing::new(passphrase.to_owned()),
                    expected,certificate,interactive:tag==34}
            },
            13 if self.mode.interactive()&&self.session.is_some()=>Command::InteractiveStart{account:c.string(256,false)?},
            14 if self.mode.interactive()&&self.session.is_some()=>{
                let round=c.u8()?;let count=c.u8()? as usize;
                if !(1..=crate::interactive::MAX_ROUNDS).contains(&round)||count>crate::interactive::MAX_PROMPTS{return Err(Failure::Field)}
                let mut answers=Zeroizing::new(Vec::with_capacity(count));
                for _ in 0..count{
                    let text=std::str::from_utf8(c.field(crate::interactive::MAX_ANSWER)?).map_err(|_|Failure::Field)?;
                    if text.contains('\0'){return Err(Failure::Field)}answers.push(text.to_owned());
                }
                let answers=crate::interactive::answers(answers,count).map_err(|_|Failure::Field)?;
                Command::InteractiveAnswers{round,answers}
            },
            #[cfg(feature="agent-qualification")]
            80 if self.mode.agent()&&self.session.is_some()&&!self.agent_listed=>{
                let socket=c.string(103,true)?;
                if !socket.starts_with('/')||socket.as_bytes().contains(&0){return Err(Failure::Field)}
                self.agent_listed=true;Command::AgentList{socket}
            },
            #[cfg(feature="agent-qualification")]
            81 if self.mode.agent()&&self.session.is_some()&&self.agent_listed&&!self.agent_selected=>{
                let account=c.string(256,false)?;
                let digest=c.take(32)?.try_into().map_err(|_|Failure::Length)?;
                self.agent_selected=true;Command::AgentSelect{account,digest}
            },
            4 if self.session.is_some()=>Command::Directory{generation:c.token()?,path:c.string(8192,true)?},
            5 if self.session.is_some()=>Command::Next(c.token()?),
            6=>Command::Stop,
            7 if self.mode.catalog()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;
                let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let offset=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;let limit=c.u16()?as usize;let sort=c.u8()?;let descending=c.u8()?;
                if !(1..=256).contains(&limit)||sort>2||descending>1{return Err(Failure::Field)}
                let find=if c.position==bytes.len(){None}else{Some(c.token()?)};
                Command::Page(Page{request,generation,revision,offset,limit,sort,descending:descending==1,find})
            },
            31 if self.mode.catalog()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;
                let read=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let count=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let folders=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let state=c.u8()?;let query=std::str::from_utf8(c.field(2048)?).map_err(|_|Failure::Field)?;
                if read<=0||folders>count||state>3||query.is_empty()||query.contains('\0'){return Err(Failure::Field)}
                Command::Find(Find{request,generation,read,revision,count,folders,state,query:query.to_owned()})
            },
            #[cfg(feature="folder-download-qualification")]
            32 if self.mode.catalog()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;
                let read=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let count=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let folders=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let state=c.u8()?;
                let observation=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                if read<=0||revision<=0||folders>count||state!=1||observation<=0{return Err(Failure::Field)}
                Command::SummarizeFolder{request,generation,read,revision,count,folders,state,observation}
            },
            #[cfg(feature="remote-action-qualification")]
            60 if self.mode.actions()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;
                let read=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let kind=c.u8()?;
                let observation=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let name=c.string(255,true)?;
                let destination=std::str::from_utf8(c.field(255)?).map_err(|_|Failure::Field)?.to_owned();
                let size=c.u64()?;let modified=c.u32()?;let permissions=c.u32()?;
                let destination_parent=if [6,7,8].contains(&kind){Some(c.string(8192,true)?)}else{None};
                let valid_name=|value:&str|value!="."&&value!=".."&&!value.contains('/')&&!value.contains('\0')&&value.len()<=255;
                let valid_parent=|value:&str|value.starts_with('/')&&
                    (value=="/"||!value.ends_with('/')&&value.split('/').skip(1).all(|part|
                        !part.is_empty()&&part!="."&&part!=".."))&&value.split('/').skip(1).count()<=127;
                if read<=0||revision<0||!valid_name(&name)||!destination.is_empty()&&!valid_name(&destination)
                    ||match kind{1=>observation!=0||!destination.is_empty()||size!=0||modified!=0||permissions!=0,
                        2=>observation<=0||destination.is_empty()||destination==name||permissions&0o170000!=0o100000,
                        3=>observation<=0||!destination.is_empty()||permissions&0o170000!=0o100000,
                        4=>observation<=0||!destination.is_empty()||permissions&0o170000!=0o040000,
                        5=>self.mode!=Mode::RemoteActionCatalog||observation<=0||destination.is_empty()
                            ||destination==name||permissions&0o170000!=0o040000,
                        6=>self.mode!=Mode::RemoteActionCatalog||observation<=0||!destination.is_empty()
                            ||permissions&0o170000!=0o100000||destination_parent.as_deref().is_none_or(|parent|!valid_parent(parent)),
                        7=>self.mode!=Mode::RemoteActionCatalog||observation<=0||!destination.is_empty()
                            ||permissions&0o170000!=0o040000||destination_parent.as_deref().is_none_or(|parent|!valid_parent(parent)),
                        8=>self.mode!=Mode::RemoteActionCatalog||observation<=0||destination.is_empty()
                            ||permissions&0o170000!=0o100000||permissions&0o7000!=0||size>64<<30
                            ||destination_parent.as_deref().is_none_or(|parent|!valid_parent(parent)),
                        _=>true}{return Err(Failure::Field)}
                Command::ActionPrepare(RemoteAction{request,generation,read,revision,kind,observation,name,
                    destination:if destination.is_empty(){None}else{Some(destination)},destination_parent,
                    size,modified,permissions})
            },
            #[cfg(feature="remote-action-qualification")]
            61 if self.mode.actions()&&self.session.is_some()=>Command::ActionPermit{request:c.token()?},
            #[cfg(feature="download-qualification")]
            8 if self.allows_downloads()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;let observation=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                if observation==0{return Err(Failure::Field)}Command::Download{request,generation,observation}
            },
            #[cfg(feature="folder-download-qualification")]
            20 if self.allows_folders()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;
                let read=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let observation=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                if read<=0||revision<=0||observation<=0{return Err(Failure::Field)}
                Command::PrepareFolder{request,generation,read,revision,observation}
            },
            #[cfg(feature="folder-download-qualification")]
            21 if self.allows_folders()&&self.session.is_some()=>Command::ReceiveFolder{request:c.token()?},
            #[cfg(feature="folder-download-qualification")]
            22 if self.allows_folders()&&self.session.is_some()=>Command::ReleaseFolder{request:c.token()?},
            #[cfg(feature="upload-qualification")]
            9 if self.allows_uploads()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let name=c.string(255,true)?;let size=c.u64()?;
                crate::upload::Target::new("/",&name,request).map_err(|_|Failure::Field)?;
                if size>1<<30{return Err(Failure::Field)}Command::Upload{request,generation,revision,name,size}
            },
            #[cfg(feature="upload-qualification")]
            10 if self.allows_uploads()&&self.session.is_some()=>{
                let request=c.token()?;let offset=c.u64()?;let bytes=Zeroizing::new(c.field(32768)?.to_vec());
                if bytes.is_empty()||offset>1<<30||bytes.len()as u64>(1<<30)-offset{return Err(Failure::Field)}Command::SourceBytes{request,offset,bytes}
            },
            #[cfg(feature="upload-qualification")]
            11 if self.allows_uploads()&&self.session.is_some()=>{
                let request=c.token()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;Command::PublicationPermit{request,digest}
            },
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            23 if self.allows_folder_uploads()&&self.session.is_some()=>{
                let request=c.token()?;let generation=c.token()?;let revision=i64::try_from(c.u64()?).map_err(|_|Failure::Field)?;
                let name=c.string(255,true)?;crate::upload::Target::new("/",&name,request).map_err(|_|Failure::Field)?;
                let length=c.u32()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;
                let files=c.u32()?;let folders=c.u32()?;let bytes=c.u64()?;
                if revision<=0||!(22..=crate::folder_upload::MAX_MANIFEST as u32).contains(&length)||files>1024||files.checked_add(folders).is_none_or(|v|v>=2048)||bytes>1<<30{return Err(Failure::Field)}
                Command::FolderUpload{request,generation,revision,name,length,digest,files,folders,bytes}
            },
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            24 if self.allows_folder_uploads()&&self.session.is_some()=>{
                let request=c.token()?;let offset=c.u32()?;let bytes=Zeroizing::new(c.field(32768)?.to_vec());
                if bytes.is_empty()||offset>crate::folder_upload::MAX_MANIFEST as u32||bytes.len()>crate::folder_upload::MAX_MANIFEST-offset as usize{return Err(Failure::Field)}Command::FolderManifestBytes{request,offset,bytes}
            },
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            25 if self.allows_folder_uploads()&&self.session.is_some()=>{
                let request=c.token()?;let node=c.u32()?;let offset=c.u64()?;let bytes=Zeroizing::new(c.field(32768)?.to_vec());
                if node==0||node>=2048||bytes.is_empty()||offset>1<<30||bytes.len()as u64>(1<<30)-offset{return Err(Failure::Field)}Command::FolderSourceBytes{request,node,offset,bytes}
            },
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            26 if self.allows_folder_uploads()&&self.session.is_some()=>{let request=c.token()?;let node=c.u32()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;if node==0||node>=2048{return Err(Failure::Field)}Command::FolderFilePermit{request,node,digest}},
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            27 if self.allows_folder_uploads()&&self.session.is_some()=>Command::FolderRootAcknowledged{request:c.token()?},
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            28 if self.allows_folder_uploads()&&self.session.is_some()=>{let request=c.token()?;let node=c.u32()?;let files=c.u32()?;let bytes=c.u64()?;if node==0||node>=2048||files==0||files>1024||bytes>1<<30{return Err(Failure::Field)}Command::FolderProgressAcknowledged{request,node,files,bytes}},
            #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
            29 if self.allows_folder_uploads()&&self.session.is_some()=>{let request=c.token()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;Command::FolderFinalPermit{request,digest}},
            #[cfg(feature="original-edit-qualification")]
            40 if self.original_enabled=>{let request=c.token()?;let generation=c.token()?;let revision=c.u64()?;let observation=c.u64()?;
                if revision==0||revision>i64::MAX as u64||observation==0||observation>i64::MAX as u64{return Err(Failure::Field)}
                Command::BeginEdit{request,generation,revision:revision as i64,observation:observation as i64}},
            #[cfg(feature="original-edit-qualification")]
            41 if self.original_enabled=>Command::AcceptBaseline{request:c.token()?,digest:c.take(32)?.try_into().map_err(|_|Failure::Field)?},
            #[cfg(feature="original-edit-qualification")]
            42 if self.original_enabled=>{let request=c.token()?;let token=c.token()?;let revision=c.u64()?;let operation=c.token()?;let generation=c.token()?;
                let size=c.u64()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;
                if revision==0||size>1<<20{return Err(Failure::Field)}Command::SaveOriginal{request,token,revision,operation,generation,size,digest}},
            #[cfg(feature="original-edit-qualification")]
            43 if self.original_enabled=>{let request=c.token()?;let offset=c.u64()?;let bytes=Zeroizing::new(c.field(32768)?.to_vec());
                if offset>1<<20||bytes.is_empty()||bytes.len()as u64>(1<<20)-offset{return Err(Failure::Field)}Command::EditBytes{request,offset,bytes}},
            #[cfg(feature="original-edit-qualification")]
            44 if self.original_enabled=>{let request=c.token()?;let edge=c.u8()?;let requested=c.u8()?;let acknowledged=c.u8()?;
                let roles=c.take(32)?.try_into().map_err(|_|Failure::Field)?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;
                if edge>5||requested&!0x1f!=0||acknowledged&!requested!=0{return Err(Failure::Field)}Command::EditPermit{request,edge,requested,acknowledged,roles,digest}},
            #[cfg(feature="original-edit-qualification")]
            48 if self.original_enabled=>{let request=c.token()?;let token=c.token()?;let revision=c.u64()?;
                if revision==0{return Err(Failure::Field)}Command::ReleaseBaselineV1{request,token,revision}},
            #[cfg(feature="inplace-edit-v1")]
            50 if self.inplace_enabled=>{let request=c.token()?;let generation=c.token()?;let revision=c.u64()?;let observation=c.u64()?;
                if revision==0||revision>i64::MAX as u64||observation==0||observation>i64::MAX as u64{return Err(Failure::Field)}Command::BeginInPlace{request,generation,revision:revision as i64,observation:observation as i64}},
            #[cfg(feature="inplace-edit-v1")]
            51 if self.inplace_enabled=>Command::AcceptInPlace{request:c.token()?,digest:c.take(32)?.try_into().map_err(|_|Failure::Field)?},
            #[cfg(feature="inplace-edit-v1")]
            52 if self.inplace_enabled=>{let request=c.token()?;let token=c.token()?;let revision=c.u64()?;let generation=c.token()?;let size=c.u64()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;
                if revision==0||revision==u64::MAX||size>1<<20{return Err(Failure::Field)}Command::SaveInPlace{request,token,revision,generation,size,digest}},
            #[cfg(feature="inplace-edit-v1")]
            53 if self.inplace_enabled=>{let request=c.token()?;let offset=c.u64()?;let bytes=Zeroizing::new(c.field(32768)?.to_vec());
                if offset>1<<20||bytes.is_empty()||bytes.len()as u64>(1<<20)-offset{return Err(Failure::Field)}Command::InPlaceBytes{request,offset,bytes}},
            #[cfg(feature="inplace-edit-v1")]
            54 if self.inplace_enabled=>{let request=c.token()?;let sequence=c.u8()?;let kind=c.u8()?;let offset=c.u64()?;let count=c.u32()?;let digest=c.take(32)?.try_into().map_err(|_|Failure::Field)?;
                if !(1..=37).contains(&sequence)||kind>5||offset>1<<20||count>32768{return Err(Failure::Field)}Command::InPlacePermit{request,sequence,kind,offset,count,digest}},
            #[cfg(feature="inplace-edit-v1")]
            58 if self.inplace_enabled=>{let request=c.token()?;let token=c.token()?;let revision=c.u64()?;if revision==0{return Err(Failure::Field)}Command::ReleaseInPlace{request,token,revision}},
            // 45/46 are deliberately unimplemented/refused: no recovery action
            // can be replayed from a stale token. A separate review job is required.
            _=>return Err(Failure::Phase),
        };
        // Explicit K/L parent capability: metadata+selected-read+experimental
        // recoverable Original Save. Old read/write saved preferences do not arm it.
        if self.mode.original()&&self.session.is_none(){
            if c.u8()?!=0x33{return Err(Failure::Field)}self.original_enabled=true;
        }
        if self.mode.inplace()&&self.session.is_none(){
            // Exact startup3 + unchanged retainedRW contract7 + pre-body rejection1. No bool
            // upgrade of an ordinary512MiB catalog and no old-mode fallback.
            if c.take(3)?!=[3,7,1]{return Err(Failure::Field)}
            let transfers=c.u8()?;if ![0u8,1,3,7,15].contains(&transfers){return Err(Failure::Field)}
            self.inplace_transfers=transfers;
            let Command::Start(ref start)=command else{return Err(Failure::Phase)};
            if start.store.as_ref().is_none_or(|s|s.quota>480<<20){return Err(Failure::Field)}
            self.inplace_enabled=true;
        }
        if self.mode.actions()&&self.session.is_none(){
            // O/P has its own exact startup. The editor flag is independent of
            // action and transfer admission; M/N startup3 remains byte-identical.
            if c.take(3)?!=[4,7,2]{return Err(Failure::Field)}
            let transfers=c.u8()?;if ![0u8,1,3,7,15].contains(&transfers){return Err(Failure::Field)}
            self.inplace_transfers=transfers;
            let editor=c.u8()?;if editor>1{return Err(Failure::Field)}
            let Command::Start(ref start)=command else{return Err(Failure::Phase)};
            if editor==1&&start.store.as_ref().is_none_or(|s|s.quota>480<<20){return Err(Failure::Field)}
            self.inplace_enabled=editor==1;
        }
        if c.position!=bytes.len(){return Err(Failure::Length)}
        self.session=Some(session);self.next=self.next.checked_add(1).ok_or(Failure::Sequence)?;
        self.valid=true;Ok(command)
    }
}
struct Cursor<'a>{bytes:&'a[u8],position:usize}
impl<'a> Cursor<'a>{
    fn take(&mut self,n:usize)->Result<&'a[u8]>{let end=self.position.checked_add(n).ok_or(Failure::Length)?;
        let found=self.bytes.get(self.position..end).ok_or(Failure::Length)?;self.position=end;Ok(found)}
    fn u8(&mut self)->Result<u8>{Ok(self.take(1)?[0])}
    fn u16(&mut self)->Result<u16>{Ok(u16::from_be_bytes(self.take(2)?.try_into().map_err(|_|Failure::Length)?))}
    fn u32(&mut self)->Result<u32>{Ok(u32::from_be_bytes(self.take(4)?.try_into().map_err(|_|Failure::Length)?))}
    fn u64(&mut self)->Result<u64>{Ok(u64::from_be_bytes(self.take(8)?.try_into().map_err(|_|Failure::Length)?))}
    fn token(&mut self)->Result<[u8;16]>{let token=self.take(16)?.try_into().map_err(|_|Failure::Length)?;
        if token==[0;16]{return Err(Failure::Field)}Ok(token)}
    fn field(&mut self,cap:usize)->Result<&'a[u8]>{let count=self.u32()? as usize;if count>cap{return Err(Failure::Length)}self.take(count)}
    fn string(&mut self,cap:usize,path:bool)->Result<String>{let value=std::str::from_utf8(self.field(cap)?).map_err(|_|Failure::Field)?;
        if value.is_empty()||value.contains('\0')||(!path&&value.chars().any(char::is_control)){return Err(Failure::Field)}Ok(value.to_owned())}
    fn optional_key(&mut self)->Result<Option<Key>>{let bytes=self.field(16384)?;
        if bytes.is_empty(){Ok(None)}else{Ok(Some(Key::from_bytes(bytes).map_err(|_|Failure::Field)?))}}
}
pub fn header(session:[u8;16],sequence:u64,kind:u8)->Vec<u8>{
    header_for(Mode::Batches,session,sequence,kind)
}
pub fn header_for(mode:Mode,session:[u8;16],sequence:u64,kind:u8)->Vec<u8>{let mut b=mode.magic().to_vec();b.extend(session);b.extend(sequence.to_be_bytes());b.push(kind);b}
pub fn field(b:&mut Vec<u8>,bytes:&[u8])->Result<()>{
    if bytes.len()>MAX_FRAME||b.len().checked_add(4+bytes.len()).is_none_or(|n|n>MAX_FRAME){return Err(Failure::Length)}
    b.extend((bytes.len()as u32).to_be_bytes());b.extend(bytes);Ok(())
}
pub fn start(session:[u8;16],host:&str,ip:&str,port:u16,scope:u32,previous:Option<&Key>)->Result<Vec<u8>>{
    let mut b=header(session,0,1);field(&mut b,host.as_bytes())?;field(&mut b,ip.as_bytes())?;
    b.extend(port.to_be_bytes());b.extend(scope.to_be_bytes());field(&mut b,previous.map_or(&[],Key::bytes))?;Ok(b)
}

#[cfg(test)]mod tests{
    use super::*;
    fn hello()->Vec<u8>{start([1;16],"generated.example","127.0.0.1",22,0,None).unwrap()}
    fn decoder()->Decoder{let mut d=Decoder::default();assert!(matches!(d.consume(&hello()),Ok(Command::Start(_))));d}
    #[test]fn start_freezes_host_port_numeric_address_and_nonce(){
        let Command::Start(s)=Decoder::default().consume(&hello()).unwrap()else{panic!("START")};
        assert_eq!(s.peer.host(),"generated.example");assert_eq!(s.peer.port(),22);assert_eq!(s.address.to_string(),"127.0.0.1:22");
        for(host,ip,port,scope)in [("127.0.0.2","127.0.0.1",22,0),("generated.example","0.0.0.0",22,0),
            ("generated.example","127.0.0.1",0,0),("generated.example","127.0.0.1",22,1),
            ("generated.example","fe80::1",22,0),("a/b","127.0.0.1",22,0)]{
            assert!(Decoder::default().consume(&start([1;16],host,ip,port,scope,None).unwrap()).is_err());
        }
        assert!(Decoder::default().consume(&start([1;16],"generated.example","fe80::1",22,4,None).unwrap()).is_ok());
    }
    #[test]fn hostile_lengths_truncation_and_trailing_bytes_poison_decoder(){
        let good=hello();for n in 0..good.len(){assert!(Decoder::default().consume(&good[..n]).is_err());}
        let mut bad=good.clone();bad.push(0);assert_eq!(Decoder::default().consume(&bad).err(),Some(Failure::Length));
        let mut bad=good.clone();bad[HEADER..HEADER+4].copy_from_slice(&u32::MAX.to_be_bytes());
        let mut d=Decoder::default();assert!(d.consume(&bad).is_err());assert!(d.consume(&good).is_err());
        assert!(Decoder::default().consume(&vec![0;MAX_FRAME+1]).is_err());
    }
    #[test]fn sequence_session_version_and_phase_are_exact(){
        for mut bad in [header([1;16],2,6),header([2;16],1,6)]{assert!(decoder().consume(&bad).is_err());bad[0]=0;assert!(decoder().consume(&bad).is_err());}
        assert!(decoder().consume(&hello()).is_err());assert!(decoder().consume(&header([1;16],1,99)).is_err());
        assert!(Decoder::default().consume(&header([1;16],0,3)).is_err());
        assert!(matches!(Decoder::default().consume(&header([1;16],0,6)),Ok(Command::Stop)));
    }
    #[test]fn credentials_preserve_unicode_without_debug_or_line_encoding(){
        let mut b=header([1;16],1,3);field(&mut b,"generated".as_bytes()).unwrap();field(&mut b,"pāss word\nwith tab\t".as_bytes()).unwrap();
        let Command::Credentials{account,password}=decoder().consume(&b).unwrap()else{panic!("Credentials")};
        assert_eq!(account,"generated");assert_eq!(password.as_str(),"pāss word\nwith tab\t");
        for(account,password)in [(b"generated\n".as_slice(),b"password".as_slice()),(b"generated",b""),(b"generated",b"a\0b")]{
            let mut b=header([1;16],1,3);field(&mut b,account).unwrap();field(&mut b,password).unwrap();assert!(decoder().consume(&b).is_err());
        }
    }
    #[test]fn private_key_commands_require_new_version_and_bounded_exact_fields(){
        let hello=||{let mut b=paged_start();b[..8].copy_from_slice(b"MEXSFTP5");b};
        let command=|key:&[u8],pass:&[u8]|{let mut b=header_for(Mode::KeyCatalog,[1;16],1,12);
            field(&mut b,b"generated").unwrap();field(&mut b,key).unwrap();field(&mut b,pass).unwrap();field(&mut b,&[]).unwrap();b};
        let good=command(b"generated-key",b"generated-passphrase");
        let mut d=Decoder::new(Mode::KeyCatalog);d.consume(&hello()).unwrap();
        let Command::KeyCredentials{account,key,passphrase,expected,interactive}=d.consume(&good).unwrap()else{panic!("KEY")};assert!(!interactive);
        assert_eq!(account,"generated");assert_eq!(&key[..],b"generated-key");assert_eq!(passphrase.as_str(),"generated-passphrase");assert!(expected.is_none());
        assert!(d.consume(&good).is_err());
        for length in 0..good.len(){let mut d=Decoder::new(Mode::KeyCatalog);d.consume(&hello()).unwrap();assert!(d.consume(&good[..length]).is_err());}
        for(key,pass)in[(vec![],vec![]),(vec![1;32769],vec![]),(vec![1],vec![1;4097]),(vec![0],vec![]) ]{
            let mut d=Decoder::new(Mode::KeyCatalog);d.consume(&hello()).unwrap();assert!(d.consume(&command(&key,&pass)).is_err());}
        let mut old=Decoder::new(Mode::Catalog);old.consume(&paged_start()).unwrap();let mut wrong=good.clone();wrong[..8].copy_from_slice(PAGED_MAGIC);assert!(old.consume(&wrong).is_err());
        assert!(Decoder::new(Mode::Catalog).consume(&hello()).is_err());assert!(Decoder::new(Mode::KeyCatalog).consume(&paged_start()).is_err());
        let mut d=Decoder::new(Mode::KeyCatalog);d.consume(&hello()).unwrap();let mut trailing=good;trailing.push(0);assert!(d.consume(&trailing).is_err());
    }
    #[test]fn user_certificate_commands_are_direct_bounded_and_distinct_from_plain_keys(){
        let start=|mode:Mode|{let mut b=paged_start();b[..8].copy_from_slice(mode.magic());b};
        let command=|mode:Mode,tag:u8,certificate:&[u8]|{
            let mut b=header_for(mode,[1;16],1,tag);
            for value in[b"generated".as_slice(),b"generated-key",b"",b"",certificate]{field(&mut b,value).unwrap()}
            b
        };
        let cert=b"ssh-ed25519-cert-v01@openssh.com generated";
        for(mode,tag,interactive)in[(Mode::KeyCatalog,33,false),(Mode::InteractiveCatalog,34,true)]{
            let mut d=Decoder::new(mode);d.consume(&start(mode)).unwrap();
            let good=command(mode,tag,cert);
            let Command::CertificateCredentials{account,key,passphrase,expected,certificate,interactive:found}=d.consume(&good).unwrap()
                else{panic!("certificate credentials")};
            assert_eq!(account,"generated");assert_eq!(&key[..],b"generated-key");assert!(passphrase.is_empty());
            assert!(expected.is_none());assert_eq!(&certificate[..],cert);assert_eq!(found,interactive);
            assert!(d.consume(&good).is_err());
            for length in 0..good.len(){let mut d=Decoder::new(mode);d.consume(&start(mode)).unwrap();assert!(d.consume(&good[..length]).is_err());}
        }
        for cert in[vec![],vec![1;crate::key_auth::MAXIMUM_CERTIFICATE_BYTES+1],vec![0]]{
            let mut d=Decoder::new(Mode::KeyCatalog);d.consume(&start(Mode::KeyCatalog)).unwrap();
            assert!(d.consume(&command(Mode::KeyCatalog,33,&cert)).is_err());
        }
        let mut d=Decoder::new(Mode::KeyCatalog);d.consume(&start(Mode::KeyCatalog)).unwrap();
        assert_eq!(d.consume(&command(Mode::KeyCatalog,34,cert)).err(),Some(Failure::Phase));
        let mut d=Decoder::new(Mode::Catalog);d.consume(&start(Mode::Catalog)).unwrap();
        assert_eq!(d.consume(&command(Mode::Catalog,33,cert)).err(),Some(Failure::Phase));
    }
    #[cfg(feature="agent-qualification")]
    #[test]fn agent_version_requires_list_then_explicit_selection_and_rejects_other_credentials(){
        let mode=Mode::AgentCatalog;
        let mut start=paged_start();start[..8].copy_from_slice(mode.magic());
        let mut list=header_for(mode,[1;16],1,80);field(&mut list,b"/generated/agent.sock").unwrap();
        let mut select=header_for(mode,[1;16],2,81);
        field(&mut select,b"generated").unwrap();select.extend([7;32]);
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();
        assert!(matches!(d.consume(&list),Ok(Command::AgentList{socket})if socket=="/generated/agent.sock"));
        assert!(matches!(d.consume(&select),Ok(Command::AgentSelect{account,digest})if account=="generated"&&digest==[7;32]));
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();
        let mut early=select.clone();early[24..32].copy_from_slice(&1u64.to_be_bytes());
        assert_eq!(d.consume(&early).err(),Some(Failure::Phase));
        for tag in [3,12,13,14,15]{
            let mut d=Decoder::new(mode);d.consume(&start).unwrap();
            assert_eq!(d.consume(&header_for(mode,[1;16],1,tag)).err(),Some(Failure::Phase));
        }
        let mut old=Decoder::new(Mode::KeyCatalog);
        let mut old_start=paged_start();old_start[..8].copy_from_slice(Mode::KeyCatalog.magic());
        old.consume(&old_start).unwrap();
        let mut disguised=list;disguised[..8].copy_from_slice(Mode::KeyCatalog.magic());
        assert_eq!(old.consume(&disguised).err(),Some(Failure::Phase));
    }
    #[test]fn interactive_commands_are_versioned_and_keep_exact_bounded_answers(){
        let hello=||{let mut value=paged_start();value[..8].copy_from_slice(b"MEXSFTP8");value};
        let answer=|round:u8,values:&[&str]|{let mut value=header_for(Mode::InteractiveCatalog,[1;16],1,14);
            value.push(round);value.push(values.len() as u8);for text in values{field(&mut value,text.as_bytes()).unwrap()}value};
        let good=answer(1,&["pāss word\n",""]);
        let mut decoder=Decoder::new(Mode::InteractiveCatalog);decoder.consume(&hello()).unwrap();
        let Command::InteractiveAnswers{round,answers}=decoder.consume(&good).unwrap()else{panic!("interactive")};
        assert_eq!(round,1);assert_eq!(&*answers,&["pāss word\n",""]);
        let oversized="x".repeat(4097);let edge="x".repeat(4096);
        for values in [vec!["bad\0answer"],vec![oversized.as_str()],vec![edge.as_str(),edge.as_str(),"x"]]{
            let mut decoder=Decoder::new(Mode::InteractiveCatalog);decoder.consume(&hello()).unwrap();assert!(decoder.consume(&answer(1,&values)).is_err());
        }
        for round in [0,9,255]{let mut decoder=Decoder::new(Mode::InteractiveCatalog);decoder.consume(&hello()).unwrap();assert!(decoder.consume(&answer(round,&[])).is_err());}
        for length in 0..good.len(){let mut decoder=Decoder::new(Mode::InteractiveCatalog);decoder.consume(&hello()).unwrap();assert!(decoder.consume(&good[..length]).is_err());}
        let mut old=Decoder::new(Mode::KeyCatalog);let mut initial=hello();initial[..8].copy_from_slice(b"MEXSFTP5");old.consume(&initial).unwrap();
        let mut unsupported=good;unsupported[..8].copy_from_slice(b"MEXSFTP5");assert!(old.consume(&unsupported).is_err());
    }
    fn jump_start(nonce:[u8;16])->Vec<u8>{
        let mut value=header_for(Mode::JumpCatalog,[1;16],0,16);
        field(&mut value,b"private.internal.test").unwrap();value.extend(2222u16.to_be_bytes());
        field(&mut value,b"jump.example.test").unwrap();field(&mut value,b"127.0.0.1").unwrap();
        value.extend(2200u16.to_be_bytes());value.extend(0u32.to_be_bytes());value.extend(nonce);
        field(&mut value,b"/generated/catalog.sqlite").unwrap();value.extend((8u64<<20).to_be_bytes());value
    }
    #[test]fn jump_start_has_two_roles_and_no_local_destination_address(){
        let good=jump_start([2;16]);let Command::Start(start)=Decoder::new(Mode::JumpCatalog).consume(&good).unwrap()else{panic!("jump")};
        assert_eq!(start.peer.host(),"private.internal.test");assert_eq!(start.peer.port(),2222);
        assert_eq!(start.address.to_string(),"127.0.0.1:2200");assert!(start.previous.is_none());
        let jump=start.jump.unwrap();assert_eq!(jump.peer.host(),"jump.example.test");assert_eq!(jump.nonce,[2;16]);
        for count in 0..good.len(){assert!(Decoder::new(Mode::JumpCatalog).consume(&good[..count]).is_err())}
        for nonce in [[0;16],[1;16]]{assert!(Decoder::new(Mode::JumpCatalog).consume(&jump_start(nonce)).is_err())}
        assert!(Decoder::new(Mode::InteractiveCatalog).consume(&good).is_err());
        assert!(Decoder::new(Mode::JumpCatalog).consume(&paged_start()).is_err());
    }
    #[test]fn jump_commands_require_the_new_version_and_explicit_role(){
        let credential=|kind:u8,account:&[u8],key:&[u8],phrase:&[u8]|{
            let mut value=header_for(Mode::JumpCatalog,[1;16],1,18);value.extend([2;16]);value.push(kind);
            field(&mut value,account).unwrap();if kind!=2{field(&mut value,key).unwrap()}
            if kind==1||kind==3{field(&mut value,phrase).unwrap()}value
        };
        for method in [0,1,2,3]{
            let good=credential(method,b"generated",b"generated-only",b"");
            let mut decoder=Decoder::new(Mode::JumpCatalog);decoder.consume(&jump_start([2;16])).unwrap();
            assert!(matches!(decoder.consume(&good),Ok(Command::JumpCredentials{nonce:[2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2],..})));
            for count in 0..good.len(){let mut d=Decoder::new(Mode::JumpCatalog);d.consume(&jump_start([2;16])).unwrap();assert!(d.consume(&good[..count]).is_err())}
        }
        for value in [credential(4,b"generated",b"x",b""),credential(0,b"generated",b"",b""),credential(1,b"generated",b"",b""),credential(2,b"bad\n",b"",b"")]{
            let mut d=Decoder::new(Mode::JumpCatalog);d.consume(&jump_start([2;16])).unwrap();assert!(d.consume(&value).is_err());
        }
        for action in [2,3,4]{let mut value=header_for(Mode::JumpCatalog,[1;16],1,17);value.extend([2;16]);value.push(action);field(&mut value,&[]).unwrap();
            let mut d=Decoder::new(Mode::JumpCatalog);d.consume(&jump_start([2;16])).unwrap();assert!(d.consume(&value).is_err());}
    }
    fn remembered_jump_start()->Vec<u8>{
        let mut value=jump_start([2;16]);value[..8].copy_from_slice(Mode::RememberedJumpCatalog.magic());
        // Insert two explicit empty prior-key fields before the catalog path.
        let catalog=HEADER+4+"private.internal.test".len()+2+4+"jump.example.test".len()+4+"127.0.0.1".len()+2+4+16;
        value.splice(catalog..catalog,[0;8]);value
    }
    #[test]fn remembered_routes_are_a_distinct_closed_metadata_contract(){
        let good=remembered_jump_start();
        let Command::Start(start)=Decoder::new(Mode::RememberedJumpCatalog).consume(&good).unwrap()else{panic!("route")};
        assert!(start.previous.is_none());assert!(start.jump.unwrap().previous.is_none());
        for count in 0..good.len(){assert!(Decoder::new(Mode::RememberedJumpCatalog).consume(&good[..count]).is_err())}
        assert!(Decoder::new(Mode::JumpCatalog).consume(&good).is_err());
        let mut old_magic=good.clone();old_magic[..8].copy_from_slice(Mode::JumpCatalog.magic());
        assert!(Decoder::new(Mode::JumpCatalog).consume(&old_magic).is_err());
        let mut missing=jump_start([2;16]);missing[..8].copy_from_slice(Mode::RememberedJumpCatalog.magic());
        assert!(Decoder::new(Mode::RememberedJumpCatalog).consume(&missing).is_err());
        for tag in [8,9,10,11]{
            let value=header_for(Mode::RememberedJumpCatalog,[1;16],1,tag);
            let mut d=Decoder::new(Mode::RememberedJumpCatalog);d.consume(&good).unwrap();assert!(d.consume(&value).is_err());
        }
        assert!(!Mode::RememberedJumpCatalog.transfers());assert!(!Mode::RememberedJumpCatalog.uploads());
    }
    #[test]fn remembered_outer_keys_have_an_explicit_expected_identity_field(){
        for method in [1,3]{
            let mut value=header_for(Mode::RememberedJumpCatalog,[1;16],1,18);value.extend([2;16]);value.push(method);
            field(&mut value,b"generated").unwrap();field(&mut value,b"generated-only-key-body").unwrap();field(&mut value,b"").unwrap();
            let missing=value.clone();field(&mut value,b"").unwrap();
            let mut decoder=Decoder::new(Mode::RememberedJumpCatalog);decoder.consume(&remembered_jump_start()).unwrap();
            let Command::JumpCredentials{authentication,..}=decoder.consume(&value).unwrap()else{panic!("route credentials")};
            assert!(matches!(authentication,JumpAuthentication::Key{expected:None,..}));
            let mut decoder=Decoder::new(Mode::RememberedJumpCatalog);decoder.consume(&remembered_jump_start()).unwrap();assert!(decoder.consume(&missing).is_err());
            let mut old=value;old[..8].copy_from_slice(Mode::JumpCatalog.magic());
            let mut decoder=Decoder::new(Mode::JumpCatalog);decoder.consume(&jump_start([2;16])).unwrap();assert!(decoder.consume(&old).is_err());
        }
    }
    #[cfg(feature="folder-download-qualification")]
    #[test]fn routed_download_combines_exact_route_authority_without_upload_or_legacy_downgrade(){
        let mode=Mode::RoutedFolderCatalog;assert!(mode.jump()&&mode.remembered_jump()&&mode.folders()&&mode.transfers()&&mode.interactive());
        assert!(!mode.uploads());let mut start=remembered_jump_start();start[..8].copy_from_slice(mode.magic());
        let Command::Start(value)=Decoder::new(mode).consume(&start).unwrap()else{panic!("route")};
        assert!(value.previous.is_none()&&value.jump.unwrap().previous.is_none());
        for length in 0..start.len(){assert!(Decoder::new(mode).consume(&start[..length]).is_err());}
        for old in[Mode::JumpCatalog,Mode::RememberedJumpCatalog,Mode::FolderCatalog]{
            assert!(Decoder::new(old).consume(&start).is_err());
            let mut relabeled=start.clone();relabeled[..8].copy_from_slice(old.magic());
            if old==Mode::JumpCatalog||old==Mode::FolderCatalog{assert!(Decoder::new(old).consume(&relabeled).is_err());}
        }
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();
        let mut download=header_for(mode,[1;16],1,8);download.extend([3;16]);download.extend([4;16]);download.extend(1u64.to_be_bytes());
        assert!(matches!(d.consume(&download),Ok(Command::Download{..})));
        for tag in[9,10,11]{let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(d.consume(&header_for(mode,[1;16],1,tag)).is_err());}
        let mut direct=paged_start();direct[..8].copy_from_slice(mode.magic());assert!(Decoder::new(mode).consume(&direct).is_err());
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    #[test]fn routed_exclusive_file_mode_does_not_widen_f_g_h_or_accept_direct_start(){
        let mode=Mode::RoutedExclusiveUploadCatalog;
        assert_eq!(mode.magic(),b"MEXSFTPI");
        assert!(mode.jump()&&mode.remembered_jump()&&mode.folders()&&mode.transfers()&&mode.uploads());
        assert!(!mode.folder_uploads());
        let mut start=remembered_jump_start();start[..8].copy_from_slice(mode.magic());
        assert!(matches!(Decoder::new(mode).consume(&start),Ok(Command::Start(Start{jump:Some(_),..}))));
        for old in[Mode::JumpCatalog,Mode::RememberedJumpCatalog,Mode::RoutedFolderCatalog,Mode::ExclusiveUploadCatalog,Mode::FreshFolderUploadCatalog]{
            assert!(Decoder::new(old).consume(&start).is_err());
            let mut relabeled=start.clone();relabeled[..8].copy_from_slice(old.magic());
            if !old.jump(){assert!(Decoder::new(old).consume(&relabeled).is_err());}
        }
        let mut direct=paged_start();direct[..8].copy_from_slice(mode.magic());
        assert!(Decoder::new(mode).consume(&direct).is_err());
        let mut request=header_for(mode,[1;16],1,9);request.extend([3;16]);request.extend([4;16]);
        request.extend(1u64.to_be_bytes());field(&mut request,b"Generated.bin").unwrap();request.extend(65553u64.to_be_bytes());
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(matches!(d.consume(&request),Ok(Command::Upload{size:65553,..})));
        for old in[Mode::JumpCatalog,Mode::RememberedJumpCatalog,Mode::RoutedFolderCatalog]{
            let mut before=start.clone();before[..8].copy_from_slice(old.magic());
            if old==Mode::JumpCatalog{before=jump_start([2;16]);}
            let mut value=request.clone();value[..8].copy_from_slice(old.magic());
            let mut d=Decoder::new(old);d.consume(&before).unwrap();assert!(d.consume(&value).is_err());
        }
        // A valid H root request is still forbidden in this file-only mode.
        let mut folder=fresh_folder_command(1,22,0,0,0);folder[..8].copy_from_slice(mode.magic());
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(d.consume(&folder).is_err());
        assert!(d.consume(&request).is_err()); // failed decoder stays poisoned
        for length in 0..start.len(){assert!(Decoder::new(mode).consume(&start[..length]).is_err());}
    }
    #[test]fn paths_remain_byte_exact_and_never_become_local_urls(){
        let path="/generated/Café/space - underscore_\n";
        let mut b=header([1;16],1,4);b.extend([2;16]);field(&mut b,path.as_bytes()).unwrap();
        let Command::Directory{generation,path:actual}=decoder().consume(&b).unwrap()else{panic!("Directory")};
        assert_eq!(generation,[2;16]);assert_eq!(actual,path);
        let mut invalid=header([1;16],1,4);invalid.extend([0;16]);field(&mut invalid,b".").unwrap();assert!(decoder().consume(&invalid).is_err());
    }
    fn paged_start()->Vec<u8>{let mut b=start([1;16],"generated.example","127.0.0.1",22,0,None).unwrap();
        b[..8].copy_from_slice(PAGED_MAGIC);field(&mut b,b"/generated/catalog.sqlite").unwrap();b.extend((8u64<<20).to_be_bytes());b}
    #[test]fn catalog_version_and_store_authority_are_explicit(){
        let b=paged_start();assert!(Decoder::default().consume(&b).is_err());
        assert!(Decoder::new(Mode::Catalog).consume(&hello()).is_err());
        let Command::Start(s)=Decoder::new(Mode::Catalog).consume(&b).unwrap()else{panic!("START")};
        assert_eq!(s.store.unwrap().quota,8<<20);
        for n in[0,999,513u64<<20]{let mut b=paged_start();let end=b.len();b[end-8..].copy_from_slice(&n.to_be_bytes());assert!(Decoder::new(Mode::Catalog).consume(&b).is_err());}
    }
    #[test]fn page_input_has_bounded_offset_count_sort_and_generation(){
        let mut b=header_for(Mode::Catalog,[1;16],1,7);b.extend([2;16]);b.extend([3;16]);b.extend(1u64.to_be_bytes());
        b.extend(90000u64.to_be_bytes());b.extend(256u16.to_be_bytes());b.extend([2,1]);
        let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();
        let Command::Page(p)=d.consume(&b).unwrap()else{panic!("PAGE")};assert_eq!((p.offset,p.limit,p.sort,p.descending,p.find),(90000,256,2,true,None));
        let mut filtered=b.clone();filtered.extend([4;16]);let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();
        let Command::Page(p)=d.consume(&filtered).unwrap()else{panic!("filtered PAGE")};assert_eq!(p.find,Some([4;16]));
        let mut bad=filtered.clone();bad.push(1);let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();assert!(d.consume(&bad).is_err());
        for n in[0,257,u16::MAX]{let mut bad=b.clone();let end=bad.len();bad[end-4..end-2].copy_from_slice(&n.to_be_bytes());
            let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();assert!(d.consume(&bad).is_err());}
        let mut d=decoder();let mut raw=b;raw[..8].copy_from_slice(MAGIC);assert!(d.consume(&raw).is_err());
    }
    #[test]fn find_input_binds_full_snapshot_and_bounded_literal_bytes(){
        let mut b=header_for(Mode::Catalog,[1;16],1,31);b.extend([4;16]);b.extend([3;16]);
        for number in [1u64,7,768,1]{b.extend(number.to_be_bytes())}b.push(1);
        field(&mut b,"%_quote'\\CAFÉ".as_bytes()).unwrap();
        let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();
        let Command::Find(f)=d.consume(&b).unwrap()else{panic!("FIND")};
        assert_eq!((f.request,f.generation,f.read,f.revision,f.count,f.folders,f.state),([4;16],[3;16],1,7,768,1,1));
        assert_eq!(f.query,"%_quote'\\CAFÉ");
        let mut oversized=b[..HEADER+16+16+33].to_vec();field(&mut oversized,&vec![b'a';2049]).unwrap();
        let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();assert!(d.consume(&oversized).is_err());
        let mut bad=b.clone();bad[HEADER+16+16+8+8+8..HEADER+16+16+8+8+8+8].copy_from_slice(&769u64.to_be_bytes());
        let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();assert!(d.consume(&bad).is_err());
    }
    #[cfg(feature="download-qualification")]
    #[test]fn transfer_command_is_versioned_and_cannot_supply_an_arbitrary_path(){
        let mut start=paged_start();start[..8].copy_from_slice(b"MEXSFTP3");
        let mut request=header_for(Mode::TransferCatalog,[1;16],1,8);request.extend([2;16]);request.extend([3;16]);request.extend(7u64.to_be_bytes());
        let mut d=Decoder::new(Mode::TransferCatalog);d.consume(&start).unwrap();
        assert!(matches!(d.consume(&request),Ok(Command::Download{observation:7,..})));
        for observation in[0,u64::MAX]{let mut bad=request.clone();bad[HEADER+32..].copy_from_slice(&observation.to_be_bytes());
            let mut d=Decoder::new(Mode::TransferCatalog);d.consume(&start).unwrap();assert!(d.consume(&bad).is_err());}
        let mut bad=request.clone();field(&mut bad,b"/unrequested/path").unwrap();let mut d=Decoder::new(Mode::TransferCatalog);d.consume(&start).unwrap();assert!(d.consume(&bad).is_err());
        assert!(Decoder::new(Mode::Catalog).consume(&start).is_err());
        let mut d=Decoder::new(Mode::Catalog);d.consume(&paged_start()).unwrap();request[..8].copy_from_slice(PAGED_MAGIC);assert!(d.consume(&request).is_err());
    }
    #[cfg(feature="folder-download-qualification")]
    #[test]fn folder_size_is_snapshot_bound_in_browse_mode_without_transfer_authority(){
        let mut request=header_for(Mode::Catalog,[1;16],1,32);request.extend([4;16]);request.extend([3;16]);
        for value in [1u64,7,768,1]{request.extend(value.to_be_bytes())}request.push(1);request.extend(9u64.to_be_bytes());
        let mut decoder=Decoder::new(Mode::Catalog);decoder.consume(&paged_start()).unwrap();
        assert!(matches!(decoder.consume(&request),Ok(Command::SummarizeFolder{read:1,revision:7,count:768,folders:1,state:1,observation:9,..})));
        for offset in [32,40,48,56,65]{let mut bad=request.clone();bad[HEADER+offset]=255;
            let mut decoder=Decoder::new(Mode::Catalog);decoder.consume(&paged_start()).unwrap();assert!(decoder.consume(&bad).is_err());}
        let mut read=header_for(Mode::Catalog,[1;16],1,21);read.extend([4;16]);
        let mut decoder=Decoder::new(Mode::Catalog);decoder.consume(&paged_start()).unwrap();assert!(decoder.consume(&read).is_err());
    }
    #[cfg(feature="folder-download-qualification")]
    #[test]fn folder_commands_need_new_mode_exact_snapshot_and_no_paths(){
        let mode=Mode::FolderCatalog;let mut start=paged_start();start[..8].copy_from_slice(mode.magic());
        let mut request=header_for(mode,[1;16],1,20);request.extend([2;16]);request.extend([3;16]);
        for n in[7u64,9,11]{request.extend(n.to_be_bytes());}
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();
        assert!(matches!(d.consume(&request),Ok(Command::PrepareFolder{read:7,revision:9,observation:11,..})));
        for offset in[32,40,48]{let mut invalid=request.clone();invalid[HEADER+offset..HEADER+offset+8].fill(0);
            let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(d.consume(&invalid).is_err());}
        let mut invalid=request.clone();field(&mut invalid,b"/unrequested/path").unwrap();let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(d.consume(&invalid).is_err());
        for old in[Mode::Catalog,Mode::TransferCatalog,Mode::InteractiveTransferCatalog,Mode::JumpCatalog,Mode::RememberedJumpCatalog]{
            assert!(!old.folders());assert!(Decoder::new(old).consume(&start).is_err());
        }
        assert!(mode.transfers()&&mode.key_auth()&&mode.interactive()&&!mode.uploads()&&!mode.jump());
        for tag in[21,22]{let mut command=header_for(mode,[1;16],1,tag);command.extend([2;16]);let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(d.consume(&command).is_ok());}
    }
    #[cfg(all(feature="upload-qualification",feature="folder-download-qualification"))]
    #[test]fn upload_commands_need_distinct_version_and_cannot_supply_directory_paths(){
        let mut start=paged_start();start[..8].copy_from_slice(b"MEXSFTPG");
        let make=|name:&str,size:u64|{let mut b=header_for(Mode::ExclusiveUploadCatalog,[1;16],1,9);b.extend([2;16]);b.extend([3;16]);b.extend(1u64.to_be_bytes());field(&mut b,name.as_bytes()).unwrap();b.extend(size.to_be_bytes());b};
        let mut d=Decoder::new(Mode::ExclusiveUploadCatalog);d.consume(&start).unwrap();
        assert!(matches!(d.consume(&make("Draft Notes.bin",1)),Ok(Command::Upload{size:1,..})));
        for(name,size)in[("../target",1),("/target",1),("a/b",1),(".",1),("name",(1<<30)+1)]{
            let mut d=Decoder::new(Mode::ExclusiveUploadCatalog);d.consume(&start).unwrap();assert!(d.consume(&make(name,size)).is_err());
        }
        for mode in[Mode::Batches,Mode::Catalog,Mode::UploadCatalog,Mode::KeyUploadCatalog,Mode::InteractiveUploadCatalog,Mode::FolderUploadCatalog]{
            let mut d=Decoder::new(mode);let mut hello=if mode.catalog(){paged_start()}else{hello()};hello[..8].copy_from_slice(mode.magic());d.consume(&hello).unwrap();
            let mut command=make("name",1);command[..8].copy_from_slice(mode.magic());assert!(d.consume(&command).is_err());
        }
        #[cfg(feature="download-qualification")]{
            let mut d=Decoder::new(Mode::TransferCatalog);let mut hello=paged_start();hello[..8].copy_from_slice(b"MEXSFTP3");d.consume(&hello).unwrap();
            let mut command=make("name",1);command[..8].copy_from_slice(b"MEXSFTP3");assert!(d.consume(&command).is_err());
        }
    }
    #[cfg(feature="remote-action-qualification")]
    #[test]fn action_modes_are_distinct_and_keep_zero_catalog_revision_and_exact_names(){
        let mode=Mode::RemoteActionCatalog;
        let mut start=paged_start();start[..8].copy_from_slice(mode.magic());start.extend([4,7,2,15,0]);
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        let mut older=start.clone();let version=older.len()-3;older[version]=1;
        assert!(Decoder::new(mode).consume(&older).is_err());
        assert!(!decoder.inplace_enabled());assert_eq!(decoder.transfer_capabilities(),15);
        assert!(mode.actions()&&mode.interactive()&&mode.key_auth()&&!mode.jump());
        let mut rename=header_for(mode,[1;16],1,60);rename.extend([2;16]);rename.extend([3;16]);
        rename.extend(1u64.to_be_bytes());rename.extend(0u64.to_be_bytes());rename.push(2);
        rename.extend(7u64.to_be_bytes());field(&mut rename,"e\u{301}.txt".as_bytes()).unwrap();
        field(&mut rename,"é.txt".as_bytes()).unwrap();rename.extend(1u64.to_be_bytes());
        rename.extend(2u32.to_be_bytes());rename.extend(0o100644u32.to_be_bytes());
        assert!(matches!(decoder.consume(&rename),Ok(Command::ActionPrepare(RemoteAction{revision:0,kind:2,..}))));
        let mut permit=header_for(mode,[1;16],2,61);permit.extend([2;16]);
        assert!(matches!(decoder.consume(&permit),Ok(Command::ActionPermit{request:[2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2]})));
        for old in [Mode::InPlaceEditCatalog,Mode::ExclusiveUploadCatalog,Mode::Catalog]{
            let mut old_start=paged_start();old_start[..8].copy_from_slice(old.magic());
            if old.inplace(){old_start.extend([3,7,1,15]);}
            let mut d=Decoder::new(old);d.consume(&old_start).unwrap();
            let mut command=rename.clone();command[..8].copy_from_slice(old.magic());
            assert!(d.consume(&command).is_err());
        }
        let mut routed=remembered_jump_start();routed[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        routed.extend([4,7,2,15,1]);
        let mut d=Decoder::new(Mode::RoutedRemoteActionCatalog);d.consume(&routed).unwrap();
        assert!(d.inplace_enabled()&&Mode::RoutedRemoteActionCatalog.jump()&&Mode::RoutedRemoteActionCatalog.remembered_jump());
        let mut p_prepare=rename.clone();p_prepare[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        assert!(matches!(d.consume(&p_prepare),Ok(Command::ActionPrepare(RemoteAction{kind:2,..}))));
        let mut p_permit=header_for(Mode::RoutedRemoteActionCatalog,[1;16],2,61);p_permit.extend([2;16]);
        let Command::ActionPermit{request}=d.consume(&p_permit).unwrap()else{panic!("P permit")};
        assert_eq!(request,[2;16]);
        let mut invalid_editor=routed.clone();*invalid_editor.last_mut().unwrap()=2;
        assert!(Decoder::new(Mode::RoutedRemoteActionCatalog).consume(&invalid_editor).is_err());
        let mut bad=rename.clone();bad[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        // The destination is one exact component; no parent-supplied path.
        let mut slash=header_for(mode,[1;16],1,60);slash.extend([2;16]);slash.extend([3;16]);
        slash.extend(1u64.to_be_bytes());slash.extend(0u64.to_be_bytes());slash.push(1);
        slash.extend(0u64.to_be_bytes());field(&mut slash,b"a/b").unwrap();field(&mut slash,b"").unwrap();
        slash.extend(0u64.to_be_bytes());slash.extend(0u32.to_be_bytes());slash.extend(0u32.to_be_bytes());
        let mut d=Decoder::new(mode);d.consume(&start).unwrap();assert!(d.consume(&slash).is_err());
        assert!(Decoder::new(mode).consume(&routed).is_err());
        assert!(Decoder::new(Mode::RoutedRemoteActionCatalog).consume(&start).is_err());
        bad.push(0);let mut d=Decoder::new(Mode::RoutedRemoteActionCatalog);
        d.consume(&routed).unwrap();assert!(d.consume(&bad).is_err());
    }
    #[cfg(feature="remote-action-qualification")]
    #[test]fn moves_require_direct_mode_distinct_kinds_and_one_bounded_absolute_parent(){
        let mode=Mode::RemoteActionCatalog;
        let mut start=paged_start();start[..8].copy_from_slice(mode.magic());start.extend([4,7,2,15,0]);
        let command=|kind:u8,permissions:u32,parent:&[u8]|{
            let mut bytes=header_for(mode,[1;16],1,60);bytes.extend([2;16]);bytes.extend([3;16]);
            bytes.extend(1u64.to_be_bytes());bytes.extend(0u64.to_be_bytes());bytes.push(kind);
            bytes.extend(7u64.to_be_bytes());field(&mut bytes,b"file.txt").unwrap();
            field(&mut bytes,b"").unwrap();bytes.extend(1u64.to_be_bytes());
            bytes.extend(2u32.to_be_bytes());bytes.extend(permissions.to_be_bytes());
            field(&mut bytes,parent).unwrap();bytes
        };
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        let accepted=command(6,0o100644,b"/generated/Other");
        assert!(matches!(decoder.consume(&accepted),Ok(Command::ActionPrepare(RemoteAction{
            kind:6,destination_parent:Some(parent),..}))if parent=="/generated/Other"));
        let folder=command(7,0o040755,b"/generated/Other");
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(matches!(decoder.consume(&folder),Ok(Command::ActionPrepare(RemoteAction{
            kind:7,destination_parent:Some(parent),..}))if parent=="/generated/Other"));
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(decoder.consume(&command(7,0o100644,b"/generated/Other")).is_err());
        for invalid in [b"relative".as_slice(),b"/generated/../Other",b"/generated//Other",
            b"/generated/Other/",b"/generated/./Other"]{
            let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
            assert!(decoder.consume(&command(7,0o040755,invalid)).is_err());
        }
        let mut incomplete=accepted.clone();incomplete.truncate(incomplete.len()-4-b"/generated/Other".len());
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(decoder.consume(&incomplete).is_err());
        let mut routed=remembered_jump_start();routed[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        routed.extend([4,7,2,15,1]);
        let mut remote=accepted;remote[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        let mut decoder=Decoder::new(Mode::RoutedRemoteActionCatalog);decoder.consume(&routed).unwrap();
        assert!(decoder.consume(&remote).is_err());
        let mut remote_folder=folder;remote_folder[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        let mut decoder=Decoder::new(Mode::RoutedRemoteActionCatalog);decoder.consume(&routed).unwrap();
        assert!(decoder.consume(&remote_folder).is_err());
    }
    #[cfg(feature="remote-action-qualification")]
    #[test]fn copy_requires_direct_mode_bounded_regular_source_and_new_name_parent(){
        let mode=Mode::RemoteActionCatalog;
        let mut start=paged_start();start[..8].copy_from_slice(mode.magic());start.extend([4,7,2,15,0]);
        let command=|permission:u32,size:u64,name:&[u8],parent:&[u8]|{
            let mut bytes=header_for(mode,[1;16],1,60);bytes.extend([2;16]);bytes.extend([3;16]);
            bytes.extend(1u64.to_be_bytes());bytes.extend(0u64.to_be_bytes());bytes.push(8);
            bytes.extend(7u64.to_be_bytes());field(&mut bytes,b"file.txt").unwrap();
            field(&mut bytes,name).unwrap();bytes.extend(size.to_be_bytes());
            bytes.extend(2u32.to_be_bytes());bytes.extend(permission.to_be_bytes());
            field(&mut bytes,parent).unwrap();bytes
        };
        let accepted=command(0o100751,1,b"copy.txt",b"/generated/Other");
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(matches!(decoder.consume(&accepted),Ok(Command::ActionPrepare(RemoteAction{
            kind:8,destination:Some(name),destination_parent:Some(parent),..}))
            if name=="copy.txt"&&parent=="/generated/Other"));
        for (mode_bits,size,name,parent) in [
            (0o104751,1,b"copy.txt".as_slice(),b"/generated/Other".as_slice()),
            (0o120777,1,b"copy.txt",b"/generated/Other"),
            (0o100751,(64<<30)+1,b"copy.txt",b"/generated/Other"),
            (0o100751,1,b"",b"/generated/Other"),
            (0o100751,1,b"copy.txt",b"/generated/../Other"),
        ]{
            let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
            assert!(decoder.consume(&command(mode_bits,size,name,parent)).is_err());
        }
        let mut routed=remembered_jump_start();routed[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        routed.extend([4,7,2,15,1]);
        let mut routed_command=accepted;routed_command[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        let mut decoder=Decoder::new(Mode::RoutedRemoteActionCatalog);decoder.consume(&routed).unwrap();
        assert!(decoder.consume(&routed_command).is_err());
    }
    #[cfg(feature="remote-action-qualification")]
    #[test]fn empty_directory_delete_has_its_own_kind_and_rejects_file_or_link_modes(){
        let mode=Mode::RemoteActionCatalog;
        let mut start=paged_start();start[..8].copy_from_slice(mode.magic());start.extend([4,7,2,15,0]);
        let action=|kind:u8,permissions:u32,destination:&[u8]|{
            let mut bytes=header_for(mode,[1;16],1,60);bytes.extend([2;16]);bytes.extend([3;16]);
            bytes.extend(1u64.to_be_bytes());bytes.extend(0u64.to_be_bytes());bytes.push(kind);
            bytes.extend(7u64.to_be_bytes());field(&mut bytes,b"Empty Folder").unwrap();
            field(&mut bytes,destination).unwrap();bytes.extend(0u64.to_be_bytes());
            bytes.extend(2u32.to_be_bytes());bytes.extend(permissions.to_be_bytes());bytes
        };
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(matches!(decoder.consume(&action(4,0o040755,b"")),Ok(Command::ActionPrepare(RemoteAction{kind:4,..}))));
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(matches!(decoder.consume(&action(5,0o040755,b"Other")),Ok(Command::ActionPrepare(RemoteAction{kind:5,..}))));
        for (kind,mode_bits,destination) in [(4,0o100644,b"".as_slice()),(4,0o120777,b""),
            (3,0o040755,b""),(2,0o040755,b"Other"),(4,0o040755,b"Other"),
            (5,0o100644,b"Other"),(5,0o120777,b"Other"),(5,0o040755,b""),
            (5,0o040755,b"Empty Folder")] {
            let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
            assert!(decoder.consume(&action(kind,mode_bits,destination)).is_err());
        }
        let mut routed=remembered_jump_start();routed[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        routed.extend([4,7,2,15,1]);
        let mut decoder=Decoder::new(Mode::RoutedRemoteActionCatalog);decoder.consume(&routed).unwrap();
        let mut denied=action(5,0o040755,b"Other");denied[..8].copy_from_slice(Mode::RoutedRemoteActionCatalog.magic());
        assert!(decoder.consume(&denied).is_err());
    }
    #[cfg(all(feature="upload-qualification",feature="folder-download-qualification"))]
    #[test]fn upload_source_and_publication_frames_are_bounded_byte_exact_and_replay_poisoning(){
        let mut start=paged_start();start[..8].copy_from_slice(b"MEXSFTPG");
        let mut bytes=header_for(Mode::ExclusiveUploadCatalog,[1;16],1,10);bytes.extend([2;16]);bytes.extend(7u64.to_be_bytes());field(&mut bytes,&[0,255,1]).unwrap();
        let mut d=Decoder::new(Mode::ExclusiveUploadCatalog);d.consume(&start).unwrap();
        let Command::SourceBytes{request,offset,bytes:body}=d.consume(&bytes).unwrap()else{panic!("SOURCE")};assert_eq!((request,offset),([2;16],7));assert_eq!(body.as_slice(),[0,255,1]);assert!(d.consume(&bytes).is_err());
        let mut permit=header_for(Mode::ExclusiveUploadCatalog,[1;16],1,11);permit.extend([2;16]);permit.extend([9;32]);let mut d=Decoder::new(Mode::ExclusiveUploadCatalog);d.consume(&start).unwrap();
        assert!(matches!(d.consume(&permit),Ok(Command::PublicationPermit{digest,..})if digest==[9;32]));
        for size in[0,32769]{let mut bad=header_for(Mode::ExclusiveUploadCatalog,[1;16],1,10);bad.extend([2;16]);bad.extend(0u64.to_be_bytes());field(&mut bad,&vec![0;size]).unwrap();
            let mut d=Decoder::new(Mode::ExclusiveUploadCatalog);d.consume(&start).unwrap();assert!(d.consume(&bad).is_err());}
        permit.push(0);let mut d=Decoder::new(Mode::ExclusiveUploadCatalog);d.consume(&start).unwrap();assert!(d.consume(&permit).is_err());
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    fn fresh_folder_start(mode:Mode)->Decoder{let mut bytes=paged_start();bytes[..8].copy_from_slice(mode.magic());let mut decoder=Decoder::new(mode);decoder.consume(&bytes).unwrap();decoder}
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    fn fresh_folder_command(revision:u64,length:u32,files:u32,folders:u32,size:u64)->Vec<u8>{
        let mut value=header_for(Mode::FreshFolderUploadCatalog,[1;16],1,23);value.extend([2;16]);value.extend([3;16]);value.extend(revision.to_be_bytes());field(&mut value,b"New Folder").unwrap();value.extend(length.to_be_bytes());value.extend([7;32]);value.extend(files.to_be_bytes());value.extend(folders.to_be_bytes());value.extend(size.to_be_bytes());value
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    #[test]fn routed_folder_j_preserves_old_modes_and_requires_two_role_start(){
        let mode=Mode::RoutedFreshFolderUploadCatalog;
        assert_eq!(mode.magic(),b"MEXSFTPJ");
        assert!(mode.jump()&&mode.remembered_jump()&&mode.folder_uploads()&&mode.uploads()&&mode.folders());
        let mut start=remembered_jump_start();start[..8].copy_from_slice(mode.magic());
        let mut command=fresh_folder_command(1,22,0,0,0);command[..8].copy_from_slice(mode.magic());
        let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();
        assert!(matches!(decoder.consume(&command),Ok(Command::FolderUpload{length:22,files:0,folders:0,bytes:0,..})));
        for old in[Mode::Catalog,Mode::JumpCatalog,Mode::RememberedJumpCatalog,Mode::FolderCatalog,Mode::RoutedFolderCatalog,Mode::ExclusiveUploadCatalog,Mode::FreshFolderUploadCatalog,Mode::RoutedExclusiveUploadCatalog]{
            assert!(Decoder::new(old).consume(&start).is_err());
            if old!=Mode::FreshFolderUploadCatalog{assert!(!old.folder_uploads());}
        }
        let mut direct=paged_start();direct[..8].copy_from_slice(mode.magic());assert!(Decoder::new(mode).consume(&direct).is_err());
        for size in 0..command.len(){let mut decoder=Decoder::new(mode);decoder.consume(&start).unwrap();assert!(decoder.consume(&command[..size]).is_err());}
        for old in[Mode::RoutedFolderCatalog,Mode::RoutedExclusiveUploadCatalog]{
            let mut before=start.clone();before[..8].copy_from_slice(old.magic());let mut request=command.clone();request[..8].copy_from_slice(old.magic());
            let mut decoder=Decoder::new(old);decoder.consume(&before).unwrap();assert!(decoder.consume(&request).is_err());
        }
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    #[test]fn folder_upload_requires_distinct_h_authority_and_exact_bounded_header(){
        let mode=Mode::FreshFolderUploadCatalog;assert_eq!(mode.magic(),b"MEXSFTPH");assert!(mode.folder_uploads()&&mode.uploads()&&mode.folders()&&!mode.jump());
        let request=fresh_folder_command(1,22,0,0,0);assert!(matches!(fresh_folder_start(mode).consume(&request),Ok(Command::FolderUpload{length:22,..})));
        for old in[Mode::Catalog,Mode::FolderCatalog,Mode::ExclusiveUploadCatalog,Mode::FolderUploadCatalog]{let mut value=request.clone();value[..8].copy_from_slice(old.magic());assert!(!old.folder_uploads());assert!(fresh_folder_start(old).consume(&value).is_err());}
        for value in[fresh_folder_command(0,22,0,0,0),fresh_folder_command(1,21,0,0,0),fresh_folder_command(1,512*1024+1,0,0,0),fresh_folder_command(1,22,1025,0,0),fresh_folder_command(1,22,1024,u32::MAX,0),fresh_folder_command(1,22,0,0,u64::MAX)]{assert!(fresh_folder_start(mode).consume(&value).is_err());}
        for length in 0..request.len(){assert!(fresh_folder_start(mode).consume(&request[..length]).is_err());}
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    #[test]fn folder_manifest_uses_existing_frame_cap_and_ordered_bounded_chunks(){
        let mode=Mode::FreshFolderUploadCatalog;assert_eq!(MAX_FRAME,65536);
        for(size,offset,accepted)in[(32768,0,true),(32769,0,false),(0,0,false),(1,512*1024,true),(2,512*1024,false)]{
            let mut value=header_for(mode,[1;16],1,24);value.extend([2;16]);value.extend((offset as u32).to_be_bytes());field(&mut value,&vec![7;size]).unwrap();
            let result=fresh_folder_start(mode).consume(&value);assert_eq!(result.is_ok(),accepted&&offset+size<=512*1024);
        }
        let mut value=fresh_folder_command(1,22,0,0,0);value.push(0);let mut decoder=fresh_folder_start(mode);assert!(decoder.consume(&value).is_err());assert!(decoder.consume(&fresh_folder_command(1,22,0,0,0)).is_err());
    }
    #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
    #[test]fn folder_member_and_ack_frames_cannot_name_local_paths_or_unbounded_nodes(){
        let mode=Mode::FreshFolderUploadCatalog;
        for(node,offset,count,accepted)in[(1u32,0u64,3,true),(0,0,3,false),(2048,0,3,false),(1,u64::MAX,3,false),(1,0,0,false),(1,0,32769,false)]{
            let mut value=header_for(mode,[1;16],1,25);value.extend([2;16]);value.extend(node.to_be_bytes());value.extend(offset.to_be_bytes());field(&mut value,&vec![7;count]).unwrap();
            assert_eq!(fresh_folder_start(mode).consume(&value).is_ok(),accepted);
        }
        for tag in[26,27,28,29]{
            let mut value=header_for(mode,[1;16],1,tag);value.extend([2;16]);
            match tag{26=>{value.extend(1u32.to_be_bytes());value.extend([7;32]);},28=>{value.extend(1u32.to_be_bytes());value.extend(1u32.to_be_bytes());value.extend(3u64.to_be_bytes());},29=>value.extend([7;32]),_=>{}}
            assert!(fresh_folder_start(mode).consume(&value).is_ok());field(&mut value,b"/unrequested/local/path").unwrap();assert!(fresh_folder_start(mode).consume(&value).is_err());
        }
    }

}
