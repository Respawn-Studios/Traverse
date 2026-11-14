use super::{action_wire, catalog::State,channel::{Output,Stop},common,from_transport,store,wire::{self,Issue}};
use smb2::{client::{Connection,Session,Tree,selected_action::{CheckedSelectedAction,ListedFile,ItemKind,Action,Outcome,preflight_code}},crypto::encryption::Cipher,transport::TcpTransport,ListOptions};
use std::{future::Future,sync::{Arc,atomic::Ordering},time::Duration};
use tokio::sync::{mpsc,oneshot};

pub fn remote(error:smb2::Error)->Issue{
    use smb2::{Error,types::status::NtStatus};
    match error{
        Error::Protocol{status,..}if status==NtStatus::LOGON_FAILURE=>Issue::Authentication,
        Error::Protocol{status,..}if status==NtStatus::ACCESS_DENIED=>Issue::Denied,
        Error::GuestSessionRefused{..}|Error::SignatureInvalid{..}=>Issue::Security,
        Error::InvalidData{..}=>Issue::Invalid,_=>Issue::Remote,
    }
}
fn encrypt(conn:&mut Connection,session:&Session)->Result<(),Issue>{
    if conn.should_encrypt(){return Ok(());}
    if conn.params().and_then(|p|p.cipher)!=Some(Cipher::Aes128Gcm){return Err(Issue::Security);}
    conn.activate_encryption(session.encryption_key.clone().ok_or(Issue::Security)?,session.decryption_key.clone().ok_or(Issue::Security)?,Cipher::Aes128Gcm);Ok(())
}
async fn operation<T>(future:impl Future<Output=smb2::Result<T>>,stop:&Stop)->Result<T,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=future=>value.map_err(remote),_=tokio::time::sleep(Duration::from_secs(10))=>Err(Issue::Deadline)}
}
async fn store_ack(command:store::Command,reply:oneshot::Receiver<Result<(),Issue>>,store:&mpsc::Sender<store::Command>,stop:&Stop)->Result<(),Issue>{
    tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=store.send(command)=>value.map_err(|_|Issue::Storage)?}
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=reply=>value.map_err(|_|Issue::Storage)?}
}
async fn finish(number:u64,state:State,store:&mpsc::Sender<store::Command>,stop:&Stop)->Result<(),Issue>{
    let(tx,rx)=oneshot::channel();store_ack(store::Command::Finish{number,state,reply:tx},rx,store,stop).await
}
struct Request{number:u64,generation:String,path:Vec<u16>}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
enum Rejection{Denied,Missing,Unavailable}
impl Rejection{fn name(self)->&'static str{match self{Self::Denied=>"denied",Self::Missing=>"missing",Self::Unavailable=>"unavailable"}}}
fn open_rejection(error:&smb2::Error)->Option<Rejection>{
    // Only a failed CREATE response proves that no directory handle was issued.
    // A query error may hide its failed CLOSE in the pinned reader: keep it fatal.
    match error{
        smb2::Error::Protocol{status,command}if *command==smb2::types::Command::Create=>match status.0{
            0xc0000022=>Some(Rejection::Denied),
            0xc000000f|0xc0000034|0xc000003a=>Some(Rejection::Missing),
            0xc0000103=>Some(Rejection::Unavailable),
            _=>None,
        },_=>None,
    }
}
struct End{number:u64,reason:&'static str,rejected:Option<(String,Rejection)>}
async fn read(request:Request,conn:Connection,tree:Tree,store:mpsc::Sender<store::Command>,stop:Stop,cancel:Stop)->Result<End,Issue>{
    let number=request.number;
    // The catalog retains SMB wire separators. This high-level Tree API takes
    // slash-separated paths and encodes a literal backslash as a name character.
    // wire::path rejects both separators inside names, so only separators change.
    let path=String::from_utf16(&request.path).map_err(|_|Issue::Invalid)?.replace('\\',"/");
    let generation=request.generation.clone();
    let(tx,rx)=oneshot::channel();
    store_ack(store::Command::Start{number,generation:request.generation,path:request.path,reply:tx},rx,&store,&stop).await?;
    // Opening cancellation cannot prove whether the server allocated a handle.
    // Close the entire session in that case rather than admitting a later read.
    let opened=tokio::select!{biased;
        _=stop.wait()=>return Err(Issue::Stop),
        _=cancel.wait()=>return Err(Issue::Close),
        value=tree.open_directory_reader_with(conn.clone(),&path,ListOptions::new().index_numbers(true))=>value,
        _=tokio::time::sleep(Duration::from_secs(10))=>return Err(Issue::Deadline),
    };
    let mut reader=match opened{
        Ok(reader)=>reader,
        Err(error)=>{
            if let Some(reason)=open_rejection(&error){
                finish(number,State::Stopped,&store,&stop).await?;
                return Ok(End{number,reason:"rejected",rejected:Some((generation,reason))});
            }
            return Err(remote(error));
        },
    };
    let mut parent_seen=false;
    loop{
        let value=tokio::select!{biased;
            _=stop.wait()=>return Err(Issue::Stop),
            _=cancel.wait()=>{
                tokio::time::timeout(Duration::from_secs(2),reader.close()).await.map_err(|_|Issue::Close)?.map_err(|_|Issue::Close)?;
                finish(number,State::Stopped,&store,&stop).await?;return Ok(End{number,reason:"cancelled",rejected:None});
            },
            value=operation(reader.next_batch(),&stop)=>value,
        };
        let entries=match value{Ok(Some(entries))=>entries,Ok(None)=>{finish(number,State::Complete,&store,&stop).await?;return Ok(End{number,reason:"complete",rejected:None});},Err(e)=>return Err(e)};
        if entries.len()>700{return Err(Issue::Invalid);}
        let mut rows=Vec::with_capacity(entries.len());
        let mut parent_in_batch=None;
        for entry in entries{
            let name=String::from_utf16(&entry.qualification_wire_name).map_err(|_|Issue::Invalid)?;
            if name=="."{
                if parent_seen||parent_in_batch.is_some(){return Err(Issue::Invalid);}
                parent_in_batch=entry.index_number.filter(|value|*value!=u64::MAX);
                parent_seen=true;continue;
            }
            if name==".."{continue;}if !common::permitted_name(&name){return Err(Issue::Invalid);}
            rows.push(store::Metadata{wire:entry.qualification_wire_name,attributes:entry.attributes.bits(),size:entry.size,
                modified:entry.modified.0,object:entry.index_number.filter(|value|*value!=u64::MAX).unwrap_or(0)});
        }
        if let Some(index)=parent_in_batch{
            let(tx,rx)=oneshot::channel();store_ack(store::Command::Parent{number,index,reply:tx},rx,&store,&stop).await?;
        }
        let(tx,rx)=oneshot::channel();store_ack(store::Command::Batch{number,rows,reply:tx},rx,&store,&stop).await?;
    }
}

pub async fn execute_mode(hello:&wire::Hello,credentials:wire::Credentials,output:&mut Output,commands:&mut mpsc::Receiver<wire::Command>,owner:&mut store::Owner,stop:&Stop,downloads:bool)->Result<(),Issue>{execute_policy(hello,credentials,output,commands,owner,stop,if downloads{wire::Mode::File}else{wire::Mode::Metadata}).await}
pub async fn execute_policy(hello:&wire::Hello,credentials:wire::Credentials,output:&mut Output,commands:&mut mpsc::Receiver<wire::Command>,owner:&mut store::Owner,stop:&Stop,mode:wire::Mode)->Result<(),Issue>{
    let downloads=mode.framed();
    let transport=match operation(TcpTransport::connect(hello.destination,Duration::from_secs(10)),stop).await{
        Ok(value)=>Arc::new(value),Err(e)=>{output.event(&format!("profile {}",["0";19].join(","))).await?;output.event("networkDrained 0 0 0").await?;return Err(e);}};
    let mut conn=match mode{wire::Mode::Metadata=>from_transport(transport,&hello.host),wire::Mode::File=>super::from_transport_download(transport,&hello.host),wire::Mode::Folder=>super::from_transport_folder(transport,&hello.host),wire::Mode::Upload=>super::from_transport_upload(transport,&hello.host)};
    // This task can stop the socket while the main owner is publishing a page
    // or awaiting its separate writer. It is joined before the final proof.
    let transport_stop=tokio::spawn({let conn=conn.clone();let stop=stop.clone();async move{stop.wait().await;conn.mark_dead();}});
    let mut active:Option<(u64,Stop,tokio::task::JoinHandle<Result<End,Issue>>)>=None;
    let mut next:Option<Request>=None;let mut last_number=0u64;let mut page_pending=false;
    let mut download:Option<(mpsc::Sender<super::download_wire::Command>,tokio::task::JoinHandle<Result<super::download_network::End,Issue>>,bool)>=None;
    let mut download_events:Option<mpsc::Receiver<super::download_network::Event>>=None;let mut last_download=0u64;
    let mut edit_sources=super::edit_source::Sources::default();
    let mut folder:Option<super::folder_network::Job>=None;let mut folder_events_open=false;
    let mut folder_size:Option<tokio::task::JoinHandle<Result<super::folder_size::End,Issue>>>=None;
    let mut upload:Option<super::upload_network::Job>=None;let mut upload_events_open=false;
    let mut edit:Option<super::edit_network::Job>=None;let mut edit_events_open=false;
    let mut action:Option<(action_wire::Selection,CheckedSelectedAction)>=None;
    let mut action_deadline:Option<tokio::time::Instant>=None;
    let mut last_action_read=0u64;
    let outcome:Result<(),Issue>=async{
        operation(conn.b10_negotiate(hello.encrypted),stop).await?;
        let session=operation(Session::setup(&mut conn,&credentials.account,&credentials.password,&credentials.domain),stop).await?;
        drop(credentials);if !session.should_sign{return Err(Issue::Security);}if hello.encrypted{encrypt(&mut conn,&session)?;}
        let tree=operation(Tree::connect(&mut conn,&hello.share),stop).await?;
        if tree.is_dfs||tree.dfs_origin.is_some(){return Err(Issue::Security);}if tree.encrypt_data{encrypt(&mut conn,&session)?;}
        if mode==wire::Mode::Upload&&!conn.should_encrypt(){return Err(Issue::Security);}
        output.event(if conn.should_encrypt(){"connected encrypted"}else{"connected signed"}).await?;
        loop{
            if active.is_none(){if let Some(request)=next.take(){
                let cancel=Stop::new();let number=request.number;
                active=Some((number,cancel.clone(),tokio::spawn(read(request,conn.clone(),tree.clone(),owner.commands.clone(),stop.clone(),cancel))));
            }}
            let(f_events,f_task)=match folder.as_mut(){Some(job)=>(Some(&mut job.events),Some(&mut job.task)),None=>(None,None)};
            let(u_events,u_task)=match upload.as_mut(){Some(job)=>(Some(&mut job.events),Some(&mut job.task)),None=>(None,None)};
            let(e_events,e_task)=match edit.as_mut(){Some(job)=>(Some(&mut job.events),Some(&mut job.task)),None=>(None,None)};
            tokio::select!{biased;
                _=stop.wait()=>return Err(Issue::Stop),
                _=async{match action_deadline{Some(deadline)=>tokio::time::sleep_until(deadline).await,
                    None=>std::future::pending().await}}=>return Err(Issue::Deadline),
                event=async{match download_events.as_mut(){Some(events)=>events.recv().await,None=>std::future::pending().await}}=>{
                    match event{Some(event)=>output.download_event(event).await?,None=>download_events=None}
                },
                result=async{match download.as_mut(){Some((_,task,_))=>task.await,None=>std::future::pending().await}}=>{
                    let (_,_,retain_source)=download.take().ok_or(Issue::Invalid)?;
                    if download_events.as_mut().is_some_and(|events|events.try_recv().is_ok()){return Err(Issue::Invalid);}
                    download_events=None;
                    match result.map_err(|_|Issue::Remote)??{
                        super::download_network::End::Complete{selection,selected,bytes,snapshot:s,digest}=>{
                            if retain_source {edit_sources.capture(selection.clone(),selected,s.clone(),digest.ok_or(Issue::Invalid)?)?;}
                            output.event(&format!(
                                "downloadComplete {} {} {bytes} {} {} {} {} {} {} {} {} {} {}",
                                selection.token,selection.ordinal,s.size,s.allocated,s.created,s.modified,s.changed,
                                s.attributes,s.links,s.index,s.volume_created,s.volume_serial)).await?
                        },
                        super::download_network::End::Released(selection)=>output.event(&format!("downloadReleased {} {}",selection.token,selection.ordinal)).await?,
                        super::download_network::End::SourceUnavailable(selection)=>output.event(&format!("downloadSourceUnavailable {} {}",selection.token,selection.ordinal)).await?,
                    }
                },
                event=async{match f_events{Some(events)if folder_events_open=>events.recv().await,_=>std::future::pending().await}}=>{
                    if let Some(event)=event{output.folder_event(event).await?;}else{folder_events_open=false;}
                },
                ended=async{match f_task{Some(task)=>task.await,None=>std::future::pending().await}}=>{
                    let mut job=folder.take().ok_or(Issue::Invalid)?;
                    if job.events.try_recv().is_ok(){return Err(Issue::Invalid);}
                    match ended.map_err(|_|Issue::Remote)??{
                        super::folder_network::End::Complete{selection,bytes,files}=>output.event(&format!("folderComplete {} {} {bytes} {files}",selection.token,selection.ordinal)).await?,
                        super::folder_network::End::Released(s)=>output.event(&format!("folderReleased {} {}",s.token,s.ordinal)).await?,
                    }
                },
                ended=async{match folder_size.as_mut(){Some(task)=>task.await,None=>std::future::pending().await}}=>{
                    folder_size=None;
                    match ended.map_err(|_|Issue::Remote)??{
                        super::folder_size::End::Complete(selection,summary)=>output.event(&format!(
                            "folderSize {} {} {} {} {} {} {} {} {} {} {} {}",selection.request,selection.number,
                            selection.generation,selection.revision,selection.count,selection.folders,selection.state,
                            selection.observation,summary.bytes,summary.files,summary.folders,summary.excluded_links)).await?,
                        super::folder_size::End::Unavailable(selection,reason)=>output.event(&format!(
                            "folderSizeUnavailable {} {}",selection.request,reason as u8)).await?,
                    }
                },
                event=async{match u_events{Some(events)if upload_events_open=>events.recv().await,_=>std::future::pending().await}}=>{
                    if let Some(event)=event{output.upload_event(event).await?;}else{upload_events_open=false;}
                },
                ended=async{match u_task{Some(task)=>task.await,None=>std::future::pending().await}}=>{
                    let mut job=upload.take().ok_or(Issue::Invalid)?;
                    let extra_event=job.events.try_recv().is_ok();
                    upload_events_open=false;
                    let outcome=ended.map_err(|_|Issue::Remote)?;
                    let completed=match outcome{
                        Ok(value)=>value,
                        Err(issue)=>{
                            if let (Some(trace),Some((token,ordinal)))=(&job.folder_failure,&job.folder_identity){
                                let value=trace.load(std::sync::atomic::Ordering::Acquire);
                                let stage=value&255;let command=(value>>8)&255;let status=(value>>16)&0xffff_ffff;
                                // Only fixed codes, never a path, name, payload or server message.
                                let _=output.event(&format!("folderUploadFailure {token} {ordinal} {stage} {} {command} {status}",issue.name())).await;
                            }
                            return Err(issue);
                        },
                    };
                    if extra_event{return Err(Issue::Invalid);}
                    match completed{
                        super::upload_network::End::Complete(s,digest)=>output.event(&format!("uploadComplete {} {} {}",s.token,s.ordinal,digest.iter().map(|b|format!("{b:02x}")).collect::<String>())).await?,
                        super::upload_network::End::StageCollision(s)=>output.event(&format!("uploadStageCollision {} {}",s.token,s.ordinal)).await?,
                        super::upload_network::End::FinalCollision(s)=>output.event(&format!("uploadFinalCollision {} {}",s.token,s.ordinal)).await?,
                        super::upload_network::End::FolderComplete(s,digest)=>output.event(&format!("folderUploadComplete {} {} {}",s.token,s.ordinal,digest.iter().map(|b|format!("{b:02x}")).collect::<String>())).await?,
                        super::upload_network::End::FolderStageCollision(s)=>output.event(&format!("folderUploadStageCollision {} {}",s.token,s.ordinal)).await?,
                        super::upload_network::End::FolderFinalCollision(s)=>output.event(&format!("folderUploadFinalCollision {} {}",s.token,s.ordinal)).await?,
                    }
                },
                event=async{match e_events{Some(events)if edit_events_open=>events.recv().await,_=>std::future::pending().await}}=>{
                    if let Some(event)=event{output.edit_event(event).await?;}else{edit_events_open=false;}
                },
                ended=async{match e_task{Some(task)=>task.await,None=>std::future::pending().await}}=>{
                    let mut job=edit.take().ok_or(Issue::Invalid)?;
                    if job.events.try_recv().is_ok(){return Err(Issue::Invalid);}
                    edit_events_open=false;
                    let ended=match ended.map_err(|_|Issue::Remote)? {
                        Ok(value)=>value,
                        Err(error)=>{
                            let checkpoint=job.checkpoint.load(Ordering::Acquire);
                            if (3..=12).contains(&checkpoint) || (15..=29).contains(&checkpoint) {
                                output.event(&format!("editFault {} {} {checkpoint}",
                                    job.selection.token,job.selection.ordinal)).await?;
                            }
                            return Err(error);
                        },
                    };
                    match ended {
                        super::edit_network::End::Refused(s)=>output.event(&format!(
                            "editRefusedChanged {} {}",s.token,s.ordinal)).await?,
                        super::edit_network::End::Complete(s,v)=>{
                            if s.source.is_some(){edit_sources.advance(&s,v.clone())?;}
                            let verb=match s.attribute_contract {
                                smb2::client::selected_edit::EditAttributeContract::ExactV1=>"editComplete",
                                smb2::client::selected_edit::EditAttributeContract::ArchiveWriteV2=>"editCompleteV2",
                                smb2::client::selected_edit::EditAttributeContract::ArchiveWriteCreationApproxV3=>"editCompleteV3",
                            };
                            output.event(&format!(
                                "{verb} {} {} {} {} {} {} {} {} {} {} {} {}",
                                s.token,s.ordinal,v.size,v.allocated,v.created,v.modified,v.changed,
                                v.attributes,v.links,v.index,v.volume_created,v.volume_serial)).await?
                        },
                    }
                },
                event=owner.events.recv()=>{
                    let event=event.ok_or(Issue::Storage)?;
                    if matches!(&event,store::Event::Page{..}|store::Event::Stale{..}|store::Event::FindResult{..}|
                        store::Event::FindStale{..}|store::Event::FindUnavailable{..}|store::Event::FindPage{..}|
                        store::Event::FindPageStale{..}|store::Event::FindPageUnavailable{..}){page_pending=false;}
                    output.publish(event).await?;
                },
                result=async{match active.as_mut(){Some((_,_,task))=>task.await,None=>std::future::pending().await}}=>{
                    // A completed JoinHandle must be taken even on error: it
                    // cannot be polled a second time by whole-session drain.
                    active=None;let ended=result.map_err(|_|Issue::Remote)??;
                    if let Some((generation,reason))=ended.rejected{
                        output.event(&format!("rejected {} {generation} {}",ended.number,reason.name())).await?;
                    }else{output.event(&format!("idle {} {}",ended.number,ended.reason)).await?;}
                },
                command=commands.recv()=>{
                    let command=command.ok_or(Issue::IPC)?;
                    if folder_size.is_some(){return Err(Issue::Invalid);}
                    if action.is_some()&&!matches!(&command,wire::Command::Action(action_wire::Command::Begin{..})){return Err(Issue::Invalid);}
                    if edit.is_some()&&!matches!(&command,wire::Command::Edit(_)){return Err(Issue::Invalid);}
                    match command{
                    wire::Command::SizeFolder(selection)=>{
                        if folder.is_some()||download.is_some()||upload.is_some()
                            ||active.is_some()||next.is_some()||page_pending||selection.number!=last_number{return Err(Issue::Invalid);}
                        match super::folder_size::resolve(&selection,owner,stop).await?{
                            Ok(selected)=>folder_size=Some(super::folder_size::start(selection,selected,conn.clone(),tree.clone())),
                            Err(reason)=>output.event(&format!("folderSizeUnavailable {} {}",selection.request,reason as u8)).await?,
                        }
                    },
                    wire::Command::Action(action_wire::Command::Prepare(selection))=>{
                        if mode!=wire::Mode::Upload||action.is_some()||folder.is_some()||download.is_some()||upload.is_some()
                            ||active.is_some()||next.is_some()||page_pending||selection.number!=last_number
                            ||selection.number<=last_action_read||Some(selection.ordinal)!=last_download.checked_add(1){return Err(Issue::Invalid);}
                        let(tx,rx)=oneshot::channel();
                        owner.commands.send(store::Command::SelectedAction{selection:selection.clone(),reply:tx}).await.map_err(|_|Issue::Storage)?;
                        let selected=tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),
                            value=rx=>value.map_err(|_|Issue::Storage)?,
                            _=tokio::time::sleep(Duration::from_secs(2))=>return Err(Issue::Deadline)}?;
                        if action_wire::case_only_rename(&selection.kind,&selected.item.wire){return Err(Issue::Invalid);}
                        let item=&selected.item;
                        let ready=format!("actionReady {} {} {} {} {} {} {} {}",selection.token,selection.ordinal,
                            item.attributes,item.size,item.modified,item.object,item.parent,
                            item.wire.iter().map(|n|format!("{n:04x}")).collect::<String>());
                        let listed=ListedFile{name:selected.item.wire,attributes:selected.item.attributes,size:selected.item.size,
                            modified:selected.item.modified,object:selected.item.object,parent:selected.item.parent};
                        let prepared=tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),
                            value=async{
                                let kind=if selection.kind.is_directory(){ItemKind::Directory}else{ItemKind::File};
                                match selection.kind.destination_parent(){
                                    Some(parent)if selection.kind.is_copy()=>CheckedSelectedAction::prepare_copy(conn.clone(),tree.tree_id,
                                        &selected.directory,listed,parent).await,
                                    Some(parent)=>CheckedSelectedAction::prepare_move(conn.clone(),tree.tree_id,
                                        &selected.directory,listed,kind,parent).await,
                                    None=>CheckedSelectedAction::prepare(conn.clone(),tree.tree_id,
                                        &selected.directory,listed,kind).await.map(Some),
                                }
                            }=>value,
                            _=tokio::time::sleep(Duration::from_secs(60))=>return Err(Issue::Deadline)};
                        let prepared=match prepared{
                            Ok(Some(value))=>value,
                            Ok(None)=>{
                                last_download=selection.ordinal;
                                output.event(&format!("actionDestinationUnavailable {} {}",selection.token,selection.ordinal)).await?;
                                continue;
                            },
                            Err(error)=>{
                                if let Some(code)=preflight_code(&error){
                                    output.event(&format!("actionRefused {} {} {code}",selection.token,selection.ordinal)).await?;
                                    return Err(Issue::ActionRefused);
                                }
                                return Err(remote(error));
                            },
                        };
                        last_download=selection.ordinal;
                        output.event(&ready).await?;
                        action=Some((selection,prepared));
                        action_deadline=Some(tokio::time::Instant::now()+Duration::from_secs(30));
                    },
                    wire::Command::Action(action_wire::Command::Begin{token,ordinal})=>{
                        let(selection,prepared)=action.take().ok_or(Issue::Invalid)?;
                        if selection.token!=token||selection.ordinal!=ordinal{return Err(Issue::Invalid);}
                        action_deadline=None;
                        if let action_wire::Kind::Copy{parent,name}=selection.kind.clone(){
                            let stage=format!(".traverse-smb-copy-{}.part",token.to_ascii_lowercase())
                                .encode_utf16().collect::<Vec<_>>();
                            let(tx,mut rx)=mpsc::channel(8);let mut checkpoint=0u8;
                            let mut copy=Box::pin(prepared.commit_copy_with_checkpoint(parent,name,stage,&mut checkpoint,&tx));
                            let deadline=tokio::time::sleep(Duration::from_secs(20*60));tokio::pin!(deadline);
                            let result=loop{tokio::select!{biased;
                                _=stop.wait()=>return Err(Issue::Stop),
                                _=&mut deadline=>return Err(Issue::Deadline),
                                value=&mut copy=>break value,
                                event=rx.recv()=>if let Some((done,total))=event{
                                    output.event(&format!("actionProgress {token} {ordinal} {done} {total}")).await?;
                                }else{return Err(Issue::Invalid);},
                            }};
                            drop(copy);drop(tx);
                            while let Ok((done,total))=rx.try_recv(){
                                output.event(&format!("actionProgress {token} {ordinal} {done} {total}")).await?;
                            }
                            let result=match result{Ok(value)=>value,Err(error)=>{
                                if checkpoint>0{output.event(&format!("actionFault {token} {ordinal} {checkpoint}")).await?;}
                                return Err(remote(error));
                            }};
                            match result{
                                Outcome::Confirmed=>{last_action_read=selection.number;
                                    output.event(&format!("actionComplete {token} {ordinal}")).await?;},
                                Outcome::Collision=>output.event(&format!("actionCollision {token} {ordinal}")).await?,
                                Outcome::StageCollision=>output.event(&format!("actionStageCollision {token} {ordinal}")).await?,
                                Outcome::FinalCollision=>output.event(&format!("actionFinalCollision {token} {ordinal}")).await?,
                                _=>return Err(Issue::Invalid),
                            }
                            continue;
                        }
                        let kind=match selection.kind{
                            action_wire::Kind::Rename(name)=>Action::Rename(name),
                            action_wire::Kind::Delete=>Action::Delete,
                            action_wire::Kind::RenameDirectory(name)=>Action::RenameDirectory(name),
                            action_wire::Kind::DeleteEmptyDirectory=>Action::DeleteEmptyDirectory,
                            action_wire::Kind::Move(parent)=>Action::Move(parent),
                            action_wire::Kind::MoveDirectory(parent)=>Action::MoveDirectory(parent),
                            action_wire::Kind::Copy{..}=>return Err(Issue::Invalid),
                        };
                        let move_action=matches!(&kind,Action::Move(_)|Action::MoveDirectory(_));
                        let mut checkpoint=0u8;
                        let result=tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),
                            value=prepared.commit_with_checkpoint(kind,&mut checkpoint)=>value,
                            _=tokio::time::sleep(Duration::from_secs(60))=>return Err(Issue::Deadline)};
                        let result=match result{
                            Ok(value)=>value,
                            Err(error)=>{
                                if move_action&&checkpoint>0{
                                    output.event(&format!("actionFault {token} {ordinal} {checkpoint}")).await?;
                                }
                                return Err(remote(error));
                            },
                        };
                        match result{
                            Outcome::Confirmed=>{last_action_read=selection.number;
                                output.event(&format!("actionComplete {token} {ordinal}")).await?;},
                            Outcome::Collision=>output.event(&format!("actionCollision {token} {ordinal}")).await?,
                            Outcome::NotEmpty=>output.event(&format!("actionNotEmpty {token} {ordinal}")).await?,
                            Outcome::StageCollision|Outcome::FinalCollision=>return Err(Issue::Invalid),
                        }
                    },
                    wire::Command::Folder(super::folder_wire::Command::Prepare(selection))=>{
                        if !mode.allows_folder()||folder.is_some()||download.is_some()||upload.is_some()||active.is_some()||next.is_some()||page_pending||selection.number!=last_number||Some(selection.ordinal)!=last_download.checked_add(1){return Err(Issue::Invalid);}
                        last_download=selection.ordinal;
                        let selected=super::folder_network::resolve(&selection,owner,stop).await?;
                        folder=Some(super::folder_network::start(selection,selected,conn.clone(),tree.tree_id,stop.clone()));folder_events_open=true;
                    },
                    wire::Command::Folder(command)=>{
                        if !mode.allows_folder()||upload.is_some(){return Err(Issue::Invalid);}folder.as_ref().ok_or(Issue::Invalid)?.commands.try_send(command).map_err(|_|Issue::Invalid)?;
                    },
                    wire::Command::Download(command @ (super::download_wire::Command::Prepare(_)
                        |super::download_wire::Command::PrepareEditOpen(_,_,_)))=>{
                        let (selection,expected_identity)=match command{
                            super::download_wire::Command::Prepare(s)=>(s,None),
                            super::download_wire::Command::PrepareEditOpen(s,object,parent)=>(s,Some((object,parent))),
                            _=>unreachable!(),
                        };
                        let retain_source=expected_identity.is_some();
                        if !downloads||folder.is_some()||download.is_some()||upload.is_some()||active.is_some()||next.is_some()||page_pending||selection.number!=last_number||Some(selection.ordinal)!=last_download.checked_add(1){return Err(Issue::Invalid);}
                        last_download=selection.ordinal;
                        if retain_source{
                            if mode!=wire::Mode::Upload{return Err(Issue::Invalid);}
                            if !edit_sources.can_open(&selection.token){
                                output.event(&format!("downloadSourceFull {} {}",selection.token,selection.ordinal)).await?;
                                continue;
                            }
                        }
                        let selected=super::download_network::resolve(&selection,owner,stop).await?;
                        if expected_identity.is_some_and(|(object,parent)|
                            selected.item.object!=object || selected.item.parent!=parent){
                            output.event(&format!("downloadSourceUnavailable {} {}",selection.token,selection.ordinal)).await?;
                            continue;
                        }
                        let job=super::download_network::start(selection,selected,retain_source,conn.clone(),tree.tree_id,stop.clone());
                        download_events=Some(job.events);download=Some((job.commands,job.task,retain_source));
                    },
                    wire::Command::Download(super::download_wire::Command::ReleaseEditSource(token))=>{
                        if mode!=wire::Mode::Upload||edit.is_some(){return Err(Issue::Invalid);}
                        edit_sources.release(&token);
                        output.event(&format!("editSourceReleased {token}")).await?;
                    },
                    wire::Command::Download(command)=>{
                        if !downloads||folder.is_some()||upload.is_some(){return Err(Issue::Invalid);}let(tx,_,_)=download.as_ref().ok_or(Issue::Invalid)?;
                        tx.try_send(command).map_err(|_|Issue::Invalid)?;
                    },
                    wire::Command::Upload(super::upload_wire::Command::Prepare(selection))=>{
                        if mode!=wire::Mode::Upload||upload.is_some()||folder.is_some()||download.is_some()||active.is_some()||next.is_some()||page_pending||selection.number!=last_number||Some(selection.ordinal)!=last_download.checked_add(1){return Err(Issue::Invalid);}
                        last_download=selection.ordinal;
                        let parent=super::upload_network::resolve(&selection,owner,stop).await?;
                        upload=Some(super::upload_network::start(selection,parent,conn.clone(),tree.tree_id,stop.clone()));upload_events_open=true;
                    },
                    wire::Command::Upload(super::upload_wire::Command::PrepareFolder(selection))=>{
                        if mode!=wire::Mode::Upload||upload.is_some()||folder.is_some()||download.is_some()||active.is_some()||next.is_some()||page_pending||selection.number!=last_number||Some(selection.ordinal)!=last_download.checked_add(1){return Err(Issue::Invalid);}
                        last_download=selection.ordinal;
                        let parent=super::folder_upload_network::resolve(&selection,owner,stop).await?;
                        upload=Some(super::folder_upload_network::start(selection,parent,conn.clone(),tree.tree_id,stop.clone()));upload_events_open=true;
                    },
                    wire::Command::Upload(command)=>{
                        if mode!=wire::Mode::Upload||folder.is_some()||download.is_some(){return Err(Issue::Invalid);}
                        upload.as_ref().ok_or(Issue::Invalid)?.commands.try_send(command).map_err(|_|Issue::Invalid)?;
                    },
                    wire::Command::Edit(super::edit_wire::Command::Prepare(selection))=>{
                        if mode!=wire::Mode::Upload||edit.is_some()||action.is_some()||upload.is_some()||folder.is_some()
                            ||download.is_some()||active.is_some()||next.is_some()||page_pending
                            ||selection.number!=last_number||Some(selection.ordinal)!=last_download.checked_add(1){
                            return Err(Issue::Invalid);
                        }
                        last_download=selection.ordinal;
                        let (selected,expected)=if selection.source.is_some(){
                            match edit_sources.get(&selection){
                                Some(source)=>(Some(source.row),Some((source.baseline,source.digest))),
                                None=>(None,None),
                            }
                        }else{(Some(super::edit_network::resolve(&selection,owner,stop).await?),None)};
                        edit=Some(super::edit_network::start(selection,selected,expected,conn.clone(),tree.tree_id,stop.clone()));
                        edit_events_open=true;
                    },
                    wire::Command::Edit(command)=>{
                        if mode!=wire::Mode::Upload{return Err(Issue::Invalid);}
                        edit.as_ref().ok_or(Issue::Invalid)?.commands.try_send(command).map_err(|_|Issue::Invalid)?;
                    },
                    wire::Command::Read{number,generation,path}=>{
                        if download.is_some()||folder.is_some()||upload.is_some(){return Err(Issue::Invalid);}
                        if Some(number)!=last_number.checked_add(1)||next.is_some(){return Err(Issue::Invalid);}
                        last_number=number;next=Some(Request{number,generation,path});
                        if let Some((_,cancel,_))=active.as_ref(){cancel.set();}
                    },
                    wire::Command::Cancel(number)=>{
                        if download.is_some()||folder.is_some()||upload.is_some(){return Err(Issue::Stop);}
                        if number==0||number>last_number{return Err(Issue::Invalid);}
                        if let Some(request)=next.as_ref(){if request.number==number{next=None;output.event(&format!("idle {number} cancelled")).await?;}}
                        if let Some((n,cancel,_))=active.as_ref(){if *n==number{cancel.set();}}
                    },
                    wire::Command::Page(request)=>{
                        if download.is_some()||folder.is_some()||upload.is_some(){return Err(Issue::Invalid);}
                        if page_pending||request.number==0||request.number>last_number{return Err(Issue::Invalid);}
                        owner.commands.try_send(store::Command::Page(request)).map_err(|_|Issue::Storage)?;page_pending=true;
                    },
                    wire::Command::Find(request)=>{
                        if download.is_some()||folder.is_some()||upload.is_some(){return Err(Issue::Invalid);}
                        if page_pending||request.number==0||request.number>last_number{return Err(Issue::Invalid);}
                        owner.commands.try_send(store::Command::Find(request)).map_err(|_|Issue::Storage)?;page_pending=true;
                    },
                    }
                }
            }
        }
    }.await;
    // First stop transport and wake directory futures; retain every owner until
    // actual joins. A timeout does not fabricate a network-drained event.
    conn.mark_dead();stop.set();drop(action.take());
    transport_stop.await.map_err(|_|Issue::Close)?;
    if let Some(mut job)=folder.take(){
        drop(job.commands);drop(job.events);
        if tokio::time::timeout(Duration::from_secs(2),&mut job.task).await.is_err(){job.task.abort();let _=job.task.await;return Err(Issue::Close);}
    }
    if let Some(mut task)=folder_size.take(){
        if tokio::time::timeout(Duration::from_secs(2),&mut task).await.is_err(){task.abort();let _=task.await;return Err(Issue::Close);}
    }
    if let Some(mut job)=upload.take(){
        drop(job.commands);drop(job.events);
        if tokio::time::timeout(Duration::from_secs(2),&mut job.task).await.is_err(){job.task.abort();let _=job.task.await;return Err(Issue::Close);}
    }
    if let Some(mut job)=edit.take(){
        drop(job.commands);drop(job.events);
        if tokio::time::timeout(Duration::from_secs(2),&mut job.task).await.is_err(){job.task.abort();let _=job.task.await;return Err(Issue::Close);}
    }
    download_events.take();
    if let Some((commands,mut task,_))=download.take(){
        drop(commands);
        if tokio::time::timeout(Duration::from_secs(2),&mut task).await.is_err(){task.abort();let _=task.await;return Err(Issue::Close);}
    }
    if let Some((_,cancel,task))=active.take(){cancel.set();if tokio::time::timeout(Duration::from_secs(2),task).await.is_err(){return Err(Issue::Close);}}
    let joined=tokio::time::timeout(Duration::from_secs(2),conn.qualification_stop_and_join()).await.map_err(|_|Issue::Close)?.map_err(|_|Issue::Close)?;
    let pending=conn.outstanding_requests().len();let profile=conn.b10_command_counts().iter().map(|n|n.to_string()).collect::<Vec<_>>().join(",");drop(conn);tokio::task::yield_now().await;
    // The IPC task may still be finishing; channel.rs joins it separately.
    let remaining=tokio::runtime::Handle::current().metrics().num_alive_tasks();
    output.event(&format!("profile {profile}")).await?;
    output.event(&format!("networkDrained {joined} {pending} {remaining}")).await?;
    if joined!=4||pending!=0||remaining>1{return Err(Issue::Close);}outcome
}

#[cfg(test)]mod tests{
    use super::*;
    use smb2::{crypto::signing::{self,SigningAlgorithm},types::SessionId};
    use tokio::{io::{AsyncReadExt,AsyncWriteExt},net::{TcpListener,TcpStream}};
    async fn receive(socket:&mut TcpStream)->Vec<u8>{
        let n=socket.read_u32().await.unwrap()as usize;assert!((64..=common::FRAME_CAP).contains(&n));
        let mut bytes=vec![0;n];socket.read_exact(&mut bytes).await.unwrap();assert!(common::permitted_frame(&bytes));bytes
    }
    async fn send(socket:&mut TcpStream,bytes:&[u8]){socket.write_u32(bytes.len()as u32).await.unwrap();socket.write_all(bytes).await.unwrap();}
    fn header(request:&[u8],length:usize)->Vec<u8>{
        let mut bytes=vec![0;length];bytes[..4].copy_from_slice(b"\xfeSMB");bytes[4]=64;
        bytes[12..14].copy_from_slice(&request[12..14]);bytes[14]=16;bytes[16]=1;
        bytes[24..32].copy_from_slice(&request[24..32]);bytes[36..48].copy_from_slice(&request[36..48]);bytes
    }
    fn negotiation(request:&[u8])->Vec<u8>{
        let mut bytes=header(request,128);bytes[64]=65;bytes[66]=3;bytes[68..70].copy_from_slice(&0x0311u16.to_le_bytes());bytes[70]=2;
        for offset in [92,96,100]{bytes[offset..offset+4].copy_from_slice(&65536u32.to_le_bytes());}bytes[124]=128;
        bytes.extend([1,0,6,0,0,0,0,0,1,0,0,0,1,0,0,0]);bytes.extend([2,0,4,0,0,0,0,0,1,0,2,0]);bytes
    }
    async fn signed(socket:&mut TcpStream,request:&[u8],mut bytes:Vec<u8>){
        signing::verify_signature(request,&[3;16],SigningAlgorithm::AesCmac,u64::from_le_bytes(request[24..32].try_into().unwrap()),false).unwrap();
        bytes[16]|=8;signing::sign_message(&mut bytes,&[3;16],SigningAlgorithm::AesCmac,u64::from_le_bytes(request[24..32].try_into().unwrap()),false).unwrap();send(socket,&bytes).await;
    }
    async fn connection(port:u16)->Connection{
        let transport=Arc::new(TcpTransport::connect(format!("127.0.0.1:{port}"),Duration::from_secs(1)).await.unwrap());
        let mut conn=from_transport(transport,"generated.invalid");conn.b10_negotiate(false).await.unwrap();
        conn.set_session_id(SessionId(42));conn.activate_signing(vec![3;16],SigningAlgorithm::AesCmac);conn
    }
    async fn peer(listener:TcpListener,cancel_query:Option<oneshot::Sender<()>>,release:Option<oneshot::Receiver<()>>,reads:usize){
        let(mut socket,_)=listener.accept().await.unwrap();let request=receive(&mut socket).await;send(&mut socket,&negotiation(&request)).await;
        let request=receive(&mut socket).await;assert_eq!(request[12],3);
        let mut response=header(&request,80);response[36]=7;response[64]=16;response[66]=1;signed(&mut socket,&request,response).await;
        let mut cancel_query=cancel_query;let mut release=release;
        for _ in 0..reads{
            let request=receive(&mut socket).await;assert_eq!(request[12],5);
            let mut response=header(&request,152);response[64]=89;response[120]=16;response[128]=11;response[136]=12;
            signed(&mut socket,&request,response).await;
            let request=receive(&mut socket).await;assert_eq!(request[12],14);
            if let Some(tx)=cancel_query.take(){let _=tx.send(());release.take().unwrap().await.unwrap();}
            // A genuine NO_MORE_FILES still requires the client's CLOSE.
            let mut response=header(&request,72);response[8..12].copy_from_slice(&0x80000006u32.to_le_bytes());response[64]=9;
            signed(&mut socket,&request,response).await;
            let request=receive(&mut socket).await;assert_eq!(request[12],6);
            let mut response=header(&request,124);response[64]=60;signed(&mut socket,&request,response).await;
        }
        let mut byte=[0];assert_eq!(socket.read(&mut byte).await.unwrap(),0);
    }
    async fn consume_events(mut events:mpsc::Receiver<store::Event>)->usize{
        let mut complete=0;
        while let Some(event)=events.recv().await{match event{store::Event::Snapshot{value,..}if value.state!=State::Loading=>complete+=1,store::Event::Failed(_)=>panic!("Actual store failed"),_=>{}}}
        complete
    }
    fn status_reply(request:&[u8],status:u32)->Vec<u8>{
        let mut response=header(request,72);response[8..12].copy_from_slice(&status.to_le_bytes());response[64]=9;response
    }
    async fn open_failure_peer(listener:TcpListener,statuses:Vec<u32>,query_failure:bool){
        let(mut socket,_)=listener.accept().await.unwrap();let request=receive(&mut socket).await;send(&mut socket,&negotiation(&request)).await;
        let request=receive(&mut socket).await;assert_eq!(request[12],3);
        let mut response=header(&request,80);response[36]=7;response[64]=16;response[66]=1;signed(&mut socket,&request,response).await;
        for status in statuses{
            let request=receive(&mut socket).await;assert_eq!(request[12],5);
            signed(&mut socket,&request,status_reply(&request,status)).await;
        }
        // A refused open must not send a CLOSE for a handle it never received.
        let request=receive(&mut socket).await;assert_eq!(request[12],5);
        let name_offset=u16::from_le_bytes(request[108..110].try_into().unwrap())as usize;
        let name_length=u16::from_le_bytes(request[110..112].try_into().unwrap())as usize;
        let expected=if query_failure{""}else{"Cut\\OccupiedParent"};
        let expected=expected.encode_utf16().flat_map(u16::to_le_bytes).collect::<Vec<_>>();
        assert_eq!(&request[name_offset..name_offset+name_length],expected.as_slice());
        let mut response=header(&request,152);response[64]=89;response[120]=16;response[128]=11;response[136]=12;
        signed(&mut socket,&request,response).await;
        let request=receive(&mut socket).await;assert_eq!(request[12],14);
        signed(&mut socket,&request,status_reply(&request,if query_failure{0xc0000022}else{0x80000006})).await;
        let request=receive(&mut socket).await;assert_eq!(request[12],6);
        if query_failure{signed(&mut socket,&request,status_reply(&request,0xc0000001)).await;}
        else{let mut response=header(&request,124);response[64]=60;signed(&mut socket,&request,response).await;}
        let mut byte=[0];assert_eq!(socket.read(&mut byte).await.unwrap(),0);
    }
    #[test]fn only_closed_known_create_statuses_are_recoverable(){
        use smb2::types::{Command,status::NtStatus};
        for code in [0xc0000022,0xc000000f,0xc0000034,0xc000003a,0xc0000103]{
            assert!(open_rejection(&smb2::Error::Protocol{status:NtStatus(code),command:Command::Create}).is_some());
            for command in [Command::QueryDirectory,Command::Close,Command::SessionSetup,Command::TreeConnect]{
                assert_eq!(open_rejection(&smb2::Error::Protocol{status:NtStatus(code),command}),None);
            }
        }
        for code in [0xc000006d,0xc000020c,0xc00000cc,0xc0000257,0,0x80000006]{
            assert_eq!(open_rejection(&smb2::Error::Protocol{status:NtStatus(code),command:Command::Create}),None);
        }
        assert_eq!(open_rejection(&smb2::Error::invalid_data("Generated malformed reply")),None);
    }
    #[tokio::test(flavor="current_thread")]
    async fn five_signed_open_refusals_keep_one_socket_and_allow_a_real_nested_next_read(){
        let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();let port=listener.local_addr().unwrap().port();
        let statuses=vec![0xc0000022,0xc000000f,0xc0000034,0xc000003a,0xc0000103];
        let peer=tokio::spawn(open_failure_peer(listener,statuses.clone(),false));
        let mut conn=connection(port).await;let tree=Tree::connect(&mut conn,"Shared").await.unwrap();
        let(path,files)=crate::tests::fixture("refused-wire-open");let stop=Stop::new();let mut owner=store::Owner::start(path,files,2<<20,stop.flag.clone());
        let(_tx,placeholder)=mpsc::channel(1);let events=std::mem::replace(&mut owner.events,placeholder);let consume=tokio::spawn(consume_events(events));
        for number in 1..=6u64{
            let generation=format!("77777777-7777-4777-8777-{number:012X}");
            let path=if number==6{wire::path("004300750074,004f00630063007500700069006500640050006100720065006e0074").unwrap()}else{vec![]};
            let request=Request{number,generation:generation.clone(),path};
            let ended=read(request,conn.clone(),tree.clone(),owner.commands.clone(),stop.clone(),Stop::new()).await.unwrap();
            if number<=5{
                let expected=if number==1{Rejection::Denied}else if number==5{Rejection::Unavailable}else{Rejection::Missing};
                assert_eq!(ended.rejected,Some((generation,expected)));assert_eq!(ended.reason,"rejected");
            }else{assert!(ended.rejected.is_none());assert_eq!(ended.reason,"complete");}
        }
        let counts=conn.b10_command_counts();assert_eq!(counts[5],6);assert_eq!(counts[6],1);assert_eq!(counts[14],1);
        conn.mark_dead();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);assert!(conn.outstanding_requests().is_empty());
        stop.set();assert!(owner.drain().await);assert_eq!(consume.await.unwrap(),6);drop(conn);peer.await.unwrap();
    }
    #[tokio::test(flavor="current_thread")]
    async fn query_denial_with_failed_close_is_terminal_even_when_the_reader_reports_denial(){
        let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();let port=listener.local_addr().unwrap().port();
        let peer=tokio::spawn(open_failure_peer(listener,vec![],true));
        let mut conn=connection(port).await;let tree=Tree::connect(&mut conn,"Shared").await.unwrap();
        let(path,files)=crate::tests::fixture("denied-query-failed-close");let stop=Stop::new();let mut owner=store::Owner::start(path,files,2<<20,stop.flag.clone());
        let(_tx,placeholder)=mpsc::channel(1);let events=std::mem::replace(&mut owner.events,placeholder);let consume=tokio::spawn(consume_events(events));
        let request=Request{number:1,generation:"77777777-7777-4777-8777-777777777777".into(),path:vec![]};
        assert!(matches!(read(request,conn.clone(),tree,owner.commands.clone(),stop.clone(),Stop::new()).await,Err(Issue::Denied)));
        conn.mark_dead();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);stop.set();assert!(owner.drain().await);
        assert_eq!(consume.await.unwrap(),0);drop(conn);peer.await.unwrap();
    }
    async fn non_directory_open(close_failure:bool){
        let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();let port=listener.local_addr().unwrap().port();
        let peer=tokio::spawn(async move{
            let(mut socket,_)=listener.accept().await.unwrap();let request=receive(&mut socket).await;send(&mut socket,&negotiation(&request)).await;
            let request=receive(&mut socket).await;assert_eq!(request[12],3);
            let mut response=header(&request,80);response[36]=7;response[64]=16;response[66]=1;signed(&mut socket,&request,response).await;
            let request=receive(&mut socket).await;assert_eq!(request[12],5);
            // A successful CREATE with regular-file attributes did issue a
            // handle. The pinned helper reports InvalidData after trying CLOSE;
            // neither that error nor a suppressed CLOSE failure is a refusal.
            let mut response=header(&request,152);response[64]=89;response[120]=32;response[128]=11;response[136]=12;
            signed(&mut socket,&request,response).await;
            let request=receive(&mut socket).await;assert_eq!(request[12],6);
            if close_failure{signed(&mut socket,&request,status_reply(&request,0xc0000001)).await;}
            else{let mut response=header(&request,124);response[64]=60;signed(&mut socket,&request,response).await;}
            let mut byte=[0];assert_eq!(socket.read(&mut byte).await.unwrap(),0);
        });
        let mut conn=connection(port).await;let tree=Tree::connect(&mut conn,"Shared").await.unwrap();
        let(path,files)=crate::tests::fixture(if close_failure{"non-directory-failed-close"}else{"non-directory-closed"});
        let stop=Stop::new();let mut owner=store::Owner::start(path,files,2<<20,stop.flag.clone());
        let(_tx,placeholder)=mpsc::channel(1);let events=std::mem::replace(&mut owner.events,placeholder);let consume=tokio::spawn(consume_events(events));
        let request=Request{number:1,generation:"77777777-7777-4777-8777-777777777777".into(),path:vec![]};
        assert!(matches!(read(request,conn.clone(),tree,owner.commands.clone(),stop.clone(),Stop::new()).await,Err(Issue::Invalid)));
        let counts=conn.b10_command_counts();assert_eq!(counts[5],1);assert_eq!(counts[6],1);assert_eq!(counts[14],0);
        conn.mark_dead();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);stop.set();assert!(owner.drain().await);
        assert_eq!(consume.await.unwrap(),0);drop(conn);peer.await.unwrap();
    }
    #[tokio::test(flavor="current_thread")]
    async fn successful_non_directory_open_is_terminal_even_after_close(){non_directory_open(false).await;}
    #[tokio::test(flavor="current_thread")]
    async fn successful_non_directory_open_cannot_hide_failed_close_as_rejection(){non_directory_open(true).await;}
    #[tokio::test(flavor="current_thread")]
    async fn seventy_actual_signed_directory_handles_close_before_reuse(){
        let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();let port=listener.local_addr().unwrap().port();let peer=tokio::spawn(peer(listener,None,None,70));
        let mut conn=connection(port).await;let tree=Tree::connect(&mut conn,"Shared").await.unwrap();
        let(path,files)=crate::tests::fixture("seventy-wire-reads");let stop=Stop::new();let mut owner=store::Owner::start(path,files,2<<20,stop.flag.clone());
        let(_tx,placeholder)=mpsc::channel(1);let events=std::mem::replace(&mut owner.events,placeholder);let consume=tokio::spawn(consume_events(events));
        for number in 1..=70{
            let request=Request{number,generation:format!("77777777-7777-4777-8777-{number:012X}"),path:vec![]};
            let ended=read(request,conn.clone(),tree.clone(),owner.commands.clone(),stop.clone(),Stop::new()).await.unwrap();assert_eq!(ended.reason,"complete");
        }
        conn.mark_dead();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);assert!(conn.outstanding_requests().is_empty());
        stop.set();assert!(owner.drain().await);assert_eq!(consume.await.unwrap(),70);drop(conn);peer.await.unwrap();
    }
    #[tokio::test(flavor="current_thread")]
    async fn cancel_inflight_query_waits_for_real_close_and_then_allows_next_read(){
        let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();let port=listener.local_addr().unwrap().port();
        let(query_tx,query_rx)=oneshot::channel();let(release_tx,release_rx)=oneshot::channel();let peer=tokio::spawn(peer(listener,Some(query_tx),Some(release_rx),2));
        let mut conn=connection(port).await;let tree=Tree::connect(&mut conn,"Shared").await.unwrap();
        let(path,files)=crate::tests::fixture("cancel-wire-query");let stop=Stop::new();let mut owner=store::Owner::start(path,files,2<<20,stop.flag.clone());
        let(_tx,placeholder)=mpsc::channel(1);let events=std::mem::replace(&mut owner.events,placeholder);let consume=tokio::spawn(consume_events(events));
        let cancel=Stop::new();let request=Request{number:1,generation:"77777777-7777-4777-8777-777777777771".into(),path:vec![]};
        let task=tokio::spawn(read(request,conn.clone(),tree.clone(),owner.commands.clone(),stop.clone(),cancel.clone()));
        query_rx.await.unwrap();cancel.set();tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(!task.is_finished());release_tx.send(()).unwrap();assert_eq!(task.await.unwrap().unwrap().reason,"cancelled");
        let next=Request{number:2,generation:"77777777-7777-4777-8777-777777777772".into(),path:vec![]};
        assert_eq!(read(next,conn.clone(),tree,owner.commands.clone(),stop.clone(),Stop::new()).await.unwrap().reason,"complete");
        conn.mark_dead();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);stop.set();assert!(owner.drain().await);assert_eq!(consume.await.unwrap(),2);drop(conn);peer.await.unwrap();
    }
}
