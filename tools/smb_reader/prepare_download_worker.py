"""Exact copied-worker seams; never edits ordinary sources or the frozen core."""
from pathlib import Path
def exact(text,old,new):
    if text.count(old)!=1:raise RuntimeError('Current copied worker seam changed: '+old[:90])
    return text.replace(old,new,1)
def patch(graph):
    root=Path(__file__).resolve().parent
    for name in ['download_wire.rs','download_network.rs']:(graph/'src'/name).write_bytes((root/name).read_bytes())
    (graph.parent/'catalog/selected_catalog.rs').write_bytes((root/'selected_catalog.rs').read_bytes())
    path=graph.parent/'catalog/catalog.rs';path.write_bytes(path.read_bytes()+b'\ninclude!("selected_catalog.rs");\n')
    path=graph/'src/wire.rs';text=path.read_text()
    text=exact(text,'pub enum Command{Read{number:u64,generation:String,path:Vec<u16>},Cancel(u64),Page(Page)}',
        'pub enum Command{Read{number:u64,generation:String,path:Vec<u16>},Cancel(u64),Page(Page),Download(super::download_wire::Command)}')
    text+='''
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
''';path.write_text(text)
    path=graph/'src/main.rs';text=path.read_text()
    text=exact(text,'mod network;','mod network;\nmod download_wire;\nmod download_network;')
    text=exact(text,'struct GuardedSend{transport:Arc<TcpTransport>,plain:',
        'struct GuardedSend{transport:Arc<TcpTransport>,download:Option<Arc<smb2::client::selected_download::SelectedDownloadPolicy>>,plain:')
    text=exact(text,'if !common::permitted_frame(data){','if !self.download.as_ref().map_or_else(||common::permitted_frame(data),|p|p.permits_frame(data)){')
    text=exact(text,'fn from_transport(transport:Arc<TcpTransport>,host:&str)->Connection{',
        '''fn from_transport(transport:Arc<TcpTransport>,host:&str)->Connection{from_transport_policy(transport,host,None)}
fn from_transport_download(transport:Arc<TcpTransport>,host:&str)->Connection{
    from_transport_policy(transport,host,Some(smb2::client::selected_download::SelectedDownloadPolicy::new()))
}
fn from_transport_policy(transport:Arc<TcpTransport>,host:&str,policy:Option<Arc<smb2::client::selected_download::SelectedDownloadPolicy>>)->Connection{''')
    text=exact(text,'Box::new(GuardedSend{transport:transport.clone(),','Box::new(GuardedSend{transport:transport.clone(),download:policy.clone(),')
    text=exact(text,'    conn.set_compression_requested(false);','    if let Some(policy)=policy{conn.set_selected_download_policy(policy).expect("new connection policy");}\n    conn.set_compression_requested(false);')
    text=exact(text,'''    if std::env::args().skip(1).collect::<Vec<_>>()!=["--browser-worker"]{std::process::exit(2);}
    std::process::exit(channel::run());''','''    let args=std::env::args().skip(1).collect::<Vec<_>>();
    if args==["--browser-worker"]{std::process::exit(channel::run());}
    if args==["--selected-download-browser-worker"]{std::process::exit(channel::run_download());}
    std::process::exit(2);''');path.write_text(text)
    path=graph/'src/store.rs';text=path.read_text()
    text=exact(text,'    Page(Page),','    Page(Page),\n    Selected{selection:super::download_wire::Selection,reply:oneshot::Sender<Result<super::catalog::SelectedRow,Issue>>},')
    text=exact(text,'                    Command::Page(request)=>{','''                    Command::Selected{selection,reply}=>{
                        let value=(||{
                            let(n,uuid,snapshot)=current.as_ref().ok_or(Issue::Invalid)?;
                            if *n!=selection.number||uuid!=&selection.generation||snapshot.revision!=selection.revision||snapshot.state!=State::Complete{return Err(Issue::Invalid);}
                            catalog.selected(*snapshot,generation(uuid)?,selection.observation).map_err(issue)
                        })();let _=reply.send(value);
                    },
                    Command::Page(request)=>{''');path.write_text(text)
    path=graph/'src/channel.rs';text=path.read_text()
    text=exact(text,'pub struct Output{stream:OwnedWriteHalf,session:String,sequence:u64,valid:bool}',
        'pub struct Output{stream:OwnedWriteHalf,session:String,sequence:u64,valid:bool,download:bool}')
    start=text.index('    pub async fn event(');end=text.index('    pub async fn publish(',start)
    text=text[:start]+'''    async fn send_owned(&mut self,bytes:Vec<u8>)->Result<(),Issue>{
        if !self.valid{return Err(Issue::IPC);}let next=self.sequence.checked_add(1).ok_or(Issue::Invalid)?;
        self.valid=false;
        tokio::time::timeout(Duration::from_millis(500),self.stream.write_all(&bytes)).await.map_err(|_|Issue::Deadline)?.map_err(|_|Issue::IPC)?;
        self.sequence=next;self.valid=true;Ok(())
    }
    pub async fn event(&mut self,payload:&str)->Result<(),Issue>{
        let magic=if self.download{"MEXSMBD1"}else{"MEXSMBB2"};
        let text=format!("{magic} {} {} {payload}",self.session,self.sequence);
        if text.len()+1>16512{return Err(Issue::Invalid);}
        let bytes=if self.download{super::download_wire::framed(text.as_bytes())?}else{(text+"\\n").into_bytes()};
        self.send_owned(bytes).await
    }
    #[cfg(test)]pub fn qualification(stream:OwnedWriteHalf,session:String,download:bool)->Self{Self{stream,session,sequence:0,valid:true,download}}
    pub async fn download_event(&mut self,event:super::download_network::Event)->Result<(),Issue>{
        if !self.download{return Err(Issue::Invalid);}
        match event{
            super::download_network::Event::Prepared{selection,item}=>{
                let name=item.wire.iter().map(|n|format!("{n:04x}")).collect::<String>();
                self.event(&format!("downloadPrepared {} {} {} {} {} {name}",selection.token,selection.ordinal,item.attributes,item.size,item.modified)).await
            },
            super::download_network::Event::Bytes{selection,sequence,offset,bytes}=>{
                let data=super::download_wire::data(&self.session,self.sequence,&selection.token,selection.ordinal,sequence,offset,&bytes)?;
                self.send_owned(super::download_wire::framed(&data)?).await
            },
        }
    }
'''+text[end:]
    text=exact(text,'async fn execute(stream:UnixStream,files:[File;3])->i32{','async fn execute(stream:UnixStream,files:[File;3],download:bool)->i32{')
    text=exact(text,'wire::hello(&line)','wire::hello_mode(&line,download)')
    text=exact(text,'wire::command(&line)','wire::command_mode(&line,download)')
    text=exact(text,'sequence:0,valid:true};','sequence:0,valid:true,download};')
    text=exact(text,'network::execute(&hello,credentials,&mut output,&mut rx,&mut owner,&stop).await',
        'network::execute_mode(&hello,credentials,&mut output,&mut rx,&mut owner,&stop,download).await')
    text=exact(text,'pub fn run()->i32{','pub fn run()->i32{run_mode(false)}\npub fn run_download()->i32{run_mode(true)}\nfn run_mode(download:bool)->i32{')
    text=exact(text,'execute(stream,files).await','execute(stream,files,download).await');path.write_text(text)
    path=graph/'src/network.rs';text=path.read_text()
    seam='pub async fn execute(hello:&wire::Hello,credentials:wire::Credentials,output:&mut Output,commands:&mut mpsc::Receiver<wire::Command>,owner:&mut store::Owner,stop:&Stop)->Result<(),Issue>{'
    text=exact(text,seam,'''pub async fn execute_mode(hello:&wire::Hello,credentials:wire::Credentials,output:&mut Output,commands:&mut mpsc::Receiver<wire::Command>,owner:&mut store::Owner,stop:&Stop,downloads:bool)->Result<(),Issue>{''')
    text=exact(text,'    let mut conn=from_transport(transport,&hello.host);',
        '    let mut conn=if downloads{super::from_transport_download(transport,&hello.host)}else{from_transport(transport,&hello.host)};')
    text=exact(text,'    let mut next:Option<Request>=None;let mut last_number=0u64;let mut page_pending=false;',
        '''    let mut next:Option<Request>=None;let mut last_number=0u64;let mut page_pending=false;
    let mut download:Option<(mpsc::Sender<super::download_wire::Command>,tokio::task::JoinHandle<Result<super::download_network::End,Issue>>)>=None;
    let mut download_events:Option<mpsc::Receiver<super::download_network::Event>>=None;let mut last_download=0u64;''')
    text=exact(text,'                event=owner.events.recv()=>{','''                event=async{match download_events.as_mut(){Some(events)=>events.recv().await,None=>std::future::pending().await}}=>{
                    match event{Some(event)=>output.download_event(event).await?,None=>download_events=None}
                },
                result=async{match download.as_mut(){Some((_,task))=>task.await,None=>std::future::pending().await}}=>{
                    download.take();
                    if download_events.as_mut().is_some_and(|events|events.try_recv().is_ok()){return Err(Issue::Invalid);}
                    download_events=None;
                    match result.map_err(|_|Issue::Remote)??{
                        super::download_network::End::Complete{selection,bytes}=>output.event(&format!("downloadComplete {} {} {bytes}",selection.token,selection.ordinal)).await?,
                        super::download_network::End::Released(selection)=>output.event(&format!("downloadReleased {} {}",selection.token,selection.ordinal)).await?,
                    }
                },
                event=owner.events.recv()=>{''')
    text=exact(text,'                    wire::Command::Read{number,generation,path}=>{','''                    wire::Command::Download(super::download_wire::Command::Prepare(selection))=>{
                        if !downloads||download.is_some()||active.is_some()||next.is_some()||page_pending||selection.number!=last_number||Some(selection.ordinal)!=last_download.checked_add(1){return Err(Issue::Invalid);}
                        last_download=selection.ordinal;
                        let selected=super::download_network::resolve(&selection,owner,stop).await?;
                        let job=super::download_network::start(selection,selected,conn.clone(),tree.tree_id,stop.clone());
                        download_events=Some(job.events);download=Some((job.commands,job.task));
                    },
                    wire::Command::Download(command)=>{
                        if !downloads{return Err(Issue::Invalid);}let(tx,_)=download.as_ref().ok_or(Issue::Invalid)?;
                        tx.try_send(command).map_err(|_|Issue::Invalid)?;
                    },
                    wire::Command::Read{number,generation,path}=>{
                        if download.is_some(){return Err(Issue::Invalid);}''')
    text=exact(text,'                    wire::Command::Cancel(number)=>{','                    wire::Command::Cancel(number)=>{\n                        if download.is_some(){return Err(Issue::Stop);}')
    text=exact(text,'                    wire::Command::Page(request)=>{','                    wire::Command::Page(request)=>{\n                        if download.is_some(){return Err(Issue::Invalid);}')
    text=exact(text,'    transport_stop.await.map_err(|_|Issue::Close)?;','''    transport_stop.await.map_err(|_|Issue::Close)?;
    download_events.take();
    if let Some((commands,mut task))=download.take(){
        drop(commands);
        if tokio::time::timeout(Duration::from_secs(2),&mut task).await.is_err(){task.abort();let _=task.await;return Err(Issue::Close);}
    }''');path.write_text(text)
