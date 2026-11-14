//! Mock-backed publication controls. No socket, credentials, or remote files.
use super::*;
use crate::{
    client::NegotiatedParams,
    msg::header::Header,
    pack::{Guid, WriteCursor, Pack},
    transport::MockTransport,
    types::{Dialect, SessionId, flags::Capabilities},
};

const TREE: TreeId = TreeId(7);
const SESSION: u64 = 0x1234;
const FILE: FileId = FileId { persistent: 5, volatile: 6 };
const CONTENT: &[u8] = b"generated upload bytes";

fn f2_child_rename_refused() -> bool {
    let policy = SelectedUploadPolicy::new();
    let root = "Folder\\.traverse-smb-upload-generated.part".encode_utf16().collect::<Vec<_>>();
    policy.folder_write_policy().begin(TREE, SESSION, &root).unwrap();
    *policy.state.lock().unwrap() = State::Active {
        tree: TREE.0, session: SESSION, file: Some(FILE), mode: UploadMode::PrivateFolderChild,
        expected: Expected::Held,
    };
    policy.expect(Expected::Rename(vec![1])).is_err()
}

#[test]
fn f2_private_child_cannot_issue_per_file_set_info_rename() {
    assert!(f2_child_rename_refused(),
        "F2's held destination-parent directory must not coexist with a child SET_INFO rename");
}
#[derive(Clone,Copy)]
enum Fault { None, ChangedIdentity, ChangedBody, MetadataDrift, OpenMetadataMismatch,
    HiddenTransition, HiddenAddition, HiddenPlusSystemRemoval, HiddenToDot }

fn incoming(command: Command, status: u32, body: Vec<u8>) -> Vec<u8> {
    let mut header = Header::new_request(command);
    header.tree_id = Some(TREE);
    header.session_id = SessionId(SESSION);
    header.flags.set_response();
    header.status = NtStatus(status);
    header.credits = 32;
    let mut out = WriteCursor::new();
    header.pack(&mut out);
    out.write_bytes(&body);
    out.into_inner()
}

fn create(modified: u64, size: u64, attributes: u32) -> Vec<u8> {
    let mut body = vec![0; 88];
    body[..2].copy_from_slice(&89u16.to_le_bytes());
    body[4..8].copy_from_slice(&1u32.to_le_bytes());
    for (at, value) in [(8, 100u64), (24, modified), (32, 400), (40, 4096),
                        (48, size), (64, 5), (72, 6)] {
        body[at..at + 8].copy_from_slice(&value.to_le_bytes());
    }
    body[56..60].copy_from_slice(&attributes.to_le_bytes());
    incoming(Command::Create, 0, body)
}

fn directory_create(id: FileId) -> Vec<u8> {
    let mut body = vec![0; 88];
    body[..2].copy_from_slice(&89u16.to_le_bytes());
    body[4..8].copy_from_slice(&2u32.to_le_bytes());
    for (at, value) in [(8, 100u64), (24, 300), (32, 400),
                        (64, id.persistent), (72, id.volatile)] {
        body[at..at + 8].copy_from_slice(&value.to_le_bytes());
    }
    body[56..60].copy_from_slice(&0x10u32.to_le_bytes());
    incoming(Command::Create, 0, body)
}

fn new_file_create() -> Vec<u8> {
    let mut frame = create(300, 0, 0x20);
    frame[68..72].copy_from_slice(&2u32.to_le_bytes());
    frame
}

fn directory_metadata(index: u64) -> Vec<Vec<u8>> {
    let mut basic = vec![0; 40];
    for (at, value) in [(0, 100u64), (8, 200), (16, 300), (24, 400)] {
        basic[at..at + 8].copy_from_slice(&value.to_le_bytes());
    }
    basic[32..36].copy_from_slice(&0x10u32.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[16] = 2;
    standard[21] = 1;
    let mut volume = vec![0; 18];
    volume[..8].copy_from_slice(&500u64.to_le_bytes());
    volume[8] = 13;
    volume[16] = 1;
    [basic, standard, index.to_le_bytes().to_vec(), volume]
        .into_iter().map(query).collect()
}

fn write(count: usize) -> Vec<u8> {
    let mut body = vec![0; 16];
    body[..2].copy_from_slice(&17u16.to_le_bytes());
    body[4..8].copy_from_slice(&(count as u32).to_le_bytes());
    incoming(Command::Write, 0, body)
}

fn flush() -> Vec<u8> {
    let mut body = vec![0; 4];
    body[..2].copy_from_slice(&4u16.to_le_bytes());
    incoming(Command::Flush, 0, body)
}

fn query(bytes: Vec<u8>) -> Vec<u8> {
    let mut body = vec![0; 8];
    body[..2].copy_from_slice(&9u16.to_le_bytes());
    body[2..4].copy_from_slice(&72u16.to_le_bytes());
    body[4..8].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
    body.extend(bytes);
    incoming(Command::QueryInfo, 0, body)
}

fn metadata(modified: u64, size: u64, attributes: u32) -> Vec<Vec<u8>> {
    let mut basic = vec![0; 40];
    for (at, value) in [(0, 100u64), (8, 200), (16, modified), (24, 400)] {
        basic[at..at + 8].copy_from_slice(&value.to_le_bytes());
    }
    basic[32..36].copy_from_slice(&attributes.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[..8].copy_from_slice(&4096u64.to_le_bytes());
    standard[8..16].copy_from_slice(&size.to_le_bytes());
    standard[16] = 1;
    let mut volume = vec![0; 18];
    volume[..8].copy_from_slice(&500u64.to_le_bytes());
    volume[8] = 13;
    volume[16] = 1;
    [basic, standard, 42u64.to_le_bytes().to_vec(), volume]
        .into_iter().map(query).collect()
}

fn read(bytes: &[u8]) -> Vec<u8> {
    let mut body = vec![0; 16];
    body[..2].copy_from_slice(&17u16.to_le_bytes());
    body[2] = 80;
    body[4..8].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
    body.extend_from_slice(bytes);
    incoming(Command::Read, 0, body)
}

fn eof() -> Vec<u8> {
    let mut body = vec![0; 9];
    body[..2].copy_from_slice(&9u16.to_le_bytes());
    incoming(Command::Read, 0xc0000011, body)
}

fn close() -> Vec<u8> {
    let mut body = vec![0; 60];
    body[..2].copy_from_slice(&60u16.to_le_bytes());
    incoming(Command::Close, 0, body)
}

fn stage_snapshot() -> FileSnapshot {
    FileSnapshot { size: CONTENT.len() as u64, allocated: 4096, created: 100,
        modified: 300, changed: 400, attributes: 0x20, links: 1,
        index: 42, volume_created: 500, volume_serial: 13 }
}

async fn publication_with_final_modified(modified: u64, fault: Fault) -> Result<Publication> {
    let mock = Arc::new(MockTransport::new());
    mock.enable_auto_rewrite_msg_id();
    let mut conn = Connection::from_transport(Box::new(mock.clone()), Box::new(mock.clone()), "generated.invalid");
    let policy = SelectedUploadPolicy::new();
    conn.set_selected_upload_policy(Arc::clone(&policy))?;
    conn.set_test_params(NegotiatedParams { dialect: Dialect::Smb3_1_1,
        max_read_size: 65536, max_write_size: 65536, max_transact_size: 65536,
        server_guid: Guid::ZERO, signing_required: false, capabilities: Capabilities::default(),
        gmac_negotiated: false, cipher: None, compression_supported: false });
    conn.set_session_id(SessionId(SESSION));
    conn.set_credits(512);
    conn.set_reviver(None);
    conn.set_keepalive(None);
    conn.set_response_timeout(Some(std::time::Duration::from_millis(300)));
    let stage = "Folder\\.traverse-smb-upload-generated.part".encode_utf16().collect();
    let final_path = (if matches!(fault, Fault::HiddenToDot) { "Folder\\.Final.bin" }
        else { "Folder\\Final.bin" }).encode_utf16().collect();
    *policy.state.lock().unwrap() = State::Active {
        tree: TREE.0, session: SESSION, file: Some(FILE), mode: UploadMode::SeparateStage,
        expected: Expected::Held,
    };
    let upload = CheckedStagedUpload { conn: conn.clone(), policy: Arc::clone(&policy),
        tree: TREE, session: SESSION, file: Some(FILE), stage, final_path, mode: UploadMode::SeparateStage,
        size: CONTENT.len() as u64, written: CONTENT.len() as u64, ended: false };

    let final_attributes = if matches!(fault, Fault::HiddenAddition) { 0x22 } else { 0x20 };
    let mut replies = vec![incoming(Command::SetInfo, 0, 2u16.to_le_bytes().to_vec())];
    replies.extend(metadata(300, CONTENT.len() as u64, final_attributes));
    replies.push(close());
    replies.push(create(modified, CONTENT.len() as u64, final_attributes));
    let mut opened = metadata(modified + u64::from(matches!(fault, Fault::OpenMetadataMismatch)), CONTENT.len() as u64, final_attributes);
    if matches!(fault, Fault::ChangedIdentity) {
        opened[2][72..80].copy_from_slice(&43u64.to_le_bytes());
    }
    replies.extend(opened);
    let mut body = CONTENT.to_vec();
    if matches!(fault, Fault::ChangedBody) { body[0] ^= 1; }
    replies.push(read(&body));
    replies.push(eof());
    replies.extend(metadata(modified + u64::from(matches!(fault, Fault::MetadataDrift)), CONTENT.len() as u64, final_attributes));
    replies.push(close());
    mock.queue_responses(replies);

    let digest: [u8; 32] = Sha256::digest(CONTENT).into();
    let mut stage = stage_snapshot();
    if matches!(fault, Fault::HiddenTransition | Fault::HiddenToDot) { stage.attributes = 0x22; }
    if matches!(fault, Fault::HiddenPlusSystemRemoval) { stage.attributes = 0x26; }
    let result = upload.publish(stage, &digest).await;
    let sent = mock.sent_messages();
    mock.close();
    assert_eq!(conn.qualification_stop_and_join().await.unwrap(), 4);
    assert!(conn.outstanding_requests().is_empty());
    let reads = sent.iter().filter(|message| u16_at(message, 12) == Command::Read as u16).count();
    let closes = sent.iter().filter(|message| u16_at(message, 12) == Command::Close as u16).count();
    match fault {
        Fault::HiddenAddition | Fault::HiddenPlusSystemRemoval | Fault::HiddenToDot => {
            assert_eq!(reads, 0); assert_eq!(closes, 0);
        }
        Fault::ChangedIdentity | Fault::OpenMetadataMismatch => { assert_eq!(reads, 0); assert_eq!(closes, 1); }
        Fault::MetadataDrift => { assert_eq!(reads, 2); assert_eq!(closes, 1); }
        Fault::None | Fault::ChangedBody | Fault::HiddenTransition => { assert_eq!(reads, 2); assert_eq!(closes, 2); }
    }
    result
}

async fn private_folder_child_with_full_readback(tamper_final: bool) -> Result<()> {
    use crate::client::selected_folder_upload::CheckedStagedFolder;
    let mock = Arc::new(MockTransport::new());
    mock.enable_auto_rewrite_msg_id();
    let mut conn = Connection::from_transport(Box::new(mock.clone()), Box::new(mock.clone()), "generated.invalid");
    let policy = SelectedUploadPolicy::new();
    conn.set_selected_upload_policy(Arc::clone(&policy))?;
    conn.set_test_params(NegotiatedParams { dialect: Dialect::Smb3_1_1,
        max_read_size: 65536, max_write_size: 65536, max_transact_size: 65536,
        server_guid: Guid::ZERO, signing_required: false, capabilities: Capabilities::default(),
        gmac_negotiated: false, cipher: None, compression_supported: false });
    conn.set_session_id(SessionId(SESSION));
    conn.set_credits(512);
    conn.set_reviver(None);
    conn.set_keepalive(None);
    conn.set_response_timeout(Some(std::time::Duration::from_millis(300)));
    let root_id = FileId { persistent: 11, volatile: 12 };
    let nested_id = FileId { persistent: 13, volatile: 14 };
    let mut replies = vec![directory_create(root_id)];
    replies.extend(directory_metadata(100));
    replies.push(directory_create(nested_id));
    replies.push(new_file_create());
    replies.push(write(CONTENT.len()));
    replies.push(flush());
    replies.extend(metadata(300, CONTENT.len() as u64, 0x20));
    replies.push(read(CONTENT));
    replies.push(eof());
    replies.extend(metadata(300, CONTENT.len() as u64, 0x20));
    replies.extend(metadata(300, CONTENT.len() as u64, 0x20));
    replies.push(close());
    replies.push(create(300, CONTENT.len() as u64, 0x20));
    replies.extend(metadata(300, CONTENT.len() as u64, 0x20));
    let mut final_bytes = CONTENT.to_vec();
    if tamper_final { final_bytes[0] ^= 1; }
    replies.push(read(&final_bytes));
    replies.push(eof());
    replies.extend(metadata(300, CONTENT.len() as u64, 0x20));
    replies.push(close());
    if !tamper_final { replies.push(close()); }
    mock.queue_responses(replies);
    let stage = ".traverse-smb-upload-generated.part".encode_utf16().collect::<Vec<_>>();
    let name = "New Folder".encode_utf16().collect::<Vec<_>>();
    let parent = "Folder".encode_utf16().collect::<Vec<_>>();
    let folder = CheckedStagedFolder::create(conn.clone(), TREE, &parent, &stage, &name).await?;
    let nested_name = "Nested".encode_utf16().collect::<Vec<_>>();
    let nested = folder.create_child(folder.root()?, &nested_name).await?;
    let file_name = "Member.bin".encode_utf16().collect::<Vec<_>>();
    let mut upload = CheckedStagedUpload::create_private_child(conn.clone(), TREE,
        &folder.path(&nested), &file_name, CONTENT.len() as u64).await?;
    upload.write_chunk(CONTENT.to_vec()).await?;
    upload.flush().await?;
    let digest: [u8; 32] = Sha256::digest(CONTENT).into();
    let observed = upload.verify_stage(&digest).await?;
    let final_result = upload.finish_private_child(observed, &digest).await;
    if tamper_final { assert!(final_result.is_err()); }
    else { final_result?; folder.close_child(nested).await?; }
    let sent = mock.sent_messages();
    assert_eq!(sent.iter().filter(|v| u16_at(v, 12) == Command::SetInfo as u16).count(), 0);
    assert_eq!(sent.iter().filter(|v| u16_at(v, 12) == Command::Read as u16).count(), 4);
    assert_eq!(sent.iter().filter(|v| u16_at(v, 12) == Command::Close as u16).count(), if tamper_final {2} else {3});
    let file_create = sent.iter().filter(|v| u16_at(v, 12) == Command::Create as u16).nth(2).unwrap();
    assert_eq!(u32_at(file_create, 64 + 24), CHILD_ACCESS);
    assert!(file_create[120..].windows(file_name.len() * 2).any(|bytes| {
        bytes == file_name.iter().flat_map(|unit| unit.to_le_bytes()).collect::<Vec<_>>()
    }));
    drop(folder);
    mock.close();
    assert_eq!(conn.qualification_stop_and_join().await.unwrap(), 4);
    assert!(conn.outstanding_requests().is_empty());
    mock.assert_fully_consumed();
    Ok(())
}

pub(super) async fn run() -> Result<usize> {
    assert!(f2_child_rename_refused(),
        "F2's held destination-parent directory must not coexist with a child SET_INFO rename");
    assert!(matches!(publication_with_final_modified(300, Fault::None).await, Ok(Publication::Complete)),
        "stable last-write publication should complete");
    assert!(matches!(publication_with_final_modified(301, Fault::None).await, Ok(Publication::Complete)),
        "close-time last-write publication should complete");
    assert!(matches!(publication_with_final_modified(301, Fault::HiddenTransition).await, Ok(Publication::Complete)),
        "private dot-stage HIDDEN removal should complete after final readback");
    for fault in [Fault::ChangedIdentity, Fault::ChangedBody, Fault::MetadataDrift, Fault::OpenMetadataMismatch,
        Fault::HiddenAddition, Fault::HiddenPlusSystemRemoval, Fault::HiddenToDot] {
        assert!(publication_with_final_modified(301, fault).await.is_err(),
            "published final with changed identity or content must remain unverified");
    }
    private_folder_child_with_full_readback(false).await?;
    private_folder_child_with_full_readback(true).await?;
    Ok(12)
}
