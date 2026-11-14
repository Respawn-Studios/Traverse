//! One selected SMB file task. It never owns the catalog or the IPC writer.
use super::{catalog::{Row,SelectedRow},channel::Stop,download_wire::{Command,Selection},network::remote,wire::Issue};
use smb2::{client::{Connection,selected_download::{CheckedFileReader,ListedFile}},types::TreeId,Error};
use std::{future::Future,time::Duration};
use tokio::sync::mpsc;
pub async fn resolve(selection:&Selection,owner:&super::store::Owner,stop:&Stop)->Result<SelectedRow,Issue>{
    let(tx,rx)=tokio::sync::oneshot::channel();
    let command=super::store::Command::Selected{selection:selection.clone(),reply:tx};
    tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=owner.commands.send(command)=>value.map_err(|_|Issue::Storage)?}
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=rx=>value.map_err(|_|Issue::Storage)?,_=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}
}

pub enum Event {
    Prepared{selection:Selection,item:Row},
    Bytes{selection:Selection,sequence:u64,offset:u64,bytes:Vec<u8>},
}
pub enum End {Complete{selection:Selection,bytes:u64},Released(Selection)}
pub struct Job {
    pub commands:mpsc::Sender<Command>,pub events:mpsc::Receiver<Event>,
    pub task:tokio::task::JoinHandle<Result<End,Issue>>,
}
async fn operation<T>(future:impl Future<Output=Result<T,Error>>,stop:&Stop,seconds:u64)->Result<T,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=future=>value.map_err(remote),_=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
async fn publish(event:Event,events:&mpsc::Sender<Event>,stop:&Stop)->Result<(),Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=events.send(event)=>value.map_err(|_|Issue::IPC),_=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}
}
async fn command(commands:&mut mpsc::Receiver<Command>,stop:&Stop,seconds:u64)->Result<Command,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=commands.recv()=>value.ok_or(Issue::IPC),_=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
fn same(token:&str,ordinal:u64,selection:&Selection)->bool{token==selection.token&&ordinal==selection.ordinal}
async fn execute(selection:Selection,selected:SelectedRow,conn:Connection,tree:TreeId,stop:Stop,
    events:mpsc::Sender<Event>,mut commands:mpsc::Receiver<Command>)->Result<End,Issue>{
    let mut path=selected.directory;
    if !path.is_empty(){path.push(92);}path.extend_from_slice(&selected.item.wire);
    let listed=ListedFile{attributes:selected.item.attributes,size:selected.item.size,modified:selected.item.modified};
    let mut reader=operation(CheckedFileReader::prepare(conn,tree,&path,listed),&stop,10).await?;
    publish(Event::Prepared{selection:selection.clone(),item:selected.item},&events,&stop).await?;
    match command(&mut commands,&stop,30).await?{
        Command::Begin{token,ordinal}if same(&token,ordinal,&selection)=>{},
        Command::Release{token,ordinal}if same(&token,ordinal,&selection)=>{
            operation(reader.release(),&stop,2).await?;return Ok(End::Released(selection));
        },_=>return Err(Issue::Invalid),
    }
    let size=reader.snapshot().size;let(mut offset,mut sequence)=(0u64,0u64);
    while offset<size {
        let bytes=operation(reader.read_chunk(),&stop,10).await?;
        let end=offset.checked_add(bytes.len()as u64).filter(|v|*v<=size).ok_or(Issue::Invalid)?;
        if bytes.is_empty()||bytes.len()>32768{return Err(Issue::Invalid);}
        publish(Event::Bytes{selection:selection.clone(),sequence,offset,bytes},&events,&stop).await?;
        match command(&mut commands,&stop,5).await?{
            Command::Ack{token,ordinal,sequence:n,offset:actual}if same(&token,ordinal,&selection)&&n==sequence&&actual==end=>{},
            _=>return Err(Issue::Invalid),
        }
        offset=end;sequence=sequence.checked_add(1).ok_or(Issue::Invalid)?;
    }
    operation(reader.finish(),&stop,10).await?;
    Ok(End::Complete{selection,bytes:offset})
}
pub fn start(selection:Selection,selected:SelectedRow,conn:Connection,tree:TreeId,stop:Stop)->Job {
    let(tx,commands)=mpsc::channel(1);let(events,rx)=mpsc::channel(1);
    let task=tokio::spawn(execute(selection,selected,conn,tree,stop,events,commands));
    Job{commands:tx,events:rx,task}
}
