//! Authenticated generated-only protocol v2. Credentials use inherited private IPC.
//! Fixed loopback endpoint; no ordinary Connect or saved-secret access.

use super::{common, from_transport};
use smb2::crypto::encryption::Cipher;
use smb2::client::{DirectoryReader, Session, Tree};
use smb2::transport::TcpTransport;
use std::{future::Future, os::fd::AsFd, sync::Arc, time::{Duration, Instant}};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{UnixStream, unix::{OwnedReadHalf, OwnedWriteHalf}}};

#[derive(Clone, Copy)]
enum Issue { Remote, Deadline, Stop, IPC, Invalid, Authentication, Denied, Security }
impl Issue {
    fn name(self) -> &'static str {
        match self { Self::Remote => "remote-error", Self::Deadline => "request-deadline",
            Self::Stop => "stopped", Self::IPC => "ipc-closed", Self::Invalid => "invalid-result",
            Self::Authentication => "authentication", Self::Denied => "denied", Self::Security => "security" }
    }
}

fn remote_issue(error: smb2::Error) -> Issue {
    use smb2::{Error, types::status::NtStatus};
    match error {
        Error::Protocol { status, .. } if status == NtStatus::LOGON_FAILURE => Issue::Authentication,
        Error::Protocol { status, .. } if status == NtStatus::ACCESS_DENIED => Issue::Denied,
        Error::GuestSessionRefused { .. } | Error::SignatureInvalid { .. } => Issue::Security,
        Error::InvalidData { .. } => Issue::Invalid,
        _ => Issue::Remote,
    }
}

struct Credentials { account: String, password: String, domain: String }
fn hex(value: &str, cap: usize, optional: bool) -> Result<String, Issue> {
    if optional && value == "-" { return Ok(String::new()); }
    if value.is_empty() || value.len() % 2 != 0 || value.len() > cap * 2
        || !value.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) { return Err(Issue::Invalid); }
    let bytes = (0..value.len()).step_by(2).map(|i| u8::from_str_radix(&value[i..i+2], 16).map_err(|_| Issue::Invalid))
        .collect::<Result<Vec<_>, _>>()?;
    if bytes.contains(&0) { return Err(Issue::Invalid); }
    String::from_utf8(bytes).map_err(|_| Issue::Invalid)
}
fn decode_credentials(value: &str) -> Result<Credentials, Issue> {
    let parts: Vec<_> = value.split(' ').collect();
    if parts.len() != 4 || parts[0] != "CREDENTIALS" { return Err(Issue::Invalid); }
    let account = hex(parts[1], 256, false)?;
    if account.eq_ignore_ascii_case("guest") || account.eq_ignore_ascii_case("anonymous") { return Err(Issue::Invalid); }
    Ok(Credentials { account, password: hex(parts[2], 4096, false)?, domain: hex(parts[3], 256, true)? })
}
async fn credentials(input: &mut OwnedReadHalf) -> Result<Credentials, Issue> {
    decode_credentials(&line(input, 9300).await?)
}

fn encrypt(conn: &mut smb2::client::Connection, session: &Session) -> Result<(), Issue> {
    // Never reset the nonce generator by reactivating an already-live cipher.
    if conn.should_encrypt() { return Ok(()); }
    if conn.params().and_then(|p| p.cipher) != Some(Cipher::Aes128Gcm) { return Err(Issue::Security); }
    let enc = session.encryption_key.clone().ok_or(Issue::Security)?;
    let dec = session.decryption_key.clone().ok_or(Issue::Security)?;
    conn.activate_encryption(enc, dec, Cipher::Aes128Gcm); Ok(())
}

fn uuid(value: &str) -> bool {
    value.len() == 36 && value.bytes().enumerate().all(|(i, c)|
        if [8, 13, 18, 23].contains(&i) { c == b'-' } else { c.is_ascii_digit() || (b'A'..=b'F').contains(&c) })
        && value != "00000000-0000-0000-0000-000000000000"
}

async fn line(input: &mut OwnedReadHalf, maximum: usize) -> Result<String, Issue> {
    let mut value = Vec::new();
    loop {
        let byte = input.read_u8().await.map_err(|_| Issue::IPC)?;
        if value.is_empty() && byte == b'S' { return Err(Issue::Stop); }
        if byte == b'\n' { return String::from_utf8(value).map_err(|_| Issue::Invalid); }
        if value.len() == maximum || !byte.is_ascii_graphic() && byte != b' ' { return Err(Issue::Invalid); }
        value.push(byte);
    }
}

async fn operation<T>(future: impl Future<Output = smb2::Result<T>>, input: &mut OwnedReadHalf) -> Result<T, Issue> {
    tokio::select! {
        value = future => value.map_err(remote_issue),
        value = input.read_u8() => match value { Ok(b'S') => Err(Issue::Stop), _ => Err(Issue::IPC) },
        _ = tokio::time::sleep(Duration::from_secs(10)) => Err(Issue::Deadline),
    }
}

struct Output { stream: OwnedWriteHalf, session: String, sequence: u64 }
impl Output {
    async fn emit(&mut self, read: Option<&str>, payload: &str, deadline: tokio::time::Instant) -> Result<(), Issue> {
        let value = format!("MEXSMB2 {} {} {} {payload}\n", self.session, read.unwrap_or("-"), self.sequence);
        if value.len() > 16_512 || self.sequence > 1_000_000 { return Err(Issue::Invalid); }
        tokio::time::timeout_at(deadline, self.stream.write_all(value.as_bytes())).await
            .map_err(|_| Issue::Deadline)?.map_err(|_| Issue::IPC)?;
        self.sequence += 1;
        Ok(())
    }
    async fn event(&mut self, read: Option<&str>, payload: &str) -> Result<(), Issue> {
        self.emit(read, payload, tokio::time::Instant::now() + Duration::from_millis(500)).await
    }
}

async fn execute(stream: UnixStream) -> i32 {
    let (mut input, stream) = stream.into_split();
    let hello = match tokio::time::timeout(Duration::from_secs(5), line(&mut input, 96)).await {
        Ok(Ok(value)) => value, _ => return 2,
    };
    let fields: Vec<_> = hello.split(' ').collect();
    if fields.len() != 5 || fields[0] != "MEXSMB2" || fields[1] != "START" || !uuid(fields[2])
        || !["encrypted", "signed"].contains(&fields[3])
        || !["ExplorerQA", "EncryptedQA", "DeniedQA"].contains(&fields[4]) { return 2; }
    let require_encryption = fields[3] == "encrypted";
    let mut output = Output { stream, session: fields[2].to_string(), sequence: 0 };
    let credentials = match tokio::time::timeout(Duration::from_secs(5), credentials(&mut input)).await {
        Ok(Ok(value)) => value, _ => return 2,
    };
    let transport = match operation(TcpTransport::connect("127.0.0.1:15445", Duration::from_secs(10)), &mut input).await {
        Ok(value) => Arc::new(value), Err(error) => {
            let commands = ["0"; 19].join(",");
            let _ = output.event(None, &format!("closed {} 0 0 0 0 0 {commands}", error.name())).await;
            return 0;
        },
    };
    let (mut conn, _plain, _transforms) = from_transport(transport);
    let mut reader: Option<DirectoryReader> = None;
    let mut active: Option<String> = None;
    let mut observed = 0usize;
    let outcome: Result<(), Issue> = async {
        operation(conn.b10_negotiate(require_encryption), &mut input).await?;
        let session = operation(Session::setup(&mut conn, &credentials.account, &credentials.password, &credentials.domain), &mut input).await?;
        drop(credentials);
        if !session.should_sign { return Err(Issue::Security); }
        if require_encryption { encrypt(&mut conn, &session)?; }
        let tree = operation(Tree::connect(&mut conn, fields[4]), &mut input).await?;
        if tree.is_dfs || tree.dfs_origin.is_some() { return Err(Issue::Security); }
        if tree.encrypt_data { encrypt(&mut conn, &session)?; }
        output.event(None, if conn.should_encrypt() { "connected encrypted" } else { "connected signed" }).await?;
        let mut seen = std::collections::HashSet::new();
        for _ in 0..64 {
            let command = line(&mut input, 128).await?;
            let parts: Vec<_> = command.split(' ').collect();
            if parts.len() != 3 || parts[0] != "READ" || !uuid(parts[1]) || !seen.insert(parts[1].to_string()) {
                return Err(Issue::Invalid);
            }
            let path = match parts[2] { "-" => "", "0046006f006c006400650072" => "Folder", _ => return Err(Issue::Invalid) };
            active = Some(parts[1].to_string());
            let id = active.as_deref();
            reader = Some(operation(tree.open_directory_reader(conn.clone(), path), &mut input).await?);
            let mut count = 0usize;
            let mut retained = 0usize;
            let mut page = 0usize;
            let mut batches = 0usize;
            loop {
                let batch = operation(reader.as_mut().ok_or(Issue::Invalid)?.next_batch(), &mut input).await?;
                let entries = match batch { Some(value) => value, None => break };
                batches += 1;
                if batches > 32 { return Err(Issue::Invalid); }
                let mut admitted = Vec::new();
                for entry in entries {
                    let name = String::from_utf16(&entry.qualification_wire_name).map_err(|_| Issue::Invalid)?;
                    if name == "." || name == ".." { continue; }
                    if !common::permitted_name(&name) { return Err(Issue::Invalid); }
                    count += 1; observed += 1;
                    retained += name.len() + entry.qualification_wire_name.len() * 2 + 128;
                    if count > 4096 || retained > 8 * 1024 * 1024 { return Err(Issue::Invalid); }
                    admitted.push(entry);
                }
                for chunk in admitted.chunks(256) {
                    let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
                    for entry in chunk {
                        let wire: String = entry.qualification_wire_name.iter().map(|n| format!("{n:04x}")).collect();
                        output.emit(id, &format!("row {} {} {wire}", entry.attributes.bits(), entry.size), deadline).await?;
                    }
                    output.emit(id, &format!("page {page} {}", chunk.len()), deadline).await?;
                    match input.read_u8().await {
                        Ok(b'N') => {}, Ok(b'S') => return Err(Issue::Stop), _ => return Err(Issue::IPC),
                    }
                    page += 1;
                }
            }
            reader = None;
            output.event(id, &format!("readEnd {count}")).await?;
            active = None;
        }
        Err(Issue::Invalid)
    }.await;
    let began = Instant::now();
    conn.mark_dead(); drop(reader.take());
    let joined = match tokio::time::timeout(Duration::from_secs(2), conn.qualification_stop_and_join()).await {
        Ok(Ok(value)) => value, _ => return 3,
    };
    let pending = conn.outstanding_requests().len();
    let counts = conn.b10_command_counts();
    drop(conn); tokio::task::yield_now().await;
    let tasks = tokio::runtime::Handle::current().metrics().num_alive_tasks();
    let commands = counts.iter().map(|n| n.to_string()).collect::<Vec<_>>().join(",");
    let name = outcome.err().map(Issue::name).unwrap_or("closed");
    let _ = output.event(active.as_deref(), &format!("closed {name} {joined} {pending} {tasks} {observed} {} {commands}", began.elapsed().as_micros())).await;
    if joined == 4 && pending == 0 && tasks == 0 { 0 } else { 3 }
}

pub fn run() -> i32 {
    let descriptor = match std::io::stdin().as_fd().try_clone_to_owned() { Ok(value) => value, Err(_) => return 2 };
    let stream = std::os::unix::net::UnixStream::from(descriptor);
    if stream.peer_addr().is_err() || stream.set_nonblocking(true).is_err() { return 2; }
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() { Ok(value) => value, Err(_) => return 2 };
    runtime.block_on(async { match UnixStream::from_std(stream) { Ok(value) => execute(value).await, Err(_) => 2 } })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generation_admission_requires_exact_nonzero_uuid() {
        assert!(uuid("A1B2C3D4-1234-4567-8ABC-123456789ABC"));
        for invalid in ["a1b2c3d4-1234-4567-8abc-123456789abc", "00000000-0000-0000-0000-000000000000",
                        "A1B2C3D4X1234-4567-8ABC-123456789ABC", "short"] {
            assert!(!uuid(invalid));
        }
    }
    #[test]
    fn credentials_are_bounded_exact_and_never_accept_guest_or_null() {
        let admitted = decode_credentials("CREDENTIALS 75736572 67656e657261746564 -").unwrap_or_else(|_| panic!("Generated credentials refused"));
        assert_eq!(admitted.account, "user"); assert_eq!(admitted.password.len(), 9); assert!(admitted.domain.is_empty());
        for value in ["CREDENTIALS - 61 -", "CREDENTIALS 4775657374 61 -", "CREDENTIALS 61 00 -", "CREDENTIALS 61 ff -",
            "CREDENTIALS 61 1 -", "CREDENTIALS 61 61 - extra", "CREDENTIALS 61 61 00"] {
            assert!(decode_credentials(value).is_err());
        }
        assert!(decode_credentials(&format!("CREDENTIALS 61 {} -", "61".repeat(4097))).is_err());
    }
}
