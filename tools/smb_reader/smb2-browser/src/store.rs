//! One actual SQLite thread. Nothing here owns or polls a network socket.
use super::{catalog::{Catalog,Error,Find as CatalogFind,Row,Snapshot,State},wire::{generation,Issue,Page,Find}};
use std::{fs::File,os::fd::AsRawFd,sync::{Arc,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
use tokio::sync::{mpsc,oneshot};

pub struct Metadata{pub wire:Vec<u16>,pub attributes:u32,pub size:u64,pub modified:u64,pub object:u64}
pub enum Command{
    Start{number:u64,generation:String,path:Vec<u16>,reply:oneshot::Sender<Result<(),Issue>>},
    Parent{number:u64,index:u64,reply:oneshot::Sender<Result<(),Issue>>},
    Batch{number:u64,rows:Vec<Metadata>,reply:oneshot::Sender<Result<(),Issue>>},
    Finish{number:u64,state:State,reply:oneshot::Sender<Result<(),Issue>>},
    Page(Page),
    Find(Find),
    Selected{selection:super::download_wire::Selection,reply:oneshot::Sender<Result<super::catalog::SelectedRow,Issue>>},
    SelectedFolder{selection:super::download_wire::Selection,reply:oneshot::Sender<Result<super::catalog::SelectedRow,Issue>>},
    SelectedFolderSize{selection:super::wire::FolderSizeSelection,reply:oneshot::Sender<Result<super::catalog::SelectedRow,Issue>>},
    SelectedAction{selection:super::action_wire::Selection,reply:oneshot::Sender<Result<super::catalog::SelectedRow,Issue>>},
    UploadDirectory{number:u64,generation:String,revision:i64,reply:oneshot::Sender<Result<Vec<u16>,Issue>>},
}
pub enum Event{
    Ready,
    Began{number:u64,generation:String},
    Snapshot{number:u64,generation:String,value:Snapshot},
    Page{request:Page,rows:Vec<Row>},
    Stale{token:String,number:u64},
    FindResult{token:String,number:u64,generation:String,snapshot:Snapshot,count:i64,folders:i64},
    FindStale{token:String,number:u64,generation:String},
    FindUnavailable{token:String,number:u64},
    FindPage{request:Page,rows:Vec<Row>,count:i64,folders:i64},
    FindPageStale{token:String,number:u64,find:String},
    FindPageUnavailable{token:String,number:u64,find:String},
    Failed(Issue),
}
pub struct Owner{pub commands:mpsc::Sender<Command>,pub events:mpsc::Receiver<Event>,join:std::thread::JoinHandle<bool>}
impl Owner{
    pub fn start(path:String,files:[File;3],quota:u64,stop:Arc<AtomicBool>)->Self{
        let(commands,mut rx)=mpsc::channel(4);let(tx,events)=mpsc::channel(4);
        let join=std::thread::spawn(move||{
            let [parent,file,lease]=files;
            let mut catalog=match Catalog::create(&path,parent.as_raw_fd(),file.as_raw_fd(),lease.as_raw_fd(),quota,stop.clone(),None){
                Ok(c)=>c,Err(e)=>{let _=send(&tx,Event::Failed(issue(e)),&stop);return false;}
            };
            let mut current:Option<(u64,String,Snapshot)>=None;let mut current_path=Vec::<u16>::new();let mut first_batch=false;let mut failed=false;
            let mut active_find:Option<(String,String,CatalogFind)>=None;
            if send(&tx,Event::Ready,&stop).is_err(){return catalog.drain().is_ok();}
            while !stop.load(Ordering::Acquire){
                let command=match rx.try_recv(){Ok(c)=>c,Err(mpsc::error::TryRecvError::Empty)=>{std::thread::sleep(Duration::from_millis(2));continue;},Err(_)=>break};
                match command{
                    Command::Start{number,generation:uuid,path,reply}=>{
                        active_find=None;
                        let result=(||{
                            if let Some((_,_,previous))=current.as_ref(){catalog.retire(previous.read).map_err(issue)?;}
                            let value=catalog.start(generation(&uuid)?,&path).map_err(issue)?;
                            current_path=path;
                            current=Some((number,uuid.clone(),value));first_batch=true;
                            send(&tx,Event::Began{number,generation:uuid.clone()},&stop)?;
                            send(&tx,Event::Snapshot{number,generation:uuid,value},&stop)
                        })();
                        if let Err(e)=result{let _=send(&tx,Event::Failed(e),&stop);failed=true;}
                        let _=reply.send(result);
                    },
                    Command::Parent{number,index,reply}=>{
                        let result=(||{
                            let(n,_,_)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=number{return Err(Issue::Invalid);}
                            catalog.observe_parent(index).map_err(issue)
                        })();
                        if let Err(e)=result{let _=send(&tx,Event::Failed(e),&stop);failed=true;}
                        let _=reply.send(result);
                    },
                    Command::Batch{number,rows,reply}=>{
                        active_find=None;
                        let result=(||{
                            let (n,uuid,mut snapshot)=current.clone().ok_or(Issue::Invalid)?;
                            let mut published=snapshot;
                            if number!=n||rows.len()>700{return Err(Issue::Invalid);}
                            for row in rows{
                                if catalog.append_with_identity(&row.wire,row.attributes,row.size,row.modified,row.object).map_err(issue)?{
                                    snapshot=catalog.snapshot(snapshot.read).map_err(issue)?;
                                    send(&tx,Event::Snapshot{number:n,generation:uuid.clone(),value:snapshot},&stop)?;
                                    published=snapshot;
                                }
                            }
                            if first_batch{
                                catalog.checkpoint().map_err(issue)?;snapshot=catalog.snapshot(snapshot.read).map_err(issue)?;
                                // A full checkpoint above may already have sent this revision.
                                if published!=snapshot{send(&tx,Event::Snapshot{number:n,generation:uuid.clone(),value:snapshot},&stop)?;}
                                first_batch=false;
                            }
                            current=Some((n,uuid,snapshot));Ok(())
                        })();
                        if let Err(e)=result{let _=send(&tx,Event::Failed(e),&stop);failed=true;}
                        let _=reply.send(result);
                    },
                    Command::Finish{number,state,reply}=>{
                        active_find=None;
                        let result=(||{
                            let(n,uuid,_)=current.clone().ok_or(Issue::Invalid)?;if n!=number{return Err(Issue::Invalid);}
                            let value=catalog.finish(state).map_err(issue)?;current=Some((n,uuid.clone(),value));
                            send(&tx,Event::Snapshot{number:n,generation:uuid,value},&stop)
                        })();
                        if let Err(e)=result{let _=send(&tx,Event::Failed(e),&stop);failed=true;}
                        let _=reply.send(result);
                    },
                    Command::Selected{selection,reply}=>{
                        let value=(||{
                            let(n,uuid,snapshot)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=selection.number||uuid!=&selection.generation||snapshot.revision!=selection.revision||snapshot.state!=State::Complete{return Err(Issue::Invalid);}
                            catalog.selected(*snapshot,generation(uuid)?,selection.observation).map_err(issue)
                        })();let _=reply.send(value);
                    },
                    Command::SelectedFolder{selection,reply}=>{
                        let value=(||{
                            let(n,uuid,snapshot)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=selection.number||uuid!=&selection.generation||snapshot.revision!=selection.revision||snapshot.state!=State::Complete{return Err(Issue::Invalid);}
                            catalog.selected_folder(*snapshot,generation(uuid)?,selection.observation).map_err(issue)
                        })();let _=reply.send(value);
                    },
                    Command::SelectedFolderSize{selection,reply}=>{
                        let value=(||{
                            let(n,uuid,snapshot)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=selection.number||uuid!=&selection.generation||snapshot.revision!=selection.revision||snapshot.count!=selection.count
                                ||snapshot.folders!=selection.folders||snapshot.state!=State::Complete||selection.state!=1{return Err(Issue::Invalid);}
                            catalog.selected_folder(*snapshot,generation(uuid)?,selection.observation).map_err(|error|
                                if error==Error::Stale{Issue::Invalid}else{issue(error)})
                        })();let _=reply.send(value);
                    },
                    Command::SelectedAction{selection,reply}=>{
                        let value=(||{
                            let(n,uuid,snapshot)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=selection.number||uuid!=&selection.generation||snapshot.revision!=selection.revision||snapshot.state!=State::Complete{return Err(Issue::Invalid);}
                            catalog.selected_action(*snapshot,generation(uuid)?,selection.observation,selection.kind.is_directory()).map_err(issue)
                        })();let _=reply.send(value);
                    },
                    Command::UploadDirectory{number,generation,revision,reply}=>{
                        let value=(||{
                            let(n,uuid,snapshot)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=number||uuid!=&generation||snapshot.revision!=revision||snapshot.state!=State::Complete{return Err(Issue::Invalid);}
                            Ok(current_path.clone())
                        })();let _=reply.send(value);
                    },
                    Command::Find(request)=>{
                        active_find=None;
                        let result=(||{
                            let Some((n,uuid,previous))=current.clone() else{
                                return send(&tx,Event::FindStale{token:request.token,number:request.number,generation:request.generation},&stop);
                            };
                            if n!=request.number||uuid!=request.generation{
                                return send(&tx,Event::FindStale{token:request.token,number:request.number,generation:request.generation},&stop);
                            }
                            catalog.checkpoint().map_err(issue)?;
                            let value=catalog.snapshot(previous.read).map_err(issue)?;
                            if previous!=value{current=Some((n,uuid.clone(),value));send(&tx,Event::Snapshot{number:n,generation:uuid.clone(),value},&stop)?;}
                            if value.revision!=request.revision||value.count!=request.count||value.folders!=request.folders||value.state as u8!=request.state{
                                return send(&tx,Event::FindStale{token:request.token,number:n,generation:uuid},&stop);
                            }
                            match catalog.find(value,&request.query){
                                Ok(found)=>{
                                    let count=found.count;let folders=found.folders;
                                    active_find=Some((request.token.clone(),uuid.clone(),found));
                                    send(&tx,Event::FindResult{token:request.token,number:n,generation:uuid,snapshot:value,count,folders},&stop)
                                },
                                Err(Error::Stale)=>send(&tx,Event::FindStale{token:request.token,number:n,generation:uuid},&stop),
                                Err(Error::SQLite(code))if code&255==9&&!stop.load(Ordering::Acquire)=>
                                    send(&tx,Event::FindUnavailable{token:request.token,number:n},&stop),
                                Err(error)=>Err(issue(error)),
                            }
                        })();
                        if let Err(e)=result{let _=send(&tx,Event::Failed(e),&stop);failed=true;}
                    },
                    Command::Page(request)=>{
                        let result=(||{
                            let Some((n,uuid,previous))=current.clone() else{
                                return if let Some(find)=request.find{send(&tx,Event::FindPageStale{token:request.token,number:request.number,find},&stop)}
                                    else{send(&tx,Event::Stale{token:request.token,number:request.number},&stop)};
                            };
                            if n!=request.number||uuid!=request.generation{return if let Some(find)=request.find{
                                send(&tx,Event::FindPageStale{token:request.token,number:request.number,find},&stop)
                            }else{send(&tx,Event::Stale{token:request.token,number:request.number},&stop)};}
                            catalog.checkpoint().map_err(issue)?;
                            let value=catalog.snapshot(previous.read).map_err(issue)?;
                            if previous!=value{active_find=None;current=Some((n,uuid.clone(),value));send(&tx,Event::Snapshot{number:n,generation:uuid.clone(),value},&stop)?;}
                            if let Some(ref find_id)=request.find{
                                if value.revision!=request.revision||active_find.as_ref().is_none_or(|(id,g,found)|id!=find_id||g!=&uuid||found.snapshot!=value){
                                    return send(&tx,Event::FindPageStale{token:request.token,number:n,find:find_id.clone()},&stop);
                                }
                                let found=&active_find.as_ref().ok_or(Issue::Invalid)?.2;
                                return match catalog.find_page(found,request.offset,256,request.sort,request.descending){
                                    Ok(rows)=>send(&tx,Event::FindPage{request,rows,count:found.count,folders:found.folders},&stop),
                                    Err(Error::Stale)=>send(&tx,Event::FindPageStale{token:request.token,number:n,find:find_id.clone()},&stop),
                                    Err(Error::SQLite(code))if code&255==9&&!stop.load(Ordering::Acquire)=>
                                        send(&tx,Event::FindPageUnavailable{token:request.token,number:n,find:find_id.clone()},&stop),
                                    Err(error)=>Err(issue(error)),
                                };
                            }
                            if value.revision!=request.revision{return send(&tx,Event::Stale{token:request.token,number:n},&stop);}
                            let rows=catalog.page(value,request.offset,256,request.sort,request.descending).map_err(issue)?;
                            send(&tx,Event::Page{request,rows},&stop)
                        })();
                        if let Err(e)=result{let _=send(&tx,Event::Failed(e),&stop);failed=true;}
                    },
                }
                if failed{break;}
            }
            // Disable the SQL progress callback for the required rollback/close.
            // Never mark an interrupted catalog complete merely to drain it.
            catalog.drain().is_ok()
        });
        Self{commands,events,join}
    }
    pub async fn drain(mut self)->bool{
        // The caller sets Stop first. Dropping publication wakes a producer
        // waiting on bounded event space; retain the thread through actual join.
        self.events.close();drop(self.commands);
        while !self.join.is_finished(){tokio::time::sleep(Duration::from_millis(2)).await;}
        self.join.join().unwrap_or(false)
    }
}
fn send(tx:&mpsc::Sender<Event>,mut event:Event,stop:&AtomicBool)->Result<(),Issue>{
    let deadline=Instant::now()+Duration::from_secs(2);
    loop{
        if stop.load(Ordering::Acquire){return Err(Issue::Stop);}
        match tx.try_send(event){Ok(())=>return Ok(()),Err(mpsc::error::TrySendError::Full(value))=>event=value,Err(_)=>return Err(Issue::IPC)}
        if Instant::now()>deadline{return Err(Issue::Deadline);}std::thread::sleep(Duration::from_millis(2));
    }
}
fn issue(e:Error)->Issue{match e{Error::SQLite(n)if n&255==13=>Issue::Quota,Error::Stopped=>Issue::Stop,Error::Invalid|Error::Duplicate=>Issue::Invalid,_=>Issue::Storage}}
