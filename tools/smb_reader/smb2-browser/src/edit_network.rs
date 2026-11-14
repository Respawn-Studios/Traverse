//! One original-file Save job. It receives and hashes all bounded edited bytes
//! before opening the remote object, then waits for durable local intent.
use super::{channel::Stop,edit_wire::{Command,Selection},network::remote,wire::Issue};
use sha2::{Digest,Sha256};
use smb2::{client::{Connection,selected_edit::{CheckedOriginalEdit,EditBaseline,EditPreflight},
    selected_download::FileSnapshot},types::TreeId,Error};
use std::{future::Future,sync::{Arc,atomic::AtomicU8},time::Duration};
use tokio::sync::mpsc;

pub enum Event { Need{selection:Selection,sequence:u64,offset:u64,count:u32}, Ready(Selection) }
pub enum End { Complete(Selection,FileSnapshot), Refused(Selection) }
pub struct Job {
    pub commands:mpsc::Sender<Command>,pub events:mpsc::Receiver<Event>,
    pub task:tokio::task::JoinHandle<Result<End,Issue>>,
    pub selection:Selection,pub checkpoint:Arc<AtomicU8>,
}
async fn operation<T>(future:impl Future<Output=Result<T,Error>>,stop:&Stop,seconds:u64)->Result<T,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=future=>value.map_err(remote),
        _=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
async fn event(value:Event,events:&mpsc::Sender<Event>,stop:&Stop)->Result<(),Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=events.send(value)=>value.map_err(|_|Issue::IPC),
        _=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}
}
async fn command(commands:&mut mpsc::Receiver<Command>,stop:&Stop)->Result<Command,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=commands.recv()=>value.ok_or(Issue::IPC),
        _=tokio::time::sleep(Duration::from_secs(30))=>Err(Issue::Deadline)}
}
async fn execute(selection:Selection,selected:Option<super::catalog::SelectedRow>,
    expected:Option<(FileSnapshot,[u8;32])>,conn:Connection,tree:TreeId,
    stop:Stop,events:mpsc::Sender<Event>,mut commands:mpsc::Receiver<Command>,
    checkpoint:Arc<AtomicU8>)->Result<End,Issue>{
    if selection.source.is_none() {
        // Preserve the older current-catalog edit's pre-body refusal order.
        let item=&selected.as_ref().ok_or(Issue::Invalid)?.item;
        if item.object!=0 && item.object!=selection.baseline.index {return Ok(End::Refused(selection));}
    }
    let mut edited=Vec::with_capacity(selection.edited_len as usize);
    let mut sequence=0u64;
    while edited.len()<selection.edited_len as usize {
        let offset=edited.len() as u64;
        let count=(selection.edited_len-offset).min(32768) as u32;
        event(Event::Need{selection:selection.clone(),sequence,offset,count},&events,&stop).await?;
        match command(&mut commands,&stop).await? {
            Command::Data{token,ordinal,sequence:n,offset:at,bytes}
                if token==selection.token && ordinal==selection.ordinal && n==sequence
                    && at==offset && bytes.len()==count as usize=>edited.extend_from_slice(&bytes),
            _=>return Err(Issue::Invalid),
        }
        sequence=sequence.checked_add(1).ok_or(Issue::Invalid)?;
    }
    if Sha256::digest(&edited).as_slice()!=selection.edited || !super::edit_wire::valid_text(&edited){
        return Err(Issue::Invalid);
    }
    let Some(selected)=selected else{return Ok(End::Refused(selection));};
    if selection.source.is_some() && expected.as_ref().is_none_or(|(snapshot,digest)|
        snapshot!=&selection.baseline || digest!=&selection.before){
        return Ok(End::Refused(selection));
    }
    let item=&selected.item;
    // The retained Open row names the same path after later catalog reads.
    // Every Save still rechecks the current remote object and body below.
    if item.object!=0 && item.object!=selection.baseline.index { return Ok(End::Refused(selection)); }
    let mut path=selected.directory;
    if !path.is_empty(){path.push(92);}path.extend_from_slice(&item.wire);
    let baseline=EditBaseline{snapshot:selection.baseline.clone(),digest:selection.before};
    let prepared=operation(CheckedOriginalEdit::prepare(conn,tree,&path,baseline),&stop,60).await?;
    let value=match prepared {
        EditPreflight::Changed=>return Ok(End::Refused(selection)),
        EditPreflight::Ready(value)=>value,
    };
    event(Event::Ready(selection.clone()),&events,&stop).await?;
    match command(&mut commands,&stop).await? {
        Command::Authorize{token,ordinal} if token==selection.token && ordinal==selection.ordinal=>{},
        _=>return Err(Issue::Invalid),
    }
    let after=operation(value.write_and_verify(&edited,&selection.edited,selection.attribute_contract,&checkpoint),&stop,60).await?;
    Ok(End::Complete(selection,after))
}
pub async fn resolve(selection:&Selection,owner:&super::store::Owner,stop:&Stop)->Result<super::catalog::SelectedRow,Issue>{
    let source=super::download_wire::Selection{token:selection.token.clone(),ordinal:selection.ordinal,
        number:selection.number,generation:selection.generation.clone(),revision:selection.revision,
        observation:selection.observation};
    super::download_network::resolve(&source,owner,stop).await
}
pub fn start(selection:Selection,selected:Option<super::catalog::SelectedRow>,
    expected:Option<(FileSnapshot,[u8;32])>,conn:Connection,tree:TreeId,stop:Stop)->Job{
    let (tx,commands)=mpsc::channel(1);let (events,rx)=mpsc::channel(1);
    let checkpoint=Arc::new(AtomicU8::new(0));
    let task=tokio::spawn(execute(selection.clone(),selected,expected,conn,tree,stop,events,commands,Arc::clone(&checkpoint)));
    Job{commands:tx,events:rx,task,selection,checkpoint}
}
