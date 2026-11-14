//! One selected folder task. Transport, catalog and IPC stay with their owners.
use super::{catalog::SelectedRow,channel::Stop,download_wire::Selection,folder_wire::Command,network::remote,wire::Issue};
use smb2::{client::{Connection,selected_folder_download::{PreparedFolder,FolderNode,FolderReadEvent}},types::TreeId,Error};
use std::{future::Future,time::Duration};
use tokio::sync::mpsc;
pub enum Event{Node{selection:Selection,ordinal:usize,node:FolderNode},Prepared{selection:Selection,files:usize,folders:usize,bytes:u64,longest:usize},Member{selection:Selection,ordinal:usize,bytes:u64,finished:bool},Bytes{selection:Selection,ordinal:usize,sequence:u64,offset:u64,bytes:Vec<u8>}}
pub enum End{Complete{selection:Selection,bytes:u64,files:usize},Released(Selection)}
pub struct Job{pub commands:mpsc::Sender<Command>,pub events:mpsc::Receiver<Event>,pub task:tokio::task::JoinHandle<Result<End,Issue>>}
async fn operation<T>(future:impl Future<Output=Result<T,Error>>,stop:&Stop,seconds:u64)->Result<T,Issue>{tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=future=>value.map_err(remote),_=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}}
async fn publish(event:Event,events:&mpsc::Sender<Event>,stop:&Stop)->Result<(),Issue>{tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=events.send(event)=>value.map_err(|_|Issue::IPC),_=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}}
async fn command(commands:&mut mpsc::Receiver<Command>,stop:&Stop,seconds:u64)->Result<Command,Issue>{tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=commands.recv()=>value.ok_or(Issue::IPC),_=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}}
pub async fn resolve(selection:&Selection,owner:&super::store::Owner,stop:&Stop)->Result<SelectedRow,Issue>{
    let(tx,rx)=tokio::sync::oneshot::channel();let command=super::store::Command::SelectedFolder{selection:selection.clone(),reply:tx};
    tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=owner.commands.send(command)=>value.map_err(|_|Issue::Storage)?}
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=rx=>value.map_err(|_|Issue::Storage)?,_=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}
}
fn same(token:&str,ordinal:u64,s:&Selection)->bool{token==s.token&&ordinal==s.ordinal}
async fn execute(selection:Selection,selected:SelectedRow,conn:Connection,tree:TreeId,stop:Stop,events:mpsc::Sender<Event>,mut commands:mpsc::Receiver<Command>)->Result<End,Issue>{
    let mut path=selected.directory;if !path.is_empty(){path.push(92);}path.extend(&selected.item.wire);
    let mut reader=operation(PreparedFolder::prepare(conn,tree,&path,selected.item.attributes,selected.item.modified),&stop,60).await?;
    for(ordinal,node)in reader.nodes().iter().enumerate(){publish(Event::Node{selection:selection.clone(),ordinal,node:node.clone()},&events,&stop).await?;}
    publish(Event::Prepared{selection:selection.clone(),files:reader.files(),folders:reader.folders(),bytes:reader.logical_bytes(),longest:reader.longest_path_bytes()},&events,&stop).await?;
    match command(&mut commands,&stop,300).await?{
        Command::Begin{token,ordinal}if same(&token,ordinal,&selection)=>{},
        Command::Release{token,ordinal}if same(&token,ordinal,&selection)=>{operation(reader.release(),&stop,2).await?;return Ok(End::Released(selection));},_=>return Err(Issue::Invalid),
    }
    operation(reader.begin(),&stop,60).await?;let mut sequence=0u64;
    loop{match operation(reader.next(),&stop,60).await?{
        FolderReadEvent::MemberStarted{ordinal,bytes}=>{sequence=0;publish(Event::Member{selection:selection.clone(),ordinal,bytes,finished:false},&events,&stop).await?;},
        FolderReadEvent::MemberFinished{ordinal,bytes}=>publish(Event::Member{selection:selection.clone(),ordinal,bytes,finished:true},&events,&stop).await?,
        FolderReadEvent::Bytes{ordinal,offset,bytes}=>{
            let end=offset.checked_add(bytes.len()as u64).ok_or(Issue::Invalid)?;
            publish(Event::Bytes{selection:selection.clone(),ordinal,sequence,offset,bytes},&events,&stop).await?;
            match command(&mut commands,&stop,5).await?{Command::Ack{token,ordinal:transaction,member,sequence:n,offset:actual}if same(&token,transaction,&selection)&&member==ordinal&&n==sequence&&actual==end=>reader.acknowledge(ordinal,end).map_err(remote)?,_=>return Err(Issue::Invalid)}
            sequence=sequence.checked_add(1).ok_or(Issue::Invalid)?;
        },FolderReadEvent::Complete{bytes,files}=>return Ok(End::Complete{selection,bytes,files}),
    }}
}
pub fn start(selection:Selection,selected:SelectedRow,conn:Connection,tree:TreeId,stop:Stop)->Job{let(tx,commands)=mpsc::channel(1);let(events,rx)=mpsc::channel(1);let task=tokio::spawn(execute(selection,selected,conn,tree,stop,events,commands));Job{commands:tx,events:rx,task}}

pub fn node_text(selection:&Selection,ordinal:usize,node:&FolderNode)->Result<String,Issue>{
    let parent=node.parent.map(|n|n.to_string()).unwrap_or_else(||"-".into());
    let name=match &node.entry{Some(entry)=>entry.name.iter().map(|n|format!("{n:04x}")).collect::<String>(),None=>"-".into()};
    let(kind,attributes,size,allocated,modified,changed,index,volume,links)=if let Some(d)=&node.directory{("d",d.attributes,d.size,d.allocated,d.modified,d.changed,d.index,d.volume,0u32)}else if let Some(f)=&node.file{("f",f.attributes,f.size,f.allocated,f.modified,f.changed,f.index,f.volume_serial,f.links)}else{return Err(Issue::Invalid);};
    Ok(format!("folderNode {} {} {ordinal} {parent} {kind} {attributes} {size} {allocated} {modified} {changed} {index} {volume} {links} {name}",selection.token,selection.ordinal))
}
