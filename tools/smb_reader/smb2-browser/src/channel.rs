use super::{network,store,wire::{self,Issue}};
use std::{fs::File,os::fd::FromRawFd,sync::{Arc,atomic::{AtomicBool,Ordering}},time::Duration};
use tokio::{io::{AsyncReadExt,AsyncWriteExt,BufReader},net::{UnixStream,unix::{OwnedReadHalf,OwnedWriteHalf}},sync::{mpsc,Notify}};
// Private browser IPC Stop is distinct from both text commands (including
// SIZE_FOLDER) and the upload frame length prefix, which begins with zero.
const STOP_BYTE:u8=1;
fn hex(bytes:&[u8])->String{bytes.iter().map(|b|format!("{b:02x}")).collect()}

#[derive(Clone)]pub struct Stop{pub flag:Arc<AtomicBool>,wake:Arc<Notify>}
impl Stop{
    pub fn new()->Self{Self{flag:Arc::new(AtomicBool::new(false)),wake:Arc::new(Notify::new())}}
    pub fn set(&self){self.flag.store(true,Ordering::Release);self.wake.notify_waiters();}
    pub async fn wait(&self){loop{let wake=self.wake.notified();if self.flag.load(Ordering::Acquire){return;}wake.await;}}
}
async fn line_with_first(input:&mut BufReader<OwnedReadHalf>,mut first:Option<u8>)->Result<String,Issue>{
    let mut bytes=Vec::new();loop{
        let byte=match first.take(){Some(v)=>v,None=>input.read_u8().await.map_err(|_|Issue::IPC)?};
        if bytes.is_empty()&&byte==STOP_BYTE{return Err(Issue::Stop);}
        if byte==b'\n'{return String::from_utf8(bytes).map_err(|_|Issue::Invalid);}
        if bytes.len()==16512||!byte.is_ascii_graphic()&&byte!=b' '{return Err(Issue::Invalid);}bytes.push(byte);
    }
}
async fn line(input:&mut BufReader<OwnedReadHalf>)->Result<String,Issue>{line_with_first(input,None).await}
async fn next(input:&mut BufReader<OwnedReadHalf>,mode:wire::Mode)->Result<wire::Command,Issue>{
    let first=input.read_u8().await.map_err(|_|Issue::IPC)?;
    if first==0&&mode==wire::Mode::Upload{
        let mut extent=[0;3];input.read_exact(&mut extent).await.map_err(|_|Issue::IPC)?;
        let length=u32::from_be_bytes([0,extent[0],extent[1],extent[2]]) as usize;
        if !(74..=super::upload_wire::MAX_FRAME).contains(&length){return Err(Issue::Invalid);}
        let mut body=vec![0;length];input.read_exact(&mut body).await.map_err(|_|Issue::IPC)?;
        return if body.first()==Some(&5) {super::edit_wire::binary(&body).map(wire::Command::Edit)}
            else {super::upload_wire::binary(&body).map(wire::Command::Upload)};
    }
    wire::command_policy(&line_with_first(input,Some(first)).await?,mode)
}
pub struct Output{stream:OwnedWriteHalf,session:String,sequence:u64,valid:bool,mode:wire::Mode}
impl Output{
    async fn send_owned(&mut self,bytes:Vec<u8>)->Result<(),Issue>{
        if !self.valid{return Err(Issue::IPC);}let next=self.sequence.checked_add(1).ok_or(Issue::Invalid)?;
        self.valid=false;
        tokio::time::timeout(Duration::from_millis(500),self.stream.write_all(&bytes)).await.map_err(|_|Issue::Deadline)?.map_err(|_|Issue::IPC)?;
        self.sequence=next;self.valid=true;Ok(())
    }
    pub async fn event(&mut self,payload:&str)->Result<(),Issue>{
        let magic=self.mode.magic();
        let text=format!("{magic} {} {} {payload}",self.session,self.sequence);
        if text.len()+1>16512{return Err(Issue::Invalid);}
        let bytes=if self.mode.framed(){super::folder_wire::framed(text.as_bytes())?}else{(text+"\n").into_bytes()};
        self.send_owned(bytes).await
    }
    #[cfg(test)]pub fn qualification(stream:OwnedWriteHalf,session:String,download:bool)->Self{Self{stream,session,sequence:0,valid:true,mode:if download{wire::Mode::File}else{wire::Mode::Metadata}}}
    pub async fn download_event(&mut self,event:super::download_network::Event)->Result<(),Issue>{
        if !self.mode.framed(){return Err(Issue::Invalid);}
        match event{
            super::download_network::Event::Prepared{selection,item}=>{
                let name=item.wire.iter().map(|n|format!("{n:04x}")).collect::<String>();
                self.event(&format!("downloadPrepared {} {} {} {} {} {name}",selection.token,selection.ordinal,item.attributes,item.size,item.modified)).await
            },
            super::download_network::Event::Bytes{selection,sequence,offset,bytes}=>{
                let data=super::download_wire::data(&self.session,self.sequence,&selection.token,selection.ordinal,sequence,offset,&bytes)?;
                let mut data=data;if self.mode==wire::Mode::Folder{data[1..9].copy_from_slice(super::folder_wire::MAGIC.as_bytes());}
                if self.mode==wire::Mode::Upload{data[1..9].copy_from_slice(super::upload_wire::MAGIC.as_bytes());}
                self.send_owned(super::folder_wire::framed(&data)?).await
            },
        }
    }
    pub async fn folder_event(&mut self,event:super::folder_network::Event)->Result<(),Issue>{
        use super::folder_network::Event;
        if !self.mode.allows_folder(){return Err(Issue::Invalid);}
        match event{
            Event::Node{selection,ordinal,node}=>self.event(&super::folder_network::node_text(&selection,ordinal,&node)?).await,
            Event::Prepared{selection,files,folders,bytes,longest}=>self.event(&format!("folderPrepared {} {} {files} {folders} {bytes} {longest}",selection.token,selection.ordinal)).await,
            Event::Member{selection,ordinal,bytes,finished}=>self.event(&format!("{} {} {} {ordinal} {bytes}",if finished{"folderMemberEnd"}else{"folderMemberBegin"},selection.token,selection.ordinal)).await,
            Event::Bytes{selection,ordinal,sequence,offset,bytes}=>{
                let mut payload=super::folder_wire::data(&self.session,self.sequence,&selection,ordinal,sequence,offset,&bytes)?;
                if self.mode==wire::Mode::Upload{payload[1..9].copy_from_slice(super::upload_wire::MAGIC.as_bytes());}
                self.send_owned(super::folder_wire::framed(&payload)?).await
            },
        }
    }
    pub async fn upload_event(&mut self,event:super::upload_network::Event)->Result<(),Issue>{
        use super::upload_network::Event;
        if self.mode!=wire::Mode::Upload{return Err(Issue::Invalid);}
        match event{
            Event::Ready(s)=>self.event(&format!("uploadReady {} {}",s.token,s.ordinal)).await,
            Event::Need(s,seq,offset,count)=>self.event(&format!("uploadNeed {} {} {seq} {offset} {count}",s.token,s.ordinal)).await,
            Event::Written(s,offset)=>self.event(&format!("uploadWritten {} {} {offset}",s.token,s.ordinal)).await,
            Event::Digest(s)=>self.event(&format!("uploadSourceDigest {} {}",s.token,s.ordinal)).await,
            Event::StageVerified(s,digest)=>self.event(&format!("uploadStageVerified {} {} {}",s.token,s.ordinal,hex(&digest))).await,
            Event::FolderManifestNeed(s,offset,count)=>self.event(&format!("folderUploadManifestNeed {} {} {offset} {count}",s.token,s.ordinal)).await,
            Event::FolderReady(s)=>self.event(&format!("folderUploadReady {} {}",s.token,s.ordinal)).await,
            Event::FolderRootCreated(s)=>self.event(&format!("folderUploadRootCreated {} {}",s.token,s.ordinal)).await,
            Event::FolderNeed(s,node,seq,offset,count)=>self.event(&format!("folderUploadNeed {} {} {node} {seq} {offset} {count}",s.token,s.ordinal)).await,
            Event::FolderDigest(s,node)=>self.event(&format!("folderUploadSourceDigest {} {} {node}",s.token,s.ordinal)).await,
            Event::FolderFileVerified(s,node,files,bytes)=>self.event(&format!("folderUploadFileVerified {} {} {node} {files} {bytes}",s.token,s.ordinal)).await,
            Event::FolderStageVerified(s,digest)=>self.event(&format!("folderUploadStageVerified {} {} {}",s.token,s.ordinal,hex(&digest))).await,
        }
    }
    pub async fn edit_event(&mut self,event:super::edit_network::Event)->Result<(),Issue>{
        if self.mode!=wire::Mode::Upload{return Err(Issue::Invalid);}
        match event{
            super::edit_network::Event::Need{selection,sequence,offset,count}=>
                self.event(&format!("editNeed {} {} {sequence} {offset} {count}",selection.token,selection.ordinal)).await,
            super::edit_network::Event::Ready(selection)=>
                self.event(&format!("editReady {} {}",selection.token,selection.ordinal)).await,
        }
    }
    pub async fn publish(&mut self,event:store::Event)->Result<(),Issue>{
        match event{
            store::Event::Ready=>Ok(()),
            store::Event::Began{number,generation}=>self.event(&format!("began {number} {generation}")).await,
            store::Event::Snapshot{number,generation,value}=>self.event(&format!("snapshot {number} {generation} {} {} {} {}",value.revision,value.count,value.folders,value.state as u8)).await,
            store::Event::Stale{token,number}=>self.event(&format!("stale {token} {number}")).await,
            store::Event::FindResult{token,number,generation,snapshot,count,folders}=>
                self.event(&format!("find {token} {number} {generation} {} {} {} {} {count} {folders}",snapshot.revision,snapshot.count,snapshot.folders,snapshot.state as u8)).await,
            store::Event::FindStale{token,number,generation}=>self.event(&format!("findStale {token} {number} {generation}")).await,
            store::Event::FindUnavailable{token,number}=>self.event(&format!("findUnavailable {token} {number} deadline")).await,
            store::Event::FindPageStale{token,number,find}=>self.event(&format!("findPageStale {token} {number} {find}")).await,
            store::Event::FindPageUnavailable{token,number,find}=>self.event(&format!("findPageUnavailable {token} {number} {find} deadline")).await,
            store::Event::Failed(issue)=>Err(issue),
            store::Event::Page{request,rows}=>{
                let count=rows.len();let deadline=tokio::time::Instant::now()+Duration::from_secs(2);
                for row in rows{
                    if tokio::time::Instant::now()>deadline{return Err(Issue::Deadline);}
                    let wire=row.wire.iter().map(|n|format!("{n:04x}")).collect::<String>();
                    self.event(&format!("row {} {} {} {} {} {} {} {} {wire}",request.token,request.number,
                        row.observation,row.attributes,row.size,row.modified,row.object,row.parent)).await?;
                }
                self.event(&format!("page {} {} {} {} {} {count}",request.token,request.number,request.generation,request.revision,request.offset)).await
            },
            store::Event::FindPage{request,rows,count,folders}=>{
                let find=request.find.as_ref().ok_or(Issue::Invalid)?;
                let returned=rows.len();let deadline=tokio::time::Instant::now()+Duration::from_secs(2);
                for row in rows{
                    if tokio::time::Instant::now()>deadline{return Err(Issue::Deadline);}
                    let wire=row.wire.iter().map(|n|format!("{n:04x}")).collect::<String>();
                    self.event(&format!("findRow {} {} {find} {} {} {} {} {} {} {wire}",request.token,request.number,
                        row.observation,row.attributes,row.size,row.modified,row.object,row.parent)).await?;
                }
                self.event(&format!("findPage {} {} {find} {} {} {} {count} {folders} {returned}",
                    request.token,request.number,request.generation,request.revision,request.offset)).await
            },
        }
    }
}
async fn execute(stream:UnixStream,files:[File;3],mode:wire::Mode)->i32{
    let(read,write)=stream.into_split();let mut input=BufReader::with_capacity(8192,read);
    let hello=match tokio::time::timeout(Duration::from_secs(5),line(&mut input)).await{
        Ok(Ok(line))=>match wire::hello_policy(&line,mode){Ok(value)=>value,Err(_)=>return 2},_=>return 2};
    let credentials=match tokio::time::timeout(Duration::from_secs(5),line(&mut input)).await{
        Ok(Ok(line))=>match wire::credentials(&line){Ok(value)=>value,Err(_)=>return 2},_=>return 2};
    let stop=Stop::new();let input_stop=stop.clone();let(commands,mut rx)=mpsc::channel(4);
    let input_task=tokio::spawn(async move{
        let issue=loop{
            tokio::select!{biased;
                _=input_stop.wait()=>return Issue::Stop,
                value=next(&mut input,mode)=>match value{
                    Ok(command)=>if commands.try_send(command).is_err(){break Issue::Invalid;},
                    Err(e)=>break e,
                }
            }
        };input_stop.set();issue
    });
    let mut output=Output{stream:write,session:hello.session.clone(),sequence:0,valid:true,mode};
    let mut owner=store::Owner::start(hello.store.clone(),files,hello.quota,stop.flag.clone());
    let ready=tokio::select!{_ =stop.wait()=>Err(Issue::Stop),value=owner.events.recv()=>match value{Some(store::Event::Ready)=>Ok(()),Some(store::Event::Failed(e))=>Err(e),_=>Err(Issue::Storage)}};
    let outcome=match ready{Ok(())=>network::execute_policy(&hello,credentials,&mut output,&mut rx,&mut owner,&stop,mode).await,Err(e)=>{let _=output.event(&format!("profile {}",["0";19].join(","))).await;let _=output.event("networkDrained 0 0 0").await;Err(e)}};
    stop.set();let input_issue=input_task.await.unwrap_or(Issue::IPC);
    let catalog_drained=owner.drain().await;
    let reason=if matches!(outcome,Err(Issue::Stop))&&input_issue!=Issue::Stop{input_issue}else{outcome.err().unwrap_or(Issue::Stop)};
    // network::execute emits its actual socket join proof before returning.
    let tasks=tokio::runtime::Handle::current().metrics().num_alive_tasks();
    let terminal=output.event(&format!("closed {} {} {tasks}",reason.name(),u8::from(catalog_drained))).await;
    if catalog_drained&&tasks==0&&terminal.is_ok(){0}else{3}
}
pub fn run()->i32{run_mode(wire::Mode::Metadata)}
pub fn run_download()->i32{run_mode(wire::Mode::File)}
pub fn run_folder()->i32{run_mode(wire::Mode::Folder)}
pub fn run_upload()->i32{run_mode(wire::Mode::Upload)}
fn run_mode(mode:wire::Mode)->i32{
    // Only a private Unix socket at descriptor3 and the exact store descriptors
    // at4/5/6 are admitted. No credentials or paths are taken from the CLI/env.
    unsafe extern "C"{fn fcntl(fd:i32,command:i32,...)->i32;}
    if (3..=6).any(|fd|unsafe{fcntl(fd,1)}<0){return 2;}
    let stream=unsafe{std::os::unix::net::UnixStream::from_raw_fd(3)};
    if stream.peer_addr().is_err()||stream.set_nonblocking(true).is_err(){return 2;}
    let files=unsafe{[File::from_raw_fd(4),File::from_raw_fd(5),File::from_raw_fd(6)]};
    let runtime=match tokio::runtime::Builder::new_current_thread().enable_all().build(){Ok(v)=>v,Err(_)=>return 2};
    runtime.block_on(async{match UnixStream::from_std(stream){Ok(stream)=>execute(stream,files,mode).await,Err(_)=>2}})
}

#[cfg(test)]mod stop_marker_tests{
    use super::*;

    #[tokio::test]
    async fn lone_stop_is_immediate_and_fragmented_size_command_is_parsed(){
        let(parent,worker)=UnixStream::pair().unwrap();
        let(_,mut writer)=parent.into_split();let(reader,_)=worker.into_split();
        let mut input=BufReader::new(reader);
        writer.write_all(&[STOP_BYTE]).await.unwrap();
        assert!(matches!(tokio::time::timeout(Duration::from_millis(100),next(&mut input,wire::Mode::Metadata)).await,
            Ok(Err(Issue::Stop))));

        let(parent,worker)=UnixStream::pair().unwrap();
        let(_,mut writer)=parent.into_split();let(reader,_)=worker.into_split();
        let mut input=BufReader::new(reader);
        let request="77777777-7777-4777-8777-777777777777";
        let read="88888888-8888-4888-8888-888888888888";
        let command=format!("SIZE_FOLDER {request} 1 {read} 7 768 3 1 99\n");
        writer.write_all(b"S").await.unwrap();
        let mut pending=tokio::spawn(async move{next(&mut input,wire::Mode::Metadata).await});
        assert!(tokio::time::timeout(Duration::from_millis(20),&mut pending).await.is_err());
        writer.write_all(&command.as_bytes()[1..]).await.unwrap();
        assert!(matches!(pending.await.unwrap(),Ok(wire::Command::SizeFolder(_))));
    }

    #[tokio::test]
    async fn invalid_s_prefix_is_refused(){
        let(parent,worker)=UnixStream::pair().unwrap();
        let(_,mut writer)=parent.into_split();let(reader,_)=worker.into_split();
        let mut input=BufReader::new(reader);
        writer.write_all(b"SPOOF\n").await.unwrap();
        assert!(matches!(next(&mut input,wire::Mode::Metadata).await,Err(Issue::Invalid)));
    }
}
