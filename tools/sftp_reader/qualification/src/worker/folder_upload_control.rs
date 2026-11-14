//! Serial H exchange, bound to the already verified session and listing. Parent
//! metadata/body requests name only the admitted request/node, never a local URL.
use super::*;
use crate::{folder_upload as tree,upload::Failure as U};
struct Source<'a>{output:&'a mut Output,input:&'a mut mpsc::Receiver<Command>,request:[u8;16],files:u32,bytes:u64}
impl tree::Source for Source<'_>{
    async fn bytes(&mut self,node:u32,offset:u64,count:usize)->Result<Vec<u8>,U>{
        let mut value=self.request.to_vec();value.extend(node.to_be_bytes());value.extend(offset.to_be_bytes());value.extend((count as u32).to_be_bytes());
        self.output.event(162,&value).await.map_err(upload_local_issue)?;
        let Some(Command::FolderSourceBytes{request,node:actual,offset:at,mut bytes})=self.input.recv().await else{return Err(U::Protocol)};
        if request!=self.request||actual!=node||at!=offset||bytes.len()!=count{return Err(U::SourceChanged)}Ok(std::mem::take(&mut*bytes))
    }
    async fn permit_file(&mut self,node:u32,digest:[u8;32])->Result<(),U>{
        let mut value=self.request.to_vec();value.extend(node.to_be_bytes());value.extend(digest);self.output.event(163,&value).await.map_err(upload_local_issue)?;
        match self.input.recv().await{Some(Command::FolderFilePermit{request,node:actual,digest:value})if request==self.request&&actual==node&&value==digest=>Ok(()),_=>Err(U::SourceChanged)}
    }
    async fn root_created(&mut self)->Result<(),U>{
        self.output.event(164,&self.request).await.map_err(upload_local_issue)?;
        match self.input.recv().await{Some(Command::FolderRootAcknowledged{request})if request==self.request=>Ok(()),_=>Err(U::SourceChanged)}
    }
    async fn verified(&mut self,node:u32,files:u32,bytes:u64)->Result<(),U>{
        let mut value=self.request.to_vec();value.extend(node.to_be_bytes());value.extend(files.to_be_bytes());value.extend(bytes.to_be_bytes());self.output.event(165,&value).await.map_err(upload_local_issue)?;
        match self.input.recv().await{Some(Command::FolderProgressAcknowledged{request,node:actual,files:count,bytes:size})if request==self.request&&actual==node&&files==count&&bytes==size=>Ok(()),_=>Err(U::SourceChanged)}
    }
    async fn finish(&mut self,digest:[u8;32])->Result<(),U>{
        let mut value=self.request.to_vec();value.extend(self.files.to_be_bytes());value.extend(self.bytes.to_be_bytes());value.extend(digest);self.output.event(166,&value).await.map_err(upload_local_issue)?;
        match self.input.recv().await{Some(Command::FolderFinalPermit{request,digest:value})if request==self.request&&value==digest=>Ok(()),_=>Err(U::SourceChanged)}
    }
}
async fn metadata(output:&mut Output,input:&mut mpsc::Receiver<Command>,request:[u8;16],length:u32,digest:[u8;32])->Result<tree::Manifest,Issue>{
    let mut value=Vec::with_capacity(length as usize);
    while value.len()<length as usize{
        let count=(length as usize-value.len()).min(32768);let mut payload=request.to_vec();payload.extend((value.len()as u32).to_be_bytes());payload.extend((count as u32).to_be_bytes());output.event(161,&payload).await?;
        match input.recv().await{
            Some(Command::FolderManifestBytes{request:actual,offset,bytes})if actual==request&&offset as usize==value.len()&&bytes.len()==count=>value.extend(&*bytes),
            _=>return Err(Issue::Invalid),
        }
    }
    let manifest=tree::Manifest::decode(&value).map_err(|_|Issue::Invalid)?;
    if manifest.digest!=digest{return Err(Issue::Invalid)}Ok(manifest)
}
pub(super) async fn run(ssh:&mut Verified,output:&mut Output,input:&mut mpsc::Receiver<Command>,stop:&Stop,directory:&str,
    request:[u8;16],generation:[u8;16],name:String,length:u32,digest:[u8;32],files:u32,folders:u32,bytes:u64)->Result<(),Issue>{
    let target=crate::upload::Target::new(directory,&name,request).map_err(|_|Issue::Invalid)?;let(_,root)=target.paths_for_intent();
    let mut payload=request.to_vec();payload.extend(generation);payload.extend(length.to_be_bytes());payload.extend(digest);payload.extend(files.to_be_bytes());payload.extend(folders.to_be_bytes());payload.extend(bytes.to_be_bytes());ipc::field(&mut payload,root.as_bytes()).map_err(|_|Issue::Invalid)?;output.event(160,&payload).await?;
    let manifest=guarded(stop,async{tokio::time::timeout(Duration::from_secs(30),metadata(output,input,request,length,digest)).await.map_err(|_|Issue::Deadline)?}).await?;
    if (manifest.files,manifest.folders,manifest.bytes)!=(files,folders,bytes){return Err(Issue::Invalid)}
    let source=Source{output,input,request,files,bytes};
    match ssh.send_upload_folder(directory,&name,request,&manifest,source,crate::upload::Limits::default(),Some(stop.catalog.clone())).await{
        Ok(receipt)=>{
            let mut payload=request.to_vec();payload.extend(receipt.files.to_be_bytes());payload.extend(receipt.bytes.to_be_bytes());payload.extend(receipt.digest);payload.extend([1,1,1]);output.event(167,&payload).await
        },
        Err(mut error)=>{
            let first=stop.reason.load(Ordering::SeqCst);if first!=255{error.cause=upload_local_issue(issue(first))}
            let cause=match error.cause{U::Input=>0,U::Io=>1,U::Timeout=>2,U::Stopped=>3,U::Truncated=>4,U::Protocol=>5,U::Status(_)=>6,U::Conflict=>7,U::UnsupportedSync=>8,U::Verification=>9,U::SourceChanged=>10};
            let status=if let U::Status(v)=error.cause{v}else{0};
            let mut payload=request.to_vec();payload.extend(error.node.to_be_bytes());payload.extend([cause,error.phase,u8::from(error.root_may_exist),u8::from(error.root_acknowledged)]);payload.extend(error.verified_files.to_be_bytes());payload.extend(error.verified_bytes.to_be_bytes());payload.extend(status.to_be_bytes());let _=output.event(168,&payload).await;
            Err(match error.cause{U::Stopped=>Issue::Stopped,U::Timeout=>Issue::Deadline,U::SourceChanged=>Issue::SourceChanged,U::Input|U::Protocol=>Issue::Invalid,U::Status(3)=>Issue::Denied,_=>Issue::Transport})
        }
    }
}
