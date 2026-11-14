//! O/P action checks on the already-authenticated serial SFTP v3 channel.
//! A prepared request has no mutation authority until its parent has durably
//! recorded Needs Review and sends one matching permit.
use super::*;
use tokio::io::{AsyncRead,AsyncWrite};

pub(super) struct Target{pub path:String,pub destination:Option<String>,pub expected:Option<crate::wire::Metadata>,pub copy_stage:Option<String>}
#[derive(Debug,PartialEq,Eq)]
#[repr(u8)]
pub(super) enum Refusal{TargetExists=1,SourceChanged=2,Denied=3,Unavailable=4,Busy=5,NotEmpty=6}
fn join(parent:&str,name:&str)->Result<String,Issue>{
    let path=format!("{}/{}",parent.trim_end_matches('/'),name);
    if path.len()>8192||!path.starts_with('/')||path.contains('\0'){return Err(Issue::Invalid)}Ok(path)
}
fn same_or_descendant(path:&str,directory:&str)->bool{
    path==directory||path.strip_prefix(directory).is_some_and(|tail|tail.starts_with('/'))
}
pub(super) fn target(action:&ipc::RemoteAction,parent:&str,selected:Option<(String,crate::catalog::Entry)>)->Result<Target,Issue>{
    let path=join(parent,&action.name)?;
    let destination=if [6,7,8].contains(&action.kind){
        let destination_parent=action.destination_parent.as_deref().ok_or(Issue::Invalid)?;
        if (action.kind!=8&&destination_parent==parent)||action.kind==7&&same_or_descendant(destination_parent,&path){
            return Err(Issue::SourceChanged)
        }
        let name=if action.kind==8{action.destination.as_deref().ok_or(Issue::Invalid)?}else{&action.name};
        let final_path=join(destination_parent,name)?;
        if final_path==path{return Err(Issue::SourceChanged)}
        Some(final_path)
    }else{action.destination.as_ref().map(|name|join(parent,name)).transpose()?};
    let expected=if action.kind==1 {
        if selected.is_some(){return Err(Issue::Phase)}None
    }else{
        let (selected_path,entry)=selected.ok_or(Issue::Phase)?;
        let selected_kind=action.permissions&0o170000;
        let required_kind=if [4,5,7].contains(&action.kind){0o040000}else{0o100000};
        if ![2,3,4,5,6,7,8].contains(&action.kind)||selected_path!=path||entry.name.as_bytes()!=action.name.as_bytes()||
            entry.size!=Some(action.size)||entry.modified!=Some(action.modified)||
            entry.mode!=Some(action.permissions)||selected_kind!=required_kind{return Err(Issue::SourceChanged)}
        if action.kind==8&&(action.size>64<<30||action.permissions&0o7000!=0){return Err(Issue::SourceChanged)}
        Some(crate::wire::Metadata{size:entry.size,modified:entry.modified,permissions:entry.mode})
    };
    let copy_stage=if action.kind==8{
        let final_path=destination.as_deref().ok_or(Issue::Invalid)?;
        let copy=crate::upload::server_copy::Target::new(&path,final_path,action.request).map_err(|_|Issue::Invalid)?;
        Some(copy.stage_path().to_owned())
    }else{None};
    Ok(Target{path,destination,expected,copy_stage})
}
fn safe_error(error:reader::Failure)->Result<Option<Refusal>,Issue>{
    match error{reader::Failure::Status(2)=>Ok(Some(Refusal::SourceChanged)),
        reader::Failure::Status(3)=>Ok(Some(Refusal::Denied)),
        reader::Failure::Status(4)=>Ok(Some(Refusal::Unavailable)),other=>Err(read_error(other))}
}
pub(super) async fn preflight<S:AsyncRead+AsyncWrite+Unpin>(reader:&mut reader::Reader<S>,
    action:&ipc::RemoteAction,parent:&str,target:&Target)->Result<Option<Refusal>,Issue>{
    let actual=match reader.real_path(parent).await{Ok(value)=>value,Err(error)=>return safe_error(error)};
    if actual!=parent{return Ok(Some(Refusal::SourceChanged))}
    let parent_metadata=match reader.metadata(parent).await{Ok(value)=>value,Err(error)=>return safe_error(error)};
    if parent_metadata.permissions.is_none_or(|mode|mode&0o170000!=0o040000){return Ok(Some(Refusal::SourceChanged))}
    let observed=match reader.metadata_optional(&target.path).await{Ok(value)=>value,Err(error)=>return safe_error(error)};
    match action.kind{
        1=>Ok(observed.map(|_|Refusal::TargetExists)),
        2|5|6|7|8=>{
            if observed!=target.expected{return Ok(Some(Refusal::SourceChanged))}
            if action.kind==8&&!reader.supports_server_copy(){return Ok(Some(Refusal::Unavailable))}
            if let Some(destination_parent)=action.destination_parent.as_deref(){
                let actual=match reader.real_path(destination_parent).await{
                    Ok(value)=>value,Err(error)=>return safe_error(error)};
                if actual!=destination_parent{return Ok(Some(Refusal::SourceChanged))}
                let metadata=match reader.metadata(destination_parent).await{
                    Ok(value)=>value,Err(error)=>return safe_error(error)};
                if metadata.permissions.is_none_or(|mode|mode&0o170000!=0o040000){
                    return Ok(Some(Refusal::SourceChanged))
                }
            }
            let destination=target.destination.as_ref().ok_or(Issue::Phase)?;
            match reader.metadata_optional(destination).await{
                Ok(Some(_))=>Ok(Some(Refusal::TargetExists)),
                Ok(None) if action.kind==8=>match reader.metadata_optional(target.copy_stage.as_deref().ok_or(Issue::Phase)?).await{
                    Ok(Some(_))=>Ok(Some(Refusal::TargetExists)),Ok(None)=>Ok(None),Err(error)=>safe_error(error)},
                Ok(None)=>Ok(None),Err(error)=>safe_error(error)}
        },
        3=>Ok(if observed==target.expected{None}else{Some(Refusal::SourceChanged)}),
        4=>{
            if observed!=target.expected{return Ok(Some(Refusal::SourceChanged))}
            match reader.directory_is_empty(&target.path).await {
                Ok(Some(true))=>Ok(None),
                Ok(Some(false))=>Ok(Some(Refusal::NotEmpty)),
                Ok(None)=>Ok(Some(Refusal::Unavailable)),
                Err(error)=>safe_error(error),
            }
        },
        _=>Err(Issue::Phase),
    }
}
pub(super) async fn mutate_and_verify<S:AsyncRead+AsyncWrite+Unpin>(reader:&mut reader::Reader<S>,
    action:&ipc::RemoteAction,target:&Target)->Result<bool,Issue>{
    let mutation=match action.kind{
        1=>reader.create_directory(&target.path).await,
        2|5|6|7=>reader.rename_standard(&target.path,target.destination.as_ref().ok_or(Issue::Phase)?).await,
        3=>reader.remove_file(&target.path).await,
        4=>reader.remove_empty_directory(&target.path).await,
        _=>return Err(Issue::Phase),
    };
    mutation.map_err(read_error)?;
    match action.kind{
        1=>Ok(reader.metadata(&target.path).await.map_err(read_error)?.permissions
              .is_some_and(|mode|mode&0o170000==0o040000)),
        2|5|6|7=>{
            let old=reader.metadata_optional(&target.path).await.map_err(read_error)?;
            let new=reader.metadata_optional(target.destination.as_ref().ok_or(Issue::Phase)?).await.map_err(read_error)?;
            Ok(old.is_none()&&new==target.expected)
        },
        3=>Ok(reader.metadata_optional(&target.path).await.map_err(read_error)?.is_none()),
        4=>Ok(reader.metadata_optional(&target.path).await.map_err(read_error)?.is_none()),
        _=>Err(Issue::Phase),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt,AsyncWriteExt,DuplexStream};
    use std::time::Duration;

    async fn request(stream:&mut DuplexStream,kind:u8,path:&str)->u32{
        let length=stream.read_u32().await.unwrap() as usize;
        let mut body=vec![0;length];stream.read_exact(&mut body).await.unwrap();
        assert_eq!(body[0],kind);
        let id=u32::from_be_bytes(body[1..5].try_into().unwrap());
        assert_eq!(u32::from_be_bytes(body[5..9].try_into().unwrap()) as usize,path.len());
        assert_eq!(&body[9..],path.as_bytes());id
    }
    async fn rename_request(stream:&mut DuplexStream,old:&str,new:&str)->u32{
        let length=stream.read_u32().await.unwrap() as usize;
        let mut body=vec![0;length];stream.read_exact(&mut body).await.unwrap();
        assert_eq!(body[0],18);
        let id=u32::from_be_bytes(body[1..5].try_into().unwrap());
        let old_length=u32::from_be_bytes(body[5..9].try_into().unwrap()) as usize;
        assert_eq!(&body[9..9+old_length],old.as_bytes());
        let next=9+old_length;
        let new_length=u32::from_be_bytes(body[next..next+4].try_into().unwrap()) as usize;
        assert_eq!(&body[next+4..],new.as_bytes());
        assert_eq!(new_length,new.len());id
    }
    async fn reply(stream:&mut DuplexStream,body:Vec<u8>){
        stream.write_u32(body.len() as u32).await.unwrap();stream.write_all(&body).await.unwrap();
    }
    fn status(id:u32,code:u32)->Vec<u8>{
        let mut body=vec![101];body.extend(id.to_be_bytes());body.extend(code.to_be_bytes());
        body.extend(0u32.to_be_bytes());body.extend(0u32.to_be_bytes());body
    }
    fn attributes(id:u32,mode:u32)->Vec<u8>{
        let mut body=vec![105];body.extend(id.to_be_bytes());body.extend(4u32.to_be_bytes());
        body.extend(mode.to_be_bytes());body
    }
    fn full_attributes(id:u32,mode:u32,size:u64,modified:u32)->Vec<u8>{
        let mut body=vec![105];body.extend(id.to_be_bytes());body.extend(13u32.to_be_bytes());
        body.extend(size.to_be_bytes());body.extend(mode.to_be_bytes());
        body.extend(1u32.to_be_bytes());body.extend(modified.to_be_bytes());body
    }
    fn handle(id:u32)->Vec<u8>{
        let mut body=vec![102];body.extend(id.to_be_bytes());body.extend(1u32.to_be_bytes());
        body.push(b'h');body
    }
    fn names(id:u32)->Vec<u8>{
        let mut body=vec![104];body.extend(id.to_be_bytes());body.extend(1u32.to_be_bytes());
        body.extend(5u32.to_be_bytes());body.extend(b"child");body.extend(0u32.to_be_bytes());
        body.extend(4u32.to_be_bytes());body.extend(0o100644u32.to_be_bytes());body
    }
    fn canonical(id:u32,path:&str)->Vec<u8>{
        let mut body=vec![104];body.extend(id.to_be_bytes());body.extend(1u32.to_be_bytes());
        body.extend((path.len() as u32).to_be_bytes());body.extend(path.as_bytes());
        body.extend(0u32.to_be_bytes());body.extend(0u32.to_be_bytes());body
    }
    fn folder_action()->ipc::RemoteAction{
        ipc::RemoteAction{request:[1;16],generation:[2;16],read:1,revision:0,kind:1,
            observation:0,name:"new".to_owned(),destination:None,destination_parent:None,
            size:0,modified:0,permissions:0}
    }
    fn empty_directory_action()->ipc::RemoteAction{
        ipc::RemoteAction{request:[1;16],generation:[2;16],read:1,revision:0,kind:4,
            observation:7,name:"Empty".to_owned(),destination:None,destination_parent:None,
            size:0,modified:2,permissions:0o040755}
    }
    fn directory_rename_action()->ipc::RemoteAction{
        ipc::RemoteAction{request:[1;16],generation:[2;16],read:1,revision:0,kind:5,
            observation:7,name:"Empty".to_owned(),destination:Some("Other".to_owned()),
            destination_parent:None,
            size:0,modified:2,permissions:0o040755}
    }
    fn file_move_action()->ipc::RemoteAction{
        ipc::RemoteAction{request:[1;16],generation:[2;16],read:1,revision:0,kind:6,
            observation:7,name:"file.txt".to_owned(),destination:None,
            destination_parent:Some("/generated/Other".to_owned()),
            size:1,modified:2,permissions:0o100644}
    }
    fn directory_move_action()->ipc::RemoteAction{
        ipc::RemoteAction{request:[1;16],generation:[2;16],read:1,revision:0,kind:7,
            observation:7,name:"Empty".to_owned(),destination:None,
            destination_parent:Some("/generated/Other".to_owned()),
            size:0,modified:2,permissions:0o040755}
    }
    fn file_copy_action()->ipc::RemoteAction{
        ipc::RemoteAction{request:[7;16],generation:[2;16],read:1,revision:0,kind:8,
            observation:7,name:"file.txt".to_owned(),destination:Some("copy.txt".to_owned()),
            destination_parent:Some("/generated/Other".to_owned()),size:1,modified:2,permissions:0o100644}
    }
    #[test]fn copy_target_separates_source_final_and_durable_stage(){
        let action=file_copy_action();let selected=target(&action,"/generated",Some(selected_file())).unwrap();
        assert_eq!(selected.path,"/generated/file.txt");
        assert_eq!(selected.destination.as_deref(),Some("/generated/Other/copy.txt"));
        assert_eq!(selected.copy_stage.as_deref(),Some("/generated/Other/.mac-explorer-copy-07070707070707070707070707070707.part"));
        let mut same=file_copy_action();same.destination_parent=Some("/generated".to_owned());
        same.destination=Some("file.txt".to_owned());
        assert!(matches!(target(&same,"/generated",Some(selected_file())),Err(Issue::SourceChanged)));
        same.destination=Some("copy.txt".to_owned());
        assert!(target(&same,"/generated",Some(selected_file())).is_ok());
        let mut special=file_copy_action();special.permissions=0o104644;
        assert!(target(&special,"/generated",Some(selected_file())).is_err());
    }
    fn selected_file()->(String,crate::catalog::Entry){
        ("/generated/file.txt".to_owned(),crate::catalog::Entry{name:"file.txt".to_owned(),
            size:Some(1),modified:Some(2),mode:Some(0o100644)})
    }
    fn selected_empty_directory()->(String,crate::catalog::Entry){
        ("/generated/Empty".to_owned(),crate::catalog::Entry{name:"Empty".to_owned(),
            size:Some(0),modified:Some(2),mode:Some(0o040755)})
    }

    #[test]fn directory_delete_target_rejects_file_and_link_kinds(){
        let action=empty_directory_action();
        assert!(target(&action,"/generated",Some(selected_empty_directory())).is_ok());
        for mode in [0o100644,0o120777]{
            let mut selected=selected_empty_directory();selected.1.mode=Some(mode);
            assert!(matches!(target(&action,"/generated",Some(selected)),Err(Issue::SourceChanged)));
        }
        let mut file_action=action;file_action.kind=3;
        assert!(matches!(target(&file_action,"/generated",Some(selected_empty_directory())),Err(Issue::SourceChanged)));
    }

    #[test]fn directory_rename_target_rejects_file_link_and_foreign_selection(){
        let action=directory_rename_action();
        let valid=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(valid.path,"/generated/Empty");assert_eq!(valid.destination.as_deref(),Some("/generated/Other"));
        for mode in [0o100644,0o120777]{
            let mut selected=selected_empty_directory();selected.1.mode=Some(mode);
            assert!(matches!(target(&action,"/generated",Some(selected)),Err(Issue::SourceChanged)));
        }
        let mut foreign=selected_empty_directory();foreign.0="/other/Empty".to_owned();
        assert!(matches!(target(&action,"/generated",Some(foreign)),Err(Issue::SourceChanged)));
    }

    #[test]fn file_move_target_keeps_leaf_and_rejects_same_parent_or_foreign_selection(){
        let action=file_move_action();
        let selected=target(&action,"/generated",Some(selected_file())).unwrap();
        assert_eq!(selected.destination.as_deref(),Some("/generated/Other/file.txt"));
        let mut same=file_move_action();same.destination_parent=Some("/generated".to_owned());
        assert!(matches!(target(&same,"/generated",Some(selected_file())),Err(Issue::SourceChanged)));
        let mut foreign=selected_file();foreign.0="/foreign/file.txt".to_owned();
        assert!(matches!(target(&action,"/generated",Some(foreign)),Err(Issue::SourceChanged)));
        let mut link=selected_file();link.1.mode=Some(0o120777);
        assert!(matches!(target(&action,"/generated",Some(link)),Err(Issue::SourceChanged)));
    }

    #[test]fn directory_move_target_refuses_self_descendant_and_non_directory(){
        let action=directory_move_action();
        let selected=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(selected.path,"/generated/Empty");
        assert_eq!(selected.destination.as_deref(),Some("/generated/Other/Empty"));
        for parent in ["/generated","/generated/Empty","/generated/Empty/Child"]{
            let mut refused=directory_move_action();refused.destination_parent=Some(parent.to_owned());
            assert!(matches!(target(&refused,"/generated",Some(selected_empty_directory())),Err(Issue::SourceChanged)));
        }
        let mut sibling=directory_move_action();sibling.destination_parent=Some("/generated/Empty2".to_owned());
        assert_eq!(target(&sibling,"/generated",Some(selected_empty_directory())).unwrap().destination.as_deref(),
            Some("/generated/Empty2/Empty"));
        for mode in [0o100644,0o120777]{
            let mut wrong=selected_empty_directory();wrong.1.mode=Some(mode);
            assert!(matches!(target(&action,"/generated",Some(wrong)),Err(Issue::SourceChanged)));
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_move_rechecks_canonical_parent_and_vacancy_before_permit(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
            for state in [0u8,1,2]{
                let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/Empty").await;
                reply(&mut server,full_attributes(id,0o040755,0,2)).await;
                let id=request(&mut server,16,"/generated/Other").await;
                reply(&mut server,canonical(id,if state==2{"/elsewhere/Other"}else{"/generated/Other"})).await;
                if state!=2{
                    let id=request(&mut server,7,"/generated/Other").await;
                    reply(&mut server,attributes(id,0o040755)).await;
                    let id=request(&mut server,7,"/generated/Other/Empty").await;
                    reply(&mut server,if state==1{attributes(id,0o040755)}else{status(id,2)}).await;
                }
            }
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
        let action=directory_move_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),None);
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::TargetExists));
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::SourceChanged));
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_move_uses_one_standard_rename_and_uncertain_error_boundary(){
        for response in [0u8,1,2]{
            let (client,mut server)=tokio::io::duplex(32768);
            let peer=tokio::spawn(async move{
                let length=server.read_u32().await.unwrap();assert_eq!(length,5);
                let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
                let id=rename_request(&mut server,"/generated/Empty","/generated/Other/Empty").await;
                if response==0{
                    reply(&mut server,status(id,0)).await;
                    let id=request(&mut server,7,"/generated/Empty").await;reply(&mut server,status(id,2)).await;
                    let id=request(&mut server,7,"/generated/Other/Empty").await;
                    reply(&mut server,full_attributes(id,0o040755,0,2)).await;
                }else if response==1{reply(&mut server,status(id,4)).await;}
            });
            let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();reader.enable_actions();
            let action=directory_move_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
            let observed=mutate_and_verify(&mut reader,&action,&target).await;
            if response==0{assert_eq!(observed.unwrap(),true)}else{assert!(observed.is_err())}
            reader.stop();peer.await.unwrap();
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn file_move_rechecks_destination_parent_and_vacancy_before_permit(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
            for occupied in [false,true]{
                let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/file.txt").await;
                reply(&mut server,full_attributes(id,0o100644,1,2)).await;
                let id=request(&mut server,16,"/generated/Other").await;
                reply(&mut server,canonical(id,"/generated/Other")).await;
                let id=request(&mut server,7,"/generated/Other").await;
                reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/Other/file.txt").await;
                reply(&mut server,if occupied{attributes(id,0o100644)}else{status(id,2)}).await;
            }
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
        let action=file_move_action();let target=target(&action,"/generated",Some(selected_file())).unwrap();
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),None);
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::TargetExists));
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn file_move_refuses_changed_or_denied_destination_parent_without_rename(){
        for parent_state in [0u8,1,2]{
            let (client,mut server)=tokio::io::duplex(32768);
            let peer=tokio::spawn(async move{
                let length=server.read_u32().await.unwrap();assert_eq!(length,5);
                let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
                let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/file.txt").await;
                reply(&mut server,full_attributes(id,0o100644,1,2)).await;
                let id=request(&mut server,16,"/generated/Other").await;
                reply(&mut server,if parent_state==1{status(id,3)}else{
                    canonical(id,if parent_state==0{"/different/Other"}else{"/generated/Other"})}).await;
                if parent_state==2{
                    let id=request(&mut server,7,"/generated/Other").await;
                    reply(&mut server,attributes(id,0o100644)).await;
                }
            });
            let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
            let action=file_move_action();let target=target(&action,"/generated",Some(selected_file())).unwrap();
            assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),
                Some(if parent_state==1{Refusal::Denied}else{Refusal::SourceChanged}));
            reader.stop();peer.await.unwrap();
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn file_move_uses_one_standard_rename_and_keeps_status_or_lost_reply_uncertain(){
        for response in [0u8,1,2]{
            let (client,mut server)=tokio::io::duplex(32768);
            let peer=tokio::spawn(async move{
                let length=server.read_u32().await.unwrap();assert_eq!(length,5);
                let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
                let id=rename_request(&mut server,"/generated/file.txt","/generated/Other/file.txt").await;
                if response==0{
                    reply(&mut server,status(id,0)).await;
                    let id=request(&mut server,7,"/generated/file.txt").await;reply(&mut server,status(id,2)).await;
                    let id=request(&mut server,7,"/generated/Other/file.txt").await;
                    reply(&mut server,full_attributes(id,0o100644,1,2)).await;
                }else if response==1{reply(&mut server,status(id,4)).await;}
            });
            let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();reader.enable_actions();
            let action=file_move_action();let target=target(&action,"/generated",Some(selected_file())).unwrap();
            let observed=mutate_and_verify(&mut reader,&action,&target).await;
            if response==0{assert_eq!(observed.unwrap(),true)}else{assert!(observed.is_err())}
            reader.stop();peer.await.unwrap();
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_rename_refuses_occupied_file_and_folder_before_mutation(){
        for occupied_mode in [0o100644,0o040755]{
            let (client,mut server)=tokio::io::duplex(32768);
            let peer=tokio::spawn(async move{
                let length=server.read_u32().await.unwrap();assert_eq!(length,5);
                let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
                let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/Empty").await;
                reply(&mut server,full_attributes(id,0o040755,0,2)).await;
                let id=request(&mut server,7,"/generated/Other").await;
                reply(&mut server,attributes(id,occupied_mode)).await;
            });
            let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
            let action=directory_rename_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
            assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::TargetExists));
            reader.stop();peer.await.unwrap();
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_rename_confirmation_requires_exact_destination_and_ack(){
        for acknowledged in [true,false]{
            let (client,mut server)=tokio::io::duplex(32768);
            let peer=tokio::spawn(async move{
                let length=server.read_u32().await.unwrap();assert_eq!(length,5);
                let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
                let id=rename_request(&mut server,"/generated/Empty","/generated/Other").await;
                if acknowledged{
                    reply(&mut server,status(id,0)).await;
                    let id=request(&mut server,7,"/generated/Empty").await;reply(&mut server,status(id,2)).await;
                    let id=request(&mut server,7,"/generated/Other").await;
                    reply(&mut server,full_attributes(id,0o040755,0,2)).await;
                }
            });
            let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();reader.enable_actions();
            let action=directory_rename_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
            let observed=mutate_and_verify(&mut reader,&action,&target).await;
            if acknowledged{assert_eq!(observed.unwrap(),true)}else{assert!(observed.is_err())}
            reader.stop();peer.await.unwrap();
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_occupied_after_prepare_refuses_before_rmdir(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();assert_eq!(init,[1,0,0,0,3]);
            reply(&mut server,vec![2,0,0,0,3]).await;
            for occupied in [false,true]{
                let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/Empty").await;
                reply(&mut server,full_attributes(id,0o040755,0,2)).await;
                let id=request(&mut server,11,"/generated/Empty").await;reply(&mut server,handle(id)).await;
                let id=request(&mut server,12,"h").await;
                reply(&mut server,if occupied{names(id)}else{status(id,1)}).await;
                let id=request(&mut server,4,"h").await;reply(&mut server,status(id,0)).await;
            }
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
        let action=empty_directory_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),None);
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::NotEmpty));
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_metadata_change_refuses_before_probe_or_rmdir(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
            let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
            let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
            let id=request(&mut server,7,"/generated/Empty").await;
            reply(&mut server,full_attributes(id,0o040755,0,3)).await;
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
        let action=empty_directory_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::SourceChanged));
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_probe_denial_refuses_before_rmdir(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
            let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
            let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
            let id=request(&mut server,7,"/generated/Empty").await;
            reply(&mut server,full_attributes(id,0o040755,0,2)).await;
            let id=request(&mut server,11,"/generated/Empty").await;reply(&mut server,status(id,3)).await;
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
        let action=empty_directory_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::Denied));
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_probe_close_without_ack_poisoned_even_after_safe_read_refusal(){
        for read_denied in [false,true]{
            let (client,mut server)=tokio::io::duplex(32768);
            let peer=tokio::spawn(async move{
                let length=server.read_u32().await.unwrap();assert_eq!(length,5);
                let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
                let id=request(&mut server,16,"/generated").await;reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/Empty").await;
                reply(&mut server,full_attributes(id,0o040755,0,2)).await;
                let id=request(&mut server,11,"/generated/Empty").await;reply(&mut server,handle(id)).await;
                let id=request(&mut server,12,"h").await;
                reply(&mut server,status(id,if read_denied{3}else{1})).await;
                let id=request(&mut server,4,"h").await;reply(&mut server,status(id,3)).await;
            });
            let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();
            let action=empty_directory_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
            assert_eq!(preflight(&mut reader,&action,"/generated",&target).await,Err(Issue::Transport));
            assert!(!reader.is_open());peer.await.unwrap();
        }
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_rmdir_ack_needs_absent_post_observation(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
            let id=request(&mut server,15,"/generated/Empty").await;reply(&mut server,status(id,0)).await;
            let id=request(&mut server,7,"/generated/Empty").await;reply(&mut server,status(id,2)).await;
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();reader.enable_actions();
        let action=empty_directory_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert_eq!(mutate_and_verify(&mut reader,&action,&target).await.unwrap(),true);
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn directory_lost_rmdir_ack_cannot_be_confirmed(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();reply(&mut server,vec![2,0,0,0,3]).await;
            let _=request(&mut server,15,"/generated/Empty").await;
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));reader.initialize().await.unwrap();reader.enable_actions();
        let action=empty_directory_action();let target=target(&action,"/generated",Some(selected_empty_directory())).unwrap();
        assert!(mutate_and_verify(&mut reader,&action,&target).await.is_err());
        reader.stop();peer.await.unwrap();
    }

    #[tokio::test(flavor="current_thread")]
    async fn destination_appearing_between_prepare_and_permit_is_refused(){
        let (client,mut server)=tokio::io::duplex(32768);
        let peer=tokio::spawn(async move{
            let length=server.read_u32().await.unwrap();assert_eq!(length,5);
            let mut init=[0;5];server.read_exact(&mut init).await.unwrap();assert_eq!(init,[1,0,0,0,3]);
            reply(&mut server,vec![2,0,0,0,3]).await;
            for occupied in [false,true]{
                let id=request(&mut server,16,"/generated").await;
                reply(&mut server,canonical(id,"/generated")).await;
                let id=request(&mut server,7,"/generated").await;
                reply(&mut server,attributes(id,0o040755)).await;
                let id=request(&mut server,7,"/generated/new").await;
                reply(&mut server,if occupied{attributes(id,0o100644)}else{status(id,2)}).await;
            }
        });
        let mut reader=reader::Reader::new(client,Duration::from_secs(1));
        reader.initialize().await.unwrap();
        let action=folder_action();let target=target(&action,"/generated",None).unwrap();
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),None);
        assert_eq!(preflight(&mut reader,&action,"/generated",&target).await.unwrap(),Some(Refusal::TargetExists));
        reader.stop();peer.await.unwrap();
    }
}
