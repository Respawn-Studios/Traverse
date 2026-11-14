//! U1 new-file transaction. No remote mutation precedes BEGIN, which the
//! parent sends only after its durable stage-intent record is committed.
use super::{channel::Stop,store,upload_wire::{Command,Selection,FolderSelection},wire::Issue,network::remote};
use smb2::{client::{Connection,selected_upload::{CheckedStagedUpload,Publication}},types::{TreeId,Command as SMBCommand,status::NtStatus},Error};
use std::{future::Future,sync::{Arc,atomic::AtomicU64},time::Duration};
use tokio::sync::{mpsc,oneshot};

pub enum Event {Ready(Selection),Need(Selection,u64,u64,u32),Written(Selection,u64),Digest(Selection),StageVerified(Selection,[u8;32]),
    FolderManifestNeed(FolderSelection,u64,u32),FolderReady(FolderSelection),FolderRootCreated(FolderSelection),
    FolderNeed(FolderSelection,u32,u64,u64,u32),FolderDigest(FolderSelection,u32),
    FolderFileVerified(FolderSelection,u32,usize,u64),FolderStageVerified(FolderSelection,[u8;32])}
pub enum End {Complete(Selection,[u8;32]),StageCollision(Selection),FinalCollision(Selection),
    FolderComplete(FolderSelection,[u8;32]),FolderStageCollision(FolderSelection),FolderFinalCollision(FolderSelection)}
pub struct Job {pub commands:mpsc::Sender<Command>,pub events:mpsc::Receiver<Event>,pub task:tokio::task::JoinHandle<Result<End,Issue>>,
    pub folder_failure:Option<Arc<AtomicU64>>,pub folder_identity:Option<(String,u64)>}
fn same(token:&str,ordinal:u64,s:&Selection)->bool{token==s.token&&ordinal==s.ordinal}
async fn send(event:Event,output:&mpsc::Sender<Event>,stop:&Stop)->Result<(),Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=output.send(event)=>value.map_err(|_|Issue::IPC),_=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}
}
async fn receive(input:&mut mpsc::Receiver<Command>,stop:&Stop,seconds:u64)->Result<Command,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=input.recv()=>value.ok_or(Issue::IPC),_=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
async fn operation<T>(future:impl Future<Output=smb2::Result<T>>,stop:&Stop,seconds:u64)->Result<T,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=future=>value.map_err(remote),_=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
pub async fn resolve(s:&Selection,owner:&store::Owner,stop:&Stop)->Result<Vec<u16>,Issue>{
    let(tx,rx)=oneshot::channel();let query=store::Command::UploadDirectory{number:s.number,generation:s.generation.clone(),revision:s.revision,reply:tx};
    tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=owner.commands.send(query)=>value.map_err(|_|Issue::Storage)?}
    let path=tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=rx=>value.map_err(|_|Issue::Storage)?,_=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}?;
    if path!=s.parent{return Err(Issue::Invalid);}Ok(path)
}
async fn execute(s:Selection,parent:Vec<u16>,conn:Connection,tree:TreeId,stop:Stop,
    events:mpsc::Sender<Event>,mut commands:mpsc::Receiver<Command>)->Result<End,Issue>{
    send(Event::Ready(s.clone()),&events,&stop).await?;
    match receive(&mut commands,&stop,30).await?{Command::Begin{token,ordinal}if same(&token,ordinal,&s)=>{},_=>return Err(Issue::Invalid)}
    // Keep the raw CREATE error long enough to distinguish a server-confirmed
    // exclusive collision from an unanswered CREATE.
    let opened=tokio::select!{biased;
        _=stop.wait()=>return Err(Issue::Stop),
        value=CheckedStagedUpload::create(conn,tree,&parent,&s.stage,&s.name,s.size)=>value,
        _=tokio::time::sleep(Duration::from_secs(10))=>return Err(Issue::Deadline),
    };
    let mut upload=match opened{
        Ok(value)=>value,
        Err(Error::Protocol{status,command})if status==NtStatus::OBJECT_NAME_COLLISION&&command==SMBCommand::Create=>return Ok(End::StageCollision(s)),
        Err(error)=>return Err(remote(error)),
    };
    let mut sequence=0u64;
    while upload.written()<s.size{
        let offset=upload.written();let count=(s.size-offset).min(upload.maximum_chunk().map_err(remote)? as u64) as u32;
        send(Event::Need(s.clone(),sequence,offset,count),&events,&stop).await?;
        let bytes=match receive(&mut commands,&stop,30).await?{
            Command::Data{token,ordinal,sequence:actual,offset:at,bytes}if same(&token,ordinal,&s)&&actual==sequence&&at==offset&&bytes.len()==count as usize=>bytes,
            _=>return Err(Issue::Invalid),
        };
        operation(upload.write_chunk(bytes),&stop,10).await?;
        send(Event::Written(s.clone(),upload.written()),&events,&stop).await?;
        sequence=sequence.checked_add(1).ok_or(Issue::Invalid)?;
    }
    send(Event::Digest(s.clone()),&events,&stop).await?;
    let digest=match receive(&mut commands,&stop,30).await?{Command::Digest{token,ordinal,digest}if same(&token,ordinal,&s)=>digest,_=>return Err(Issue::Invalid)};
    operation(upload.flush(),&stop,10).await?;
    let stage=operation(upload.verify_stage(&digest),&stop,300).await?;
    send(Event::StageVerified(s.clone(),digest),&events,&stop).await?;
    match receive(&mut commands,&stop,30).await?{Command::Commit{token,ordinal}if same(&token,ordinal,&s)=>{},_=>return Err(Issue::Invalid)}
    match operation(upload.publish(stage,&digest),&stop,300).await?{
        Publication::Complete=>Ok(End::Complete(s,digest)),Publication::FinalCollision=>Ok(End::FinalCollision(s)),
    }
}
pub fn start(s:Selection,parent:Vec<u16>,conn:Connection,tree:TreeId,stop:Stop)->Job{
    let(tx,commands)=mpsc::channel(1);let(events,rx)=mpsc::channel(1);
    let task=tokio::spawn(execute(s,parent,conn,tree,stop,events,commands));
    Job{commands:tx,events:rx,task,folder_failure:None,folder_identity:None}
}
