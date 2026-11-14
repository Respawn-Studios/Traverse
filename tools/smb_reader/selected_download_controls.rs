//! Copied-build controls only. No socket, credential, local publication or UI.
use super::*;
use crate::{client::NegotiatedParams,transport::MockTransport,msg::header::Header,
    pack::Guid,types::{Dialect,SessionId,flags::Capabilities}};
const TREE:TreeId=TreeId(7);
const SESSION:u64=0x1234;
const FILE:FileId=FileId{persistent:5,volatile:6};
fn header(command:Command,response:bool)->Header {
    let mut h=Header::new_request(command);h.tree_id=Some(TREE);h.session_id=SessionId(SESSION);h.credits=32;
    if response{h.flags.set_response();}h
}
fn packed(h:&Header,body:&[u8])->Vec<u8>{let mut out=WriteCursor::new();h.pack(&mut out);out.write_bytes(body);out.into_inner()}
fn incoming(command:Command,status:u32,body:Vec<u8>)->Frame {
    let mut h=header(command,true);h.status=crate::types::status::NtStatus(status);
    let raw=packed(&h,&body);Frame{header:h,body,raw}
}
fn create(size:u64)->Vec<u8> {
    let mut body=vec![0;88];body[..2].copy_from_slice(&89u16.to_le_bytes());body[4..8].copy_from_slice(&1u32.to_le_bytes());
    for (at,value)in [(8,100u64),(24,300),(32,400),(40,size.next_multiple_of(4096)),(48,size),(64,5),(72,6)]{body[at..at+8].copy_from_slice(&value.to_le_bytes());}
    body[56..60].copy_from_slice(&0x20u32.to_le_bytes());incoming(Command::Create,0,body).raw
}
fn metadata(size:u64)->Vec<Vec<u8>> {
    let mut basic=vec![0;40];for(at,value)in [(0,100u64),(8,200),(16,300),(24,400)]{basic[at..at+8].copy_from_slice(&value.to_le_bytes());}
    basic[32..36].copy_from_slice(&0x20u32.to_le_bytes());
    let mut standard=vec![0;24];standard[..8].copy_from_slice(&size.next_multiple_of(4096).to_le_bytes());standard[8..16].copy_from_slice(&size.to_le_bytes());standard[16]=1;
    let mut volume=vec![0;18];volume[..8].copy_from_slice(&500u64.to_le_bytes());volume[8]=13;volume[16]=1;
    [basic,standard,42u64.to_le_bytes().to_vec(),volume].into_iter().map(|bytes|query_frame(bytes,0).raw).collect()
}
fn query_frame(bytes:Vec<u8>,padding:usize)->Frame {
    let mut body=vec![0;8+padding];body[..2].copy_from_slice(&9u16.to_le_bytes());body[2..4].copy_from_slice(&((72+padding)as u16).to_le_bytes());
    body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend(bytes);incoming(Command::QueryInfo,0,body)
}
fn read_frame(bytes:Vec<u8>,padding:usize)->Frame {
    let mut body=vec![0;16+padding];body[..2].copy_from_slice(&17u16.to_le_bytes());body[2]=(80+padding)as u8;
    body[4..8].copy_from_slice(&(bytes.len()as u32).to_le_bytes());body.extend(bytes);incoming(Command::Read,0,body)
}
fn eof()->Frame{let mut body=vec![0;9];body[..2].copy_from_slice(&9u16.to_le_bytes());incoming(Command::Read,0xc0000011,body)}
fn close(status:u32)->Vec<u8>{let mut body=vec![0;60];body[..2].copy_from_slice(&60u16.to_le_bytes());incoming(Command::Close,status,body).raw}
fn setup(enabled:bool)->(Connection,Arc<MockTransport>,Arc<SelectedDownloadPolicy>){
    let mock=Arc::new(MockTransport::new());mock.enable_auto_rewrite_msg_id();
    let mut conn=Connection::from_transport(Box::new(mock.clone()),Box::new(mock.clone()),"generated.invalid");
    let policy=SelectedDownloadPolicy::new();if enabled{conn.set_selected_download_policy(Arc::clone(&policy)).unwrap();}
    conn.set_test_params(NegotiatedParams{dialect:Dialect::Smb3_1_1,max_read_size:65536,max_write_size:65536,max_transact_size:65536,
        server_guid:Guid::ZERO,signing_required:false,capabilities:Capabilities::default(),gmac_negotiated:false,cipher:None,compression_supported:false});
    conn.set_session_id(SessionId(SESSION));conn.set_credits(512);conn.set_reviver(None);conn.set_keepalive(None);
    conn.set_response_timeout(Some(std::time::Duration::from_millis(300)));(conn,mock,policy)
}
fn open_request(name:&[u16])->Vec<u8>{let mut body=WriteCursor::new();ExactOpen(name).pack(&mut body);packed(&header(Command::Create,false),&body.into_inner())}
fn parser_controls()->usize {
    let mut count=0;
    for length in [1,32767,32768]{for pad in [0,7,31]{
        let frame=read_frame(vec![91;length],pad);assert_eq!(read_bytes(&frame,length as u32,TREE,SESSION).unwrap().unwrap(),vec![91;length]);count+=1;
    }}
    let good=read_frame(vec![91;4],3);
    for at in [4,12,16,20,36,40,64,66,68,72,76]{
        let mut bad=incoming(Command::Read,0,good.body.clone());bad.raw[at]^=0x40;bad.body=bad.raw[64..].to_vec();
        assert!(read_bytes(&bad,4,TREE,SESSION).is_err());count+=1;
    }
    for length in 0..good.raw.len(){let mut bad=incoming(Command::Read,0,good.body.clone());bad.raw.truncate(length);bad.body=if length>=64{bad.raw[64..].to_vec()}else{vec![]};assert!(read_bytes(&bad,4,TREE,SESSION).is_err());count+=1;}
    for requested in [0,3,CHUNK+1]{assert!(read_bytes(&good,requested,TREE,SESSION).is_err());count+=1;}
    assert!(read_bytes(&read_frame(vec![],0),1,TREE,SESSION).is_err());count+=1;
    assert!(read_bytes(&eof(),1,TREE,SESSION).unwrap().is_none());count+=1;
    for at in [64,66,68,72]{let mut bad=eof();bad.raw[at]^=1;bad.body=bad.raw[64..].to_vec();assert!(read_bytes(&bad,1,TREE,SESSION).is_err());count+=1;}
    for pad in [0,8,32]{let q=query_frame(vec![17;40],pad);assert_eq!(query_bytes(&q,40,TREE,SESSION).unwrap(),vec![17;40]);count+=1;}
    let q=query_frame(vec![17;40],0);
    for at in [64,66,68]{let mut bad=incoming(Command::QueryInfo,0,q.body.clone());bad.raw[at]^=1;bad.body=bad.raw[64..].to_vec();assert!(query_bytes(&bad,40,TREE,SESSION).is_err());count+=1;}
    count
}
fn policy_controls()->usize {
    let mut count=0;let policy=SelectedDownloadPolicy::new();let name="Folder\\Generated.txt".encode_utf16().collect::<Vec<_>>();
    let good=open_request(&name);assert!(!policy.permits_frame(&good));count+=1;
    for bad in ["", "\\name", "a\\..\\x", "a\\\\x", "a/b", "a:x", "a.", "a ", "a\n", "*"]{assert!(policy.begin(TREE,SESSION,&bad.encode_utf16().collect::<Vec<_>>()).is_err());count+=1;}
    assert!(policy.begin(TREE,SESSION,&[0xd800]).is_err());count+=1;
    policy.begin(TREE,SESSION,&name).unwrap();assert!(policy.permits_frame(&good));assert!(policy.begin(TREE,SESSION,&name).is_err());count+=2;
    for at in [12,16,20,36,40,64,66,68,72,88,92,96,100,104,108,110,112,116,120]{let mut bad=good.clone();bad[at]^=1;assert!(!policy.permits_frame(&bad));count+=1;}
    let mut extra=good.clone();extra.extend([0;8]);assert!(!policy.permits_frame(&extra));count+=1;
    policy.opened(FILE).unwrap();assert!(!policy.permits_frame(&good));count+=1;
    policy.expect(Expected::Read(0,32)).unwrap();
    let request=ReadRequest{padding:0,flags:0,length:32,offset:0,file_id:FILE,minimum_count:0,channel:0,remaining_bytes:0,read_channel_info:vec![]};
    let mut body=WriteCursor::new();request.pack(&mut body);let good=packed(&header(Command::Read,false),&body.into_inner());assert!(policy.permits_frame(&good));count+=1;
    for at in [12,20,36,40,64,66,67,68,72,80,88,96,100,104,108,110,112]{let mut bad=good.clone();bad[at]^=1;assert!(!policy.permits_frame(&bad));count+=1;}
    for command in [7u16,9,10,11,15,17,18]{let mut bad=good.clone();bad[12..14].copy_from_slice(&command.to_le_bytes());assert!(!policy.permits_frame(&bad));count+=1;}
    policy.acknowledged().unwrap();assert!(!policy.permits_frame(&good));policy.poison();assert!(!policy.permits_frame(&good));count+=2;
    count
}
async fn drain(conn:&Connection,mock:&MockTransport){mock.close();assert_eq!(conn.qualification_stop_and_join().await.unwrap(),4);assert!(conn.outstanding_requests().is_empty());}
async fn success_case(size:usize)->usize {
    let (conn,mock,policy)=setup(true);let source=(0..size).map(|n|(n%251)as u8).collect::<Vec<_>>();
    let mut replies=vec![create(size as u64)];replies.extend(metadata(size as u64));
    // Deliberate short positive READs prove advancement by actual returned bytes.
    let mut cursor=0;let mut expected_lengths=vec![];
    while cursor<size{let length=(size-cursor).min(CHUNK as usize).min(16001);replies.push(read_frame(source[cursor..cursor+length].to_vec(),5).raw);expected_lengths.push(length);cursor+=length;}
    replies.push(eof().raw);replies.extend(metadata(size as u64));replies.push(close(0));mock.queue_responses(replies);
    let name="Folder\\Generated.txt".encode_utf16().collect::<Vec<_>>();
    let mut reader=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:size as u64,modified:300}).await.unwrap();
    assert_eq!(reader.snapshot().index,42);let mut result=vec![];
    while result.len()<size{result.extend(reader.read_chunk().await.unwrap());}
    assert_eq!(result,source);assert_eq!(reader.finish().await.unwrap().size,size as u64);
    assert!(matches!(*policy.state.lock().unwrap(),State::Idle));
    let sent=mock.sent_messages();assert_eq!(sent.len(),11+expected_lengths.len());
    let reads=sent.iter().filter(|v|u16_at(v,12)==8).collect::<Vec<_>>();assert_eq!(reads.len(),expected_lengths.len()+1);
    assert_eq!(u64_at(reads.last().unwrap(),72),size as u64);assert_eq!(u32_at(reads.last().unwrap(),68),1);
    for request in sent{assert!(matches!(u16_at(&request,12),5|6|8|16));}
    drain(&conn,&mock).await;1
}
async fn failed_finish(kind:u8)->usize {
    let (conn,mock,policy)=setup(true);let mut replies=vec![create(0)];replies.extend(metadata(0));
    if kind==0{replies.push(read_frame(vec![71],0).raw);}else{
        replies.push(eof().raw);let mut after=metadata(0);
        if kind==1{after[2][72]^=1;} // Same open's filesystem identity changes.
        replies.extend(after);if kind==2{replies.push(close(0xc0000128));}
    }
    mock.queue_responses(replies);let name="Generated.txt".encode_utf16().collect::<Vec<_>>();
    let reader=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:0,modified:300}).await.unwrap();
    assert!(reader.finish().await.is_err());assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));drain(&conn,&mock).await;1
}
async fn cancel_case(stage:u8)->usize {
    let (conn,mock,policy)=setup(true);let name="Generated.txt".encode_utf16().collect::<Vec<_>>();
    if stage==2{mock.queue_response(create(1));}
    else if stage>0{let size=if stage==1{1}else{0};let mut replies=vec![create(size)];replies.extend(metadata(size));
        if stage>=4{replies.push(eof().raw);}if stage==5{replies.extend(metadata(size));}mock.queue_responses(replies);}
    if stage==0||stage==2{
        let open=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:1,modified:300});
        assert!(tokio::time::timeout(std::time::Duration::from_millis(25),open).await.is_err());
    }else if stage==1{
        let mut reader=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:1,modified:300}).await.unwrap();
        assert!(tokio::time::timeout(std::time::Duration::from_millis(25),reader.read_chunk()).await.is_err());drop(reader);
    }else{
        let reader=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:0,modified:300}).await.unwrap();
        assert!(tokio::time::timeout(std::time::Duration::from_millis(25),reader.finish()).await.is_err());
    }
    assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));drain(&conn,&mock).await;1
}
async fn prepare_bounds(kind:u8)->usize {
    let(conn,mock,policy)=setup(true);let size=if kind==7{MAX_FILE}else{1};
    let mut replies=vec![create(size)];let mut facts=metadata(size);
    match kind {
        0=>facts[2][72..80].fill(0),1=>facts[3][80..84].fill(0),
        2=>facts[1][92]=1,3=>facts[1][93]=1,
        4=>replies[0][120]|=0x10,5=>replies[0][121]|=4,
        6=>replies[0][96]^=1,7=>{},_=>unreachable!(),
    }
    replies.extend(facts);mock.queue_responses(replies);let name="Generated.txt".encode_utf16().collect::<Vec<_>>();
    let result=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size,modified:300}).await;
    if kind==7{let reader=result.unwrap();assert_eq!(reader.snapshot().size,MAX_FILE);drop(reader);}else{assert!(result.is_err());}
    assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));
    assert!(!mock.sent_messages().iter().any(|v|u16_at(v,12)==8));drain(&conn,&mock).await;1
}
async fn connection_claim()->usize {
    let (conn,mock,policy)=setup(true);let other=Arc::new(MockTransport::new());
    let mut second=Connection::from_transport(Box::new(other.clone()),Box::new(other.clone()),"other.generated.invalid");
    assert!(second.set_selected_download_policy(policy).is_err());assert!(other.sent_messages().is_empty());
    second.set_selected_download_policy(SelectedDownloadPolicy::new()).unwrap();
    assert!(second.set_selected_download_policy(SelectedDownloadPolicy::new()).is_err());
    drain(&second,&other).await;drain(&conn,&mock).await;1
}
async fn preadmission_refusals()->usize {
    let(conn,mock,policy)=setup(true);let mut count=0;
    for attrs in [0x10,0x40,0x400]{
        assert!(CheckedFileReader::prepare(conn.clone(),TREE,&[71],ListedFile{attributes:attrs,size:0,modified:300}).await.is_err());count+=1;
    }
    assert!(CheckedFileReader::prepare(conn.clone(),TREE,&[71],ListedFile{attributes:0x20,size:MAX_FILE+1,modified:300}).await.is_err());count+=1;
    for name in [vec![],vec![71;2049],vec![0xd800]]{
        assert!(CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:0,modified:300}).await.is_err());count+=1;
    }
    assert!(mock.sent_messages().is_empty());assert!(matches!(*policy.state.lock().unwrap(),State::Idle));drain(&conn,&mock).await;count
}
async fn release_prepared(lost_close:bool)->usize {
    let(conn,mock,policy)=setup(true);let mut replies=vec![create(42)];replies.extend(metadata(42));
    if !lost_close{replies.push(close(0));}mock.queue_responses(replies);
    let name="Generated.txt".encode_utf16().collect::<Vec<_>>();
    let reader=CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:42,modified:300}).await.unwrap();
    if lost_close{assert!(tokio::time::timeout(std::time::Duration::from_millis(25),reader.release()).await.is_err());
        assert!(matches!(*policy.state.lock().unwrap(),State::Poisoned));}
    else{reader.release().await.unwrap();assert!(matches!(*policy.state.lock().unwrap(),State::Idle));}
    let sent=mock.sent_messages();assert_eq!(sent.len(),6);assert!(!sent.iter().any(|v|u16_at(v,12)==8));drain(&conn,&mock).await;1
}
pub(super) async fn run()->Result<usize>{
    let mut checks=parser_controls()+policy_controls();
    for size in [0,1,32767,32768,32769]{checks+=success_case(size).await;}
    for kind in 0..3{checks+=failed_finish(kind).await;}
    for stage in 0..6{checks+=cancel_case(stage).await;}
    for kind in 0..8{checks+=prepare_bounds(kind).await;}
    checks+=connection_claim().await;checks+=preadmission_refusals().await;
    checks+=release_prepared(false).await;checks+=release_prepared(true).await;
    let(conn,mock,_)=setup(false);let name="Generated.txt".encode_utf16().collect::<Vec<_>>();
    assert!(CheckedFileReader::prepare(conn.clone(),TREE,&name,ListedFile{attributes:0x20,size:1,modified:300}).await.is_err());
    assert!(mock.sent_messages().is_empty());drain(&conn,&mock).await;checks+=1;
    Ok(checks)
}
