//! Generated frame/authority controls, no sockets or local body publication.
use super::*;
use crate::{client::NegotiatedParams,transport::MockTransport,msg::header::Header,
    pack::{Guid,FileTime},types::{Dialect,SessionId,flags::Capabilities}};
const TREE:TreeId=TreeId(7);const SESSION:u64=0x1234;
fn header(command:Command,response:bool)->Header{let mut h=Header::new_request(command);h.tree_id=Some(TREE);h.session_id=SessionId(SESSION);h.credits=64;if response{h.flags.set_response();}h}
fn frame(command:Command,status:u32,body:Vec<u8>)->Vec<u8>{let mut h=header(command,true);h.status=crate::types::status::NtStatus(status);let mut out=WriteCursor::new();h.pack(&mut out);out.write_bytes(&body);out.into_inner()}
fn create(file:FileId,directory:bool,size:u64)->Vec<u8>{
    let mut body=vec![0;88];body[..2].copy_from_slice(&89u16.to_le_bytes());body[4..8].copy_from_slice(&1u32.to_le_bytes());
    for(at,value)in[(8,100u64),(24,300),(32,400),(40,if directory{0}else{size.next_multiple_of(4096)}),(48,size),(64,file.persistent),(72,file.volatile)]{body[at..at+8].copy_from_slice(&value.to_le_bytes());}
    body[56..60].copy_from_slice(&(if directory{0x10u32}else{0x20}).to_le_bytes());frame(Command::Create,0,body)
}
fn query(bytes:Vec<u8>)->Vec<u8>{let mut body=vec![0;8];body[..2].copy_from_slice(&9u16.to_le_bytes());body[2..4].copy_from_slice(&72u16.to_le_bytes());body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend(bytes);frame(Command::QueryInfo,0,body)}
fn metadata(directory:bool,index:u64,size:u64)->Vec<Vec<u8>>{
    let mut basic=vec![0;40];for(at,value)in[(0,100u64),(8,200),(16,300),(24,400)]{basic[at..at+8].copy_from_slice(&value.to_le_bytes());}
    basic[32..36].copy_from_slice(&(if directory{0x10u32}else{0x20}).to_le_bytes());
    let mut standard=vec![0;24];standard[..8].copy_from_slice(&(if directory{0}else{size.next_multiple_of(4096)}).to_le_bytes());standard[8..16].copy_from_slice(&size.to_le_bytes());standard[16]=if directory{2}else{1};standard[21]=u8::from(directory);
    let mut volume=vec![0;18];volume[..8].copy_from_slice(&500u64.to_le_bytes());volume[8]=13;volume[16]=1;
    [basic,standard,index.to_le_bytes().to_vec(),volume].into_iter().map(query).collect()
}
fn open_dir(file:FileId,index:u64)->Vec<Vec<u8>>{let mut values=vec![create(file,true,0)];values.extend(metadata(true,index,0));values}
fn close(status:u32)->Vec<u8>{let mut body=vec![0;60];body[..2].copy_from_slice(&60u16.to_le_bytes());frame(Command::Close,status,body)}
fn no_more()->Vec<u8>{let mut body=vec![0;9];body[..2].copy_from_slice(&9u16.to_le_bytes());frame(Command::QueryDirectory,0x80000006,body)}
fn listed(name:&str,directory:bool,index:u64,size:u64)->DirectoryInfoEntry{DirectoryInfoEntry{file_name:name.into(),file_id:Some(index),
    last_write_time:FileTime(300),change_time:FileTime(400),creation_time:FileTime(100),last_access_time:FileTime(200),
    file_attributes:if directory{0x10}else{0x20},end_of_file:size,allocation_size:if directory{0}else{size.next_multiple_of(4096)},..Default::default()}}
fn listing(rows:&[DirectoryInfoEntry])->Vec<u8>{let bytes=crate::msg::directory_info::pack_entries(FileInformationClass::FileIdBothDirectoryInformation,rows).unwrap();
    let mut body=vec![0;8];body[..2].copy_from_slice(&9u16.to_le_bytes());body[2..4].copy_from_slice(&72u16.to_le_bytes());body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend(bytes);frame(Command::QueryDirectory,0,body)}
fn read(bytes:&[u8])->Vec<u8>{let mut body=vec![0;16];body[..2].copy_from_slice(&17u16.to_le_bytes());body[2]=80;body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend_from_slice(bytes);frame(Command::Read,0,body)}
fn eof()->Vec<u8>{let mut body=vec![0;9];body[..2].copy_from_slice(&9u16.to_le_bytes());frame(Command::Read,0xc0000011,body)}
fn setup()->(Connection,Arc<MockTransport>,Arc<SelectedFolderPolicy>){
    let mock=Arc::new(MockTransport::new());mock.enable_auto_rewrite_msg_id();let mut conn=Connection::from_transport(Box::new(mock.clone()),Box::new(mock.clone()),"generated.invalid");
    let policy=SelectedFolderPolicy::new();conn.set_selected_folder_policy(Arc::clone(&policy)).unwrap();
    conn.set_test_params(NegotiatedParams{dialect:Dialect::Smb3_1_1,max_read_size:65536,max_write_size:65536,max_transact_size:65536,
        server_guid:Guid::ZERO,signing_required:false,capabilities:Capabilities::default(),gmac_negotiated:false,cipher:None,compression_supported:false});
    conn.set_session_id(SessionId(SESSION));conn.set_credits(4096);conn.set_reviver(None);conn.set_keepalive(None);conn.set_response_timeout(Some(std::time::Duration::from_millis(250)));(conn,mock,policy)
}
async fn drain(conn:&Connection,mock:&MockTransport){mock.close();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);assert!(conn.outstanding_requests().is_empty());}
fn root()->FileId{FileId{persistent:5,volatile:6}}
async fn successful_file()->usize{
    let(conn,mock,policy)=setup();let mut replies=open_dir(root(),100);
    replies.extend(metadata(true,100,0));replies.push(listing(&[listed("Member.txt",false,101,3)]));replies.push(no_more());replies.extend(metadata(true,100,0));
    replies.extend(open_dir(FileId{persistent:7,volatile:8},100));replies.push(close(0));
    replies.push(create(FileId{persistent:9,volatile:10},false,3));replies.extend(metadata(false,101,3));
    replies.push(read(b"abc"));replies.push(eof());replies.extend(metadata(false,101,3));replies.push(close(0));replies.push(close(0));mock.queue_responses(replies);
    let(owner,root)=CheckedFolderReader::prepare(conn.clone(),TREE,&"Folder".encode_utf16().collect::<Vec<_>>(),0x10,300).await.unwrap();
    let entries=owner.children(&root).await.unwrap();assert_eq!(entries.len(),1);assert_eq!(entries[0].index,101);
    let mut file=owner.prepare_file(&root,&entries[0]).await.unwrap();assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));
    owner.permit_file_body().unwrap();assert_eq!(file.read_chunk().await.unwrap(),b"abc");file.finish().await.unwrap();
    // Inner D1 Idle after actual CLOSE cannot reopen B2 metadata authority.
    assert!(policy.file.idle());let mut request=WriteCursor::new();ExactDirectory(&"Other".encode_utf16().collect::<Vec<_>>()).pack(&mut request);
    let mut raw=WriteCursor::new();header(Command::Create,false).pack(&mut raw);raw.write_bytes(&request.into_inner());assert!(!policy.permits_frame(&raw.into_inner()));
    owner.member_closed().unwrap();owner.close(root).await.unwrap();owner.finish().unwrap();assert!(matches!(*policy.state.lock().unwrap(),State::Idle));
    let messages=mock.sent_messages();assert_eq!(messages.iter().filter(|v|u16_at(v,12)==8).count(),2);assert!(messages.iter().all(|v|matches!(u16_at(v,12),5|6|8|14|16)));
    assert!(messages.iter().filter(|v|u16_at(v,12)==14).all(|v|v[66]==37));drain(&conn,&mock).await;1
}
async fn root_refusal(kind:u8)->usize{
    let(conn,mock,policy)=setup();let mut replies=open_dir(root(),100);
    match kind{0=>replies[3][72..80].fill(0),1=>replies[3][72..80].fill(255),2=>replies[1][104]|=0x40,
        3=>replies[2][92]=1,4=>replies[2][93]=0,5=>replies[0][121]|=4,6=>replies[0][68..72].copy_from_slice(&2u32.to_le_bytes()),
        7=>replies[4][80..84].fill(0),8=>replies[0][128..136].fill(255),_=>unreachable!()}
    mock.queue_responses(replies);assert!(CheckedFolderReader::prepare(conn.clone(),TREE,&[70],0x10,300).await.is_err());
    assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));assert!(!mock.sent_messages().iter().any(|v|matches!(u16_at(v,12),6|8|14)));
    drain(&conn,&mock).await;1
}
async fn enumeration_refusal(kind:u8)->usize{
    let(conn,mock,policy)=setup();let mut replies=open_dir(root(),100);replies.extend(metadata(true,100,0));
    let mut row=listed("Member",false,101,3);
    match kind{0=>row.file_id=Some(0),1=>row.file_id=Some(u64::MAX),2=>row.file_attributes|=0x400,
        3=>row.file_name="..\\Outside".into(),4=>row.file_name="A\u{202e}txt".into(),5=>{},6=>{},7=>{},_=>unreachable!()}
    if kind==6{let mut body=vec![0;9];body[..2].copy_from_slice(&9u16.to_le_bytes());replies.push(frame(Command::QueryDirectory,0xc0000003,body));}
    else if kind==7{let mut bad=no_more();bad[68]=1;replies.push(bad);}
    else{replies.push(listing(&if kind==5{vec![row.clone(),row]}else{vec![row]}));}
    mock.queue_responses(replies);let(owner,root)=CheckedFolderReader::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    assert!(owner.children(&root).await.is_err());drop(owner);assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));
    assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));assert_eq!(mock.sent_messages().iter().filter(|v|u16_at(v,12)==14).count(),1);
    drain(&conn,&mock).await;1
}
async fn close_refusal()->usize{
    let(conn,mock,policy)=setup();let mut replies=open_dir(root(),100);replies.push(close(0xc0000128));mock.queue_responses(replies);
    let(owner,root)=CheckedFolderReader::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();assert!(owner.close(root).await.is_err());drop(owner);
    assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));assert_eq!(mock.sent_messages().iter().filter(|v|u16_at(v,12)==6).count(),1);
    drain(&conn,&mock).await;1
}
async fn cancel_query()->usize{
    let(conn,mock,policy)=setup();mock.queue_responses(open_dir(root(),100));let(owner,root)=CheckedFolderReader::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    assert!(tokio::time::timeout(std::time::Duration::from_millis(20),owner.children(&root)).await.is_err());let count=mock.sent_messages().len();drop(owner);
    tokio::task::yield_now().await;assert_eq!(mock.sent_messages().len(),count);assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));drain(&conn,&mock).await;1
}
fn root_contents(rows:&[DirectoryInfoEntry])->Vec<Vec<u8>>{
    let mut result=metadata(true,100,0);if !rows.is_empty(){result.push(listing(rows));}result.push(no_more());result.extend(metadata(true,100,0));result
}
fn root_path_check()->Vec<Vec<u8>>{let mut replies=open_dir(FileId{persistent:7,volatile:8},100);replies.push(close(0));replies}
fn file_prepare(index:u64,size:u64)->Vec<Vec<u8>>{let mut replies=root_path_check();replies.push(create(FileId{persistent:9,volatile:10},false,size));replies.extend(metadata(false,index,size));replies}
async fn empty_tree(release:bool)->usize{
    let(conn,mock,policy)=setup();let mut replies=open_dir(root(),100);replies.extend(root_contents(&[]));
    if !release{for _ in 0..2{replies.extend(root_path_check());replies.extend(root_contents(&[]));}}
    replies.push(close(0));mock.queue_responses(replies);
    let mut folder=PreparedFolder::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    assert_eq!(folder.nodes().len(),1);assert_eq!((folder.files(),folder.folders(),folder.logical_bytes()),(0,0,0));
    if release{folder.release().await.unwrap();}else{
        folder.begin().await.unwrap();assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::Complete{bytes:0,files:0}));assert!(folder.next().await.is_err());drop(folder);
    }
    assert!(matches!(*policy.state.lock().unwrap(),State::Idle));assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));drain(&conn,&mock).await;1
}
async fn complete_tree_file()->usize{
    let(conn,mock,policy)=setup();let rows=[listed("Member.txt",false,101,3)];let mut replies=open_dir(root(),100);
    replies.extend(root_contents(&rows));replies.extend(file_prepare(101,3));replies.push(close(0));
    replies.extend(root_path_check());replies.extend(root_contents(&rows)); // Begin rechecks.
    replies.extend(file_prepare(101,3));replies.push(read(b"abc"));replies.push(eof());replies.extend(metadata(false,101,3));replies.push(close(0));
    replies.extend(root_path_check());replies.extend(root_contents(&rows));replies.push(close(0));mock.queue_responses(replies);
    let mut folder=PreparedFolder::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    assert_eq!(folder.nodes().len(),2);assert_eq!(folder.nodes()[1].parent,Some(0));assert_eq!(folder.nodes()[1].file.as_ref().unwrap().index,101);
    assert_eq!((folder.files(),folder.folders(),folder.logical_bytes()),(1,0,3));assert!(folder.next().await.is_err());
    assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));folder.begin().await.unwrap();
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::MemberStarted{ordinal:1,bytes:3}));
    match folder.next().await.unwrap(){FolderReadEvent::Bytes{ordinal:1,offset:0,bytes}=>assert_eq!(bytes,b"abc"),_=>panic!("wrong generated folder event")}
    let before=mock.sent_messages().len();assert!(folder.next().await.is_err());assert!(folder.acknowledge(2,3).is_err());assert!(folder.acknowledge(1,4).is_err());assert_eq!(mock.sent_messages().len(),before);
    folder.acknowledge(1,3).unwrap();assert!(folder.acknowledge(1,3).is_err());
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::MemberFinished{ordinal:1,bytes:3}));
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::Complete{bytes:3,files:1}));assert!(folder.next().await.is_err());drop(folder);
    assert!(matches!(*policy.state.lock().unwrap(),State::Idle));drain(&conn,&mock).await;1
}
async fn member_refusal(kind:u8)->usize{
    let(conn,mock,policy)=setup();let mut replies=open_dir(root(),100);replies.extend(root_path_check());
    let id=if kind==4{root()}else{FileId{persistent:9,volatile:10}};replies.push(create(id,false,3));let mut facts=metadata(false,101,3);
    match kind{0=>facts[2][72..80].copy_from_slice(&102u64.to_le_bytes()),1=>facts[3][80..84].copy_from_slice(&14u32.to_le_bytes()),
        2=>facts[1][88..92].copy_from_slice(&2u32.to_le_bytes()),3=>facts[0][96..104].copy_from_slice(&401u64.to_le_bytes()),4=>{},_=>unreachable!()}
    replies.extend(facts);mock.queue_responses(replies);let(owner,root)=CheckedFolderReader::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    let row=FolderEntry{name:"Member.txt".encode_utf16().collect(),attributes:0x20,size:3,allocated:4096,modified:300,changed:400,index:101};
    assert!(owner.prepare_file(&root,&row).await.is_err());drop(owner);assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));drain(&conn,&mock).await;1
}
fn contents(index:u64,rows:&[DirectoryInfoEntry])->Vec<Vec<u8>>{
    let mut values=metadata(true,index,0);if !rows.is_empty(){values.push(listing(rows));}values.push(no_more());values.extend(metadata(true,index,0));values
}
fn path_check(index:u64,file:FileId)->Vec<Vec<u8>>{let mut values=open_dir(file,index);values.push(close(0));values}
fn child_open()->Vec<Vec<u8>>{let mut values=root_path_check();values.extend(open_dir(FileId{persistent:11,volatile:12},101));values}
fn nested_file_prepare()->Vec<Vec<u8>>{
    let mut values=path_check(101,FileId{persistent:13,volatile:14});values.push(create(FileId{persistent:9,volatile:10},false,3));values.extend(metadata(false,102,3));values
}
fn nested_verify(root_rows:&[DirectoryInfoEntry],child_rows:&[DirectoryInfoEntry])->Vec<Vec<u8>>{
    let mut values=root_path_check();values.extend(root_contents(root_rows));values.extend(child_open());values.extend(contents(101,child_rows));values.push(close(0));values
}
async fn nested_tree()->usize{
    let(conn,mock,policy)=setup();let root_rows=[listed("Branch",true,101,0)];let child_rows=[listed("File.txt",false,102,3)];
    let mut replies=open_dir(root(),100);replies.extend(root_contents(&root_rows));replies.extend(child_open());replies.extend(contents(101,&child_rows));
    replies.extend(nested_file_prepare());replies.push(close(0));replies.push(close(0));
    replies.extend(nested_verify(&root_rows,&child_rows));
    replies.extend(child_open());replies.extend(nested_file_prepare());replies.push(read(b"abc"));replies.push(eof());replies.extend(metadata(false,102,3));replies.push(close(0));
    replies.push(close(0));replies.extend(nested_verify(&root_rows,&child_rows));replies.push(close(0));mock.queue_responses(replies);
    let mut folder=PreparedFolder::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    assert_eq!(folder.nodes().len(),3);assert_eq!(folder.nodes()[2].parent,Some(1));assert_eq!(folder.longest_path_bytes(),15);
    assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));folder.begin().await.unwrap();
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::MemberStarted{ordinal:2,bytes:3}));
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::Bytes{ordinal:2,offset:0,..}));folder.acknowledge(2,3).unwrap();
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::MemberFinished{ordinal:2,bytes:3}));
    assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::Complete{bytes:3,files:1}));drop(folder);
    assert!(matches!(*policy.state.lock().unwrap(),State::Idle));drain(&conn,&mock).await;1
}
async fn tree_refusal(kind:u8)->usize{
    let(conn,mock,policy)=setup();let rows=[listed("Member.txt",false,101,3)];let mut replies=open_dir(root(),100);
    replies.extend(root_contents(&rows));replies.extend(file_prepare(101,3));replies.push(close(0));
    replies.extend(root_path_check());let changed=[listed("Member.txt",false,102,3)];replies.extend(root_contents(if kind==0{&changed}else{&rows}));
    if kind!=0{
        replies.extend(file_prepare(if kind==1{102}else{101},3));
        if kind==2{replies.push(read(b"abc"));replies.push(eof());replies.extend(metadata(false,101,3));replies.push(close(0));replies.extend(root_path_check());replies.extend(root_contents(&changed));}
    }
    mock.queue_responses(replies);let mut folder=PreparedFolder::prepare(conn.clone(),TREE,&[70],0x10,300).await.unwrap();
    if kind==0{assert!(folder.begin().await.is_err());}
    else{
        folder.begin().await.unwrap();
        if kind==1{assert!(folder.next().await.is_err());}
        else{
            assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::MemberStarted{..}));
            if kind==3{assert!(tokio::time::timeout(std::time::Duration::from_millis(20),folder.next()).await.is_err());}
            else{
                assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::Bytes{..}));folder.acknowledge(1,3).unwrap();
                assert!(matches!(folder.next().await.unwrap(),FolderReadEvent::MemberFinished{..}));assert!(folder.next().await.is_err());
            }
        }
    }
    let reads=mock.sent_messages().iter().filter(|v|u16_at(v,12)==8).count();assert_eq!(reads,if kind==2{2}else if kind==3{1}else{0});
    let sent=mock.sent_messages().len();drop(folder);tokio::task::yield_now().await;assert_eq!(sent,mock.sent_messages().len());assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));drain(&conn,&mock).await;1
}
fn policy_controls()->usize{
    let policy=SelectedFolderPolicy::new();policy.begin(TREE,SESSION).unwrap();let path="Folder".encode_utf16().collect::<Vec<_>>();
    policy.expect(Expected::Open(path.iter().flat_map(|v|v.to_le_bytes()).collect())).unwrap();
    let mut raw=WriteCursor::new();header(Command::Create,false).pack(&mut raw);ExactDirectory(&path).pack(&mut raw);let good=raw.into_inner();assert!(policy.permits_frame(&good));let mut count=1;
    for at in [4,12,16,20,36,40,64,66,68,72,88,92,96,100,104,108,110,112,116,120]{let mut bad=good.clone();bad[at]^=1;assert!(!policy.permits_frame(&bad));count+=1;}
    for bad in ["", "..", "a/b", "a\\b", "bad.", "bad ", "a\n", "a\u{202e}"]{assert!(!safe_name(&bad.encode_utf16().collect::<Vec<_>>()));count+=1;}
    assert!(!safe_name(&[0xd800]));assert!(!safe_path(&[70;2049]));count+=2;
    assert!(policy.opened(FileId{persistent:u64::MAX,volatile:7}).is_err());policy.opened(root()).unwrap();
    let query=QueryDirectoryRequest{file_information_class:FileInformationClass::FileIdBothDirectoryInformation,flags:QueryDirectoryFlags(1),file_index:0,file_id:root(),output_buffer_length:65536,file_name:"*".into()};
    policy.expect(Expected::List(root(),true,65536)).unwrap();let mut raw=WriteCursor::new();header(Command::QueryDirectory,false).pack(&mut raw);query.pack(&mut raw);let good=raw.into_inner();assert!(policy.permits_frame(&good));count+=1;
    for at in [12,16,20,36,40,64,66,67,68,72,80,88,90,92,96]{let mut bad=good.clone();bad[at]^=1;assert!(!policy.permits_frame(&bad));count+=1;}
    policy.poison();assert!(!policy.permits_frame(&good));count+1
}
pub(super) async fn run()->Result<usize>{
    let mut count=policy_controls();count+=successful_file().await;
    for kind in 0..9{count+=root_refusal(kind).await;}
    for kind in 0..8{count+=enumeration_refusal(kind).await;}
    count+=close_refusal().await;count+=cancel_query().await;
    count+=empty_tree(true).await;count+=empty_tree(false).await;count+=complete_tree_file().await;
    for kind in 0..5{count+=member_refusal(kind).await;}
    count+=nested_tree().await;for kind in 0..4{count+=tree_refusal(kind).await;}Ok(count)
}

// Generated Samba-like continuation refusal at the actual transport boundary.
// Included only in b12-folder-qualification; no real sockets or server state.
struct PatternSend{mock:Arc<MockTransport>,replies:Mutex<std::collections::VecDeque<Vec<u8>>>,empty:AtomicU64}
#[async_trait::async_trait]
impl crate::transport::TransportSend for PatternSend{
    async fn send(&self,data:&[u8])->Result<()>{
        let planned={self.replies.lock().unwrap().pop_front().ok_or_else(invalid)?};
        let reply=if u16_at(data,12)==14&&u16_at(data,90)==0{
            self.empty.fetch_add(1,Ordering::AcqRel);
            let mut body=vec![0;9];body[..2].copy_from_slice(&9u16.to_le_bytes());frame(Command::QueryDirectory,0xc0000033,body)
        }else{planned};
        self.mock.queue_response(reply);crate::transport::TransportSend::send(self.mock.as_ref(),data).await
    }
}
pub(super) async fn continuation_run()->Result<usize>{
    let mock=Arc::new(MockTransport::new());mock.enable_auto_rewrite_msg_id();let rows=[listed("Member.txt",false,101,3)];
    let mut replies=open_dir(root(),100);replies.extend(root_contents(&rows));replies.push(close(0));
    let send=Arc::new(PatternSend{mock:Arc::clone(&mock),replies:Mutex::new(replies.into()),empty:AtomicU64::new(0)});
    struct Sender(Arc<PatternSend>);
    #[async_trait::async_trait]impl crate::transport::TransportSend for Sender{async fn send(&self,data:&[u8])->Result<()>{self.0.send(data).await}}
    let mut conn=Connection::from_transport(Box::new(Sender(Arc::clone(&send))),Box::new(mock.clone()),"generated.invalid");
    let policy=SelectedFolderPolicy::new();conn.set_selected_folder_policy(Arc::clone(&policy))?;
    conn.set_test_params(NegotiatedParams{dialect:Dialect::Smb3_1_1,max_read_size:65536,max_write_size:65536,max_transact_size:65536,
        server_guid:Guid::ZERO,signing_required:false,capabilities:Capabilities::default(),gmac_negotiated:false,cipher:None,compression_supported:false});
    conn.set_session_id(SessionId(SESSION));conn.set_credits(4096);conn.set_reviver(None);conn.set_keepalive(None);conn.set_response_timeout(Some(std::time::Duration::from_millis(250)));
    let(owner,directory)=CheckedFolderReader::prepare(conn.clone(),TREE,&[70],0x10,300).await?;
    let result=owner.children(&directory).await;
    if result.is_ok(){owner.close(directory).await?;owner.finish()?;}else{drop(owner);}
    drain(&conn,&mock).await;
    // The uncorrected reader receives STATUS_OBJECT_NAME_INVALID here. Actual
    // source/connection/transport bytes, not a duplicate request implementation.
    assert!(result.is_ok(),"actual continuation rejected by Samba-like peer");
    assert_eq!(send.empty.load(Ordering::Acquire),0);assert!(result.unwrap()==rows.iter().map(|r|FolderEntry{name:r.file_name.encode_utf16().collect(),attributes:r.file_attributes,size:r.end_of_file,allocated:r.allocation_size,modified:r.last_write_time.0,changed:r.change_time.0,index:r.file_id.unwrap()}).collect::<Vec<_>>());
    let requests=mock.sent_messages().into_iter().filter(|r|u16_at(r,12)==14).collect::<Vec<_>>();assert_eq!(requests.len(),2);assert_eq!((requests[0][67],requests[1][67]),(1,0));
    assert!(requests.iter().all(|r|u16_at(r,90)==2&&r[96..]==[42,0]));
    let p=SelectedFolderPolicy::new();p.begin(TREE,SESSION)?;p.expect(Expected::Open(vec![70,0]))?;p.opened(root())?;p.expect(Expected::List(root(),false,65536))?;
    let query=QueryDirectoryRequest{file_information_class:FileInformationClass::FileIdBothDirectoryInformation,flags:QueryDirectoryFlags(0),file_index:0,file_id:root(),output_buffer_length:65536,file_name:"*".into()};
    let mut out=WriteCursor::new();header(Command::QueryDirectory,false).pack(&mut out);query.pack(&mut out);let good=out.into_inner();assert!(p.permits_frame(&good));
    let mut empty=good[..97].to_vec();empty[88..92].fill(0);empty[96]=0;assert!(!p.permits_frame(&empty));
    for at in[66,67,96]{let mut bad=good.clone();bad[at]^=1;assert!(!p.permits_frame(&bad));}
    Ok(6)
}
