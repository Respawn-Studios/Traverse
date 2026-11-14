//! F2: one bounded manifest, one private sibling root, checked child files,
//! and one no-replace root publication on the existing encrypted connection.
use super::{channel::Stop,network::remote,store,upload_network::{End,Event,Job},
    upload_wire::{self,Command,FolderSelection},wire::Issue};
use sha2::{Digest,Sha256};
use smb2::{client::{Connection,selected_folder_upload::{CheckedStagedFolder,DirectoryHandle,FolderIdentity,FolderPublication},
    selected_folder_download::{FolderNode,PreparedFolder,FolderReadEvent},selected_upload::CheckedStagedUpload},
    types::{Command as SMBCommand,TreeId,status::NtStatus},Error};
use std::{collections::{HashMap,HashSet},future::Future,sync::{Arc,atomic::{AtomicU64,Ordering}},time::Duration};
use tokio::sync::{mpsc,oneshot};

#[derive(Clone)]
struct Node { directory:bool, parts:Vec<Vec<u16>>, size:u64 }
struct Manifest { raw:Vec<u8>, nodes:Vec<Node> }
fn take<'a>(bytes:&'a[u8],cursor:&mut usize,count:usize)->Result<&'a[u8],Issue>{
    let end=cursor.checked_add(count).ok_or(Issue::Invalid)?;
    let value=bytes.get(*cursor..end).ok_or(Issue::Invalid)?;*cursor=end;Ok(value)
}
fn decode(bytes:Vec<u8>,s:&FolderSelection)->Result<Manifest,Issue>{
    if bytes.len()!=s.manifest_len||bytes.get(..8)!=Some(b"TRVFUP01")
        ||Sha256::digest(&bytes).as_slice()!=s.manifest_digest{return Err(Issue::Invalid);}
    let mut at=8;let count=u32::from_be_bytes(take(&bytes,&mut at,4)?.try_into().unwrap()) as usize;
    if count==0||count>2048{return Err(Issue::Invalid);}
    let mut nodes=Vec::with_capacity(count);let mut parents=HashSet::<Vec<Vec<u8>>>::new();
    let mut previous:Option<Vec<Vec<u8>>>=None;let(mut files,mut folders,mut total)=(0usize,0usize,0u64);
    let parent_len=s.parent.len()+usize::from(!s.parent.is_empty());
    for index in 0..count {
        let header=take(&bytes,&mut at,10)?;let kind=header[0];let depth=header[1] as usize;
        let size=u64::from_be_bytes(header[2..10].try_into().unwrap());
        if !matches!(kind,1|2)||depth>32||(index==0)!= (depth==0)||index==0&&kind!=1
            ||kind==1&&size!=0{return Err(Issue::Invalid);}
        let mut raw_parts=Vec::with_capacity(depth);let mut parts=Vec::with_capacity(depth);
        for _ in 0..depth {
            let length=u16::from_be_bytes(take(&bytes,&mut at,2)?.try_into().unwrap()) as usize;
            if !(1..=255).contains(&length){return Err(Issue::Invalid);}
            let raw=take(&bytes,&mut at,length)?.to_vec();
            let text=String::from_utf8(raw.clone()).map_err(|_|Issue::Invalid)?;
            if text.as_bytes()!=raw||text.to_ascii_lowercase().starts_with(".traverse-smb-upload-"){
                return Err(Issue::Invalid);
            }
            let utf16=text.encode_utf16().collect::<Vec<_>>();
            if !upload_wire::safe_upload_component(&utf16){return Err(Issue::Invalid);}
            raw_parts.push(raw);parts.push(utf16);
        }
        if previous.as_ref().is_some_and(|old|*old>=raw_parts)
            ||index>0&&!parents.contains(&raw_parts[..depth-1].to_vec()){return Err(Issue::Invalid);}
        let suffix=parts.iter().map(|v|1+v.len()).sum::<usize>();
        if parent_len+s.stage.len()+suffix>2048||parent_len+s.name.len()+suffix>2048{return Err(Issue::Invalid);}
        if kind==1 {parents.insert(raw_parts.clone());if index>0{folders+=1;}}
        else {files+=1;total=total.checked_add(size).filter(|n|*n<=1<<30).ok_or(Issue::Invalid)?;}
        nodes.push(Node{directory:kind==1,parts,size});previous=Some(raw_parts);
    }
    if at!=bytes.len()||files!=s.files||folders!=s.folders||total!=s.size||nodes.len()!=1+files+folders{
        return Err(Issue::Invalid);
    }
    Ok(Manifest{raw:bytes,nodes})
}
fn joined(parent:&[u16],child:&[u16])->Vec<u16>{
    let mut out=parent.to_vec();if !out.is_empty(){out.push(92);}out.extend_from_slice(child);out
}
fn same(token:&str,ordinal:u64,s:&FolderSelection)->bool{token==s.token&&ordinal==s.ordinal}
// Only fixed phase/command/status numbers cross the private diagnostic seam.
// No component, body, account, or server-provided text is stored here.
fn phase(trace:&AtomicU64,number:u8){trace.store(u64::from(number)|(255u64<<8),Ordering::Release)}
fn protocol_failure(trace:&AtomicU64,error:&Error){
    if let Error::Protocol{status,command}=error{
        let stage=trace.load(Ordering::Acquire)&255;
        trace.store(stage|((*command as u16 as u64)<<8)|((status.0 as u64)<<16),Ordering::Release);
    }
}
async fn send(event:Event,output:&mpsc::Sender<Event>,stop:&Stop)->Result<(),Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=output.send(event)=>value.map_err(|_|Issue::IPC),
        _=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}
}
async fn receive(input:&mut mpsc::Receiver<Command>,stop:&Stop,seconds:u64)->Result<Command,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=input.recv()=>value.ok_or(Issue::IPC),
        _=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
async fn operation<T>(future:impl Future<Output=smb2::Result<T>>,stop:&Stop,seconds:u64,trace:&AtomicU64)->Result<T,Issue>{
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=future=>value.map_err(|error|{protocol_failure(trace,&error);remote(error)}),
        _=tokio::time::sleep(Duration::from_secs(seconds))=>Err(Issue::Deadline)}
}
pub async fn resolve(s:&FolderSelection,owner:&store::Owner,stop:&Stop)->Result<Vec<u16>,Issue>{
    let(tx,rx)=oneshot::channel();
    let query=store::Command::UploadDirectory{number:s.number,generation:s.generation.clone(),revision:s.revision,reply:tx};
    tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),value=owner.commands.send(query)=>value.map_err(|_|Issue::Storage)?}
    let path=tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),value=rx=>value.map_err(|_|Issue::Storage)?,
        _=tokio::time::sleep(Duration::from_secs(2))=>Err(Issue::Deadline)}?;
    if path!=s.parent{return Err(Issue::Invalid);}Ok(path)
}
fn map_nodes(nodes:&[FolderNode],manifest:&Manifest)->Result<Vec<usize>,Issue>{
    if nodes.len()!=manifest.nodes.len(){return Err(Issue::Invalid);}
    let mut expected=HashMap::<Vec<Vec<u16>>,usize>::new();
    for(i,node)in manifest.nodes.iter().enumerate(){if expected.insert(node.parts.clone(),i).is_some(){return Err(Issue::Invalid);}}
    let mut paths=Vec::<Vec<Vec<u16>>>::with_capacity(nodes.len());let mut mapping=Vec::new();let mut seen=HashSet::new();
    for(i,node)in nodes.iter().enumerate(){
        let parts=if i==0{vec![]}else{
            let parent=node.parent.ok_or(Issue::Invalid)?;if parent>=i{return Err(Issue::Invalid);}
            let mut value=paths[parent].clone();value.push(node.entry.as_ref().ok_or(Issue::Invalid)?.name.clone());value
        };
        let wanted=*expected.get(&parts).ok_or(Issue::Invalid)?;let source=&manifest.nodes[wanted];
        if !seen.insert(wanted)||source.directory!=node.is_directory()
            ||!source.directory&&node.file.as_ref().is_none_or(|file|file.size!=source.size){return Err(Issue::Invalid);}
        paths.push(parts);mapping.push(wanted);
    }
    if seen.len()!=manifest.nodes.len(){return Err(Issue::Invalid);}
    Ok(mapping)
}
async fn verify_final(conn:Connection,tree:TreeId,path:&[u16],manifest:&Manifest,digests:&[Option<[u8;32]>],
    identity:FolderIdentity,stop:&Stop,trace:&AtomicU64)->Result<(),Issue>{
    let mut reader=operation(PreparedFolder::prepare_published(conn,tree,path),stop,90,trace).await?;
    if reader.root_identity()!=Some((identity.volume,identity.index))
        ||reader.files()!=digests.iter().filter(|v|v.is_some()).count()
        ||reader.logical_bytes()!=manifest.nodes.iter().map(|n|n.size).sum::<u64>(){return Err(Issue::Invalid);}
    let mapping=map_nodes(reader.nodes(),manifest)?;
    operation(reader.begin(),stop,90,trace).await?;
    let mut active:Option<(usize,Sha256)>=None;let mut completed=0usize;
    loop {match operation(reader.next(),stop,90,trace).await? {
        FolderReadEvent::MemberStarted{ordinal,bytes}=>{
            let node=*mapping.get(ordinal).ok_or(Issue::Invalid)?;
            if active.is_some()||manifest.nodes[node].directory||bytes!=manifest.nodes[node].size{return Err(Issue::Invalid);}
            active=Some((node,Sha256::new()));
        },
        FolderReadEvent::Bytes{ordinal,offset,bytes}=>{
            let node=*mapping.get(ordinal).ok_or(Issue::Invalid)?;
            let Some((held,hash))=active.as_mut()else{return Err(Issue::Invalid)};
            if *held!=node||bytes.is_empty(){return Err(Issue::Invalid);}hash.update(&bytes);
            reader.acknowledge(ordinal,offset+bytes.len() as u64).map_err(remote)?;
        },
        FolderReadEvent::MemberFinished{ordinal,bytes}=>{
            let node=*mapping.get(ordinal).ok_or(Issue::Invalid)?;
            let Some((held,hash))=active.take()else{return Err(Issue::Invalid)};
            if held!=node||bytes!=manifest.nodes[node].size||digests[node].as_ref().is_none_or(|v|hash.finalize().as_slice()!=v){return Err(Issue::Invalid);}
            completed+=1;
        },
        FolderReadEvent::Complete{bytes,files}=>{
            if active.is_some()||files!=completed||files!=reader.files()||bytes!=reader.logical_bytes(){return Err(Issue::Invalid);}
            return Ok(());
        },
    }}
}
async fn execute(s:FolderSelection,parent:Vec<u16>,conn:Connection,tree:TreeId,stop:Stop,
    events:mpsc::Sender<Event>,mut commands:mpsc::Receiver<Command>,trace:&AtomicU64)->Result<End,Issue>{
    phase(trace,1);
    let mut encoded=Vec::with_capacity(s.manifest_len);
    while encoded.len()<s.manifest_len {
        let offset=encoded.len();let count=(s.manifest_len-offset).min(32768);
        send(Event::FolderManifestNeed(s.clone(),offset as u64,count as u32),&events,&stop).await?;
        match receive(&mut commands,&stop,30).await?{
            Command::FolderManifest{token,ordinal,offset:at,bytes} if same(&token,ordinal,&s)
                &&at==offset as u64&&bytes.len()==count=>encoded.extend(bytes),_=>return Err(Issue::Invalid),
        }
    }
    let manifest=decode(encoded,&s)?;
    send(Event::FolderReady(s.clone()),&events,&stop).await?;
    match receive(&mut commands,&stop,30).await?{Command::BeginFolder{token,ordinal}if same(&token,ordinal,&s)=>{},_=>return Err(Issue::Invalid)}
    phase(trace,2);
    let opened=tokio::select!{biased;_=stop.wait()=>return Err(Issue::Stop),
        value=CheckedStagedFolder::create(conn.clone(),tree,&parent,&s.stage,&s.name)=>value,
        _=tokio::time::sleep(Duration::from_secs(10))=>return Err(Issue::Deadline)};
    let folder=match opened{
        Ok(folder)=>folder,
        Err(Error::Protocol{status,command})if status==NtStatus::OBJECT_NAME_COLLISION&&command==SMBCommand::Create=>return Ok(End::FolderStageCollision(s)),
        Err(error)=>{protocol_failure(trace,&error);return Err(remote(error))},
    };
    phase(trace,3);
    send(Event::FolderRootCreated(s.clone()),&events,&stop).await?;
    match receive(&mut commands,&stop,30).await?{Command::FolderRootAck{token,ordinal}if same(&token,ordinal,&s)=>{},_=>return Err(Issue::Invalid)}
    let mut open=Vec::<(Vec<Vec<u16>>,DirectoryHandle)>::new();let mut digests=vec![None;manifest.nodes.len()];
    let(mut files,mut bytes)=(0usize,0u64);
    for(index,node)in manifest.nodes.iter().enumerate().skip(1){
        let depth=node.parts.len();if depth==0{return Err(Issue::Invalid);}
        phase(trace,4);
        while open.len()>depth-1{let(_,handle)=open.pop().ok_or(Issue::Invalid)?;operation(folder.close_child(handle),&stop,10,trace).await?;}
        let parent_handle=if let Some((parts,handle))=open.last(){
            if parts.as_slice()!=&node.parts[..depth-1]{return Err(Issue::Invalid);}handle
        }else{if depth!=1{return Err(Issue::Invalid);}folder.root().map_err(remote)?};
        let name=node.parts.last().ok_or(Issue::Invalid)?;
        if node.directory{
            let handle=operation(folder.create_child(parent_handle,name),&stop,10,trace).await?;
            open.push((node.parts.clone(),handle));continue;
        }
        phase(trace,5);
        let path=folder.path(parent_handle);
        let mut upload=operation(CheckedStagedUpload::create_private_child(conn.clone(),tree,&path,name,node.size),&stop,10,trace).await?;
        let mut sequence=0u64;let mut source_hash=Sha256::new();
        while upload.written()<node.size{
            let offset=upload.written();let count=(node.size-offset).min(upload.maximum_chunk().map_err(remote)? as u64) as u32;
            send(Event::FolderNeed(s.clone(),index as u32,sequence,offset,count),&events,&stop).await?;
            let chunk=match receive(&mut commands,&stop,30).await?{
                Command::FolderData{token,ordinal,node:actual,sequence:seq,offset:at,bytes:chunk}
                    if same(&token,ordinal,&s)&&actual==index as u32&&seq==sequence&&at==offset&&chunk.len()==count as usize=>chunk,
                _=>return Err(Issue::Invalid),
            };
            source_hash.update(&chunk);operation(upload.write_chunk(chunk),&stop,10,trace).await?;
            sequence=sequence.checked_add(1).ok_or(Issue::Invalid)?;
        }
        send(Event::FolderDigest(s.clone(),index as u32),&events,&stop).await?;
        let digest=match receive(&mut commands,&stop,30).await?{
            Command::FolderFileDigest{token,ordinal,node:actual,digest}if same(&token,ordinal,&s)&&actual==index as u32=>digest,
            _=>return Err(Issue::Invalid),
        };
        if source_hash.finalize().as_slice()!=digest{return Err(Issue::Invalid);}
        phase(trace,6);
        operation(upload.flush(),&stop,10,trace).await?;
        let stage=operation(upload.verify_stage(&digest),&stop,300,trace).await?;
        operation(upload.finish_private_child(stage,&digest),&stop,300,trace).await?;
        digests[index]=Some(digest);files+=1;bytes=bytes.checked_add(node.size).ok_or(Issue::Invalid)?;
        phase(trace,7);
        send(Event::FolderFileVerified(s.clone(),index as u32,files,bytes),&events,&stop).await?;
        match receive(&mut commands,&stop,30).await?{
            Command::FolderFileAck{token,ordinal,node:actual,files:confirmed,bytes:amount}
                if same(&token,ordinal,&s)&&actual==index as u32&&confirmed==files&&amount==bytes=>{},_=>return Err(Issue::Invalid),
        }
    }
    phase(trace,4);
    while let Some((_,handle))=open.pop(){operation(folder.close_child(handle),&stop,10,trace).await?;}
    if files!=s.files||bytes!=s.size{return Err(Issue::Invalid);}
    phase(trace,8);
    let stage_nodes=operation(folder.inspect_stage(),&stop,180,trace).await?;
    let _=map_nodes(&stage_nodes,&manifest)?;
    let mut tree_hash=Sha256::new();tree_hash.update(&manifest.raw);
    for digest in digests.iter().flatten(){tree_hash.update(digest);}
    let digest:[u8;32]=tree_hash.finalize().into();
    phase(trace,9);
    send(Event::FolderStageVerified(s.clone(),digest),&events,&stop).await?;
    match receive(&mut commands,&stop,30).await?{
        Command::CommitFolder{token,ordinal,digest:reported}if same(&token,ordinal,&s)&&reported==digest=>{},_=>return Err(Issue::Invalid),
    }
    phase(trace,9);
    let identity=match operation(folder.publish(),&stop,60,trace).await?{
        FolderPublication::FinalCollision=>return Ok(End::FolderFinalCollision(s)),
        FolderPublication::Complete(identity)=>identity,
    };
    let final_path=joined(&parent,&s.name);
    phase(trace,10);
    tokio::select!{biased;_=stop.wait()=>Err(Issue::Stop),
        result=verify_final(conn,tree,&final_path,&manifest,&digests,identity,&stop,trace)=>result,
        _=tokio::time::sleep(Duration::from_secs(1800))=>Err(Issue::Deadline)}?;
    Ok(End::FolderComplete(s,digest))
}
pub fn start(s:FolderSelection,parent:Vec<u16>,conn:Connection,tree:TreeId,stop:Stop)->Job{
    let(tx,commands)=mpsc::channel(1);let(events,rx)=mpsc::channel(1);
    let trace=Arc::new(AtomicU64::new(0));let held=Arc::clone(&trace);
    let identity=(s.token.clone(),s.ordinal);
    let task=tokio::spawn(async move{execute(s,parent,conn,tree,stop,events,commands,&held).await});
    Job{commands:tx,events:rx,task,folder_failure:Some(trace),folder_identity:Some(identity)}
}
#[cfg(test)]mod tests{
    use super::*;
    use smb2::client::{selected_download::FileSnapshot,
        selected_folder_download::{DirectorySnapshot,FolderEntry}};
    #[test]fn failure_trace_has_only_fixed_phase_command_and_status(){
        let trace=AtomicU64::new(0);phase(&trace,4);
        assert_eq!(trace.load(Ordering::Acquire),4|(255<<8));
        protocol_failure(&trace,&Error::Protocol{status:NtStatus::ACCESS_DENIED,command:SMBCommand::Create});
        let value=trace.load(Ordering::Acquire);
        assert_eq!(value&255,4);assert_eq!((value>>8)&255,5);
        assert_eq!((value>>16)&0xffff_ffff,NtStatus::ACCESS_DENIED.0 as u64);
        phase(&trace,5);assert_eq!(trace.load(Ordering::Acquire),5|(255<<8));
    }
    #[test]fn sealed_manifest_refuses_truncated_escape_and_unlisted_members(){
        let mut raw=b"TRVFUP01".to_vec();raw.extend(2u32.to_be_bytes());
        raw.extend([1,0]);raw.extend(0u64.to_be_bytes());
        raw.extend([2,1]);raw.extend(3u64.to_be_bytes());
        raw.extend(8u16.to_be_bytes());raw.extend(b"File.bin");
        let digest:[u8;32]=Sha256::digest(&raw).into();
        let s=FolderSelection{token:"77777777-7777-4777-8777-777777777777".into(),ordinal:1,number:2,
            generation:"88888888-8888-4888-8888-888888888888".into(),revision:3,parent:vec![],
            name:"Tree".encode_utf16().collect(),stage:".traverse-smb-upload-77777777777747778777777777777777.part".encode_utf16().collect(),
            files:1,folders:0,size:3,manifest_len:raw.len(),manifest_digest:digest};
        assert_eq!(decode(raw.clone(),&s).unwrap().nodes.len(),2);
        let mut cut=raw.clone();cut.pop();assert!(decode(cut,&s).is_err());
        let mut reserved=raw.clone();reserved[12]=2;
        let mut altered=s.clone();altered.manifest_digest=Sha256::digest(&reserved).into();
        assert!(decode(reserved,&altered).is_err());
        let mut extra=s.clone();extra.files=2;assert!(decode(raw,&extra).is_err());
    }
    #[test]fn folder_upload_stage_probe_requires_exact_membership_kind_and_size(){
        let directory=DirectorySnapshot{size:0,allocated:0,modified:1,changed:1,
            attributes:0x10,index:1,volume:1};
        let file=FileSnapshot{size:3,allocated:4096,created:1,modified:1,changed:1,
            attributes:0x80,links:1,index:2,volume_created:1,volume_serial:1};
        let root=FolderNode{parent:None,entry:None,directory:Some(directory.clone()),file:None};
        let member=FolderNode{parent:Some(0),entry:Some(FolderEntry{
            name:"File.bin".encode_utf16().collect(),attributes:0x80,size:3,allocated:4096,
            modified:1,changed:1,index:2}),directory:None,file:Some(file.clone())};
        let manifest=Manifest{raw:vec![],nodes:vec![
            Node{directory:true,parts:vec![],size:0},
            Node{directory:false,parts:vec!["File.bin".encode_utf16().collect()],size:3},
        ]};
        assert_eq!(map_nodes(&[root.clone(),member.clone()],&manifest).unwrap(),[0,1]);
        let mut extra=member.clone();extra.entry.as_mut().unwrap().name="Extra.bin".encode_utf16().collect();
        assert!(map_nodes(&[root.clone(),extra],&manifest).is_err());
        let mut wrong_size=member.clone();wrong_size.file.as_mut().unwrap().size=4;
        assert!(map_nodes(&[root.clone(),wrong_size],&manifest).is_err());
        let mut wrong_kind=member;wrong_kind.file=None;wrong_kind.directory=Some(directory);
        assert!(map_nodes(&[root,wrong_kind],&manifest).is_err());
    }
}
