//! Qualification-only signed-helper protocol v1. Fixed loopback generated peer.
//! No credentials, endpoint resolution, local paths or ordinary Connect entry.

use super::{common, from_transport};
use smb2::client::{DirectoryReader, Session, Tree};
use smb2::transport::TcpTransport;
use std::{future::Future, os::fd::AsFd, sync::Arc, time::{Duration, Instant}};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{UnixStream, unix::{OwnedReadHalf, OwnedWriteHalf}}};

#[derive(Clone, Copy)]
enum Issue { Remote, Deadline, Stop, IPC, Invalid }
impl Issue {
    fn name(self) -> &'static str {
        match self { Self::Remote => "remote-error", Self::Deadline => "request-deadline",
            Self::Stop => "stopped", Self::IPC => "ipc-closed", Self::Invalid => "invalid-result" }
    }
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
        value = future => value.map_err(|_| Issue::Remote),
        value = input.read_u8() => match value { Ok(b'S') => Err(Issue::Stop), _ => Err(Issue::IPC) },
        _ = tokio::time::sleep(Duration::from_secs(10)) => Err(Issue::Deadline),
    }
}

struct Output { stream: OwnedWriteHalf, session: String, sequence: u64 }
impl Output {
    async fn emit(&mut self, read: Option<&str>, payload: &str, deadline: tokio::time::Instant) -> Result<(), Issue> {
        let value = format!("MEXSMB1 {} {} {} {payload}\n", self.session, read.unwrap_or("-"), self.sequence);
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
    if fields.len() != 3 || fields[0] != "MEXSMB1" || fields[1] != "START" || !uuid(fields[2]) { return 2; }
    let mut output = Output { stream, session: fields[2].to_string(), sequence: 0 };
    let transport = match operation(TcpTransport::connect("127.0.0.1:15445", Duration::from_secs(10)), &mut input).await {
        Ok(value) => Arc::new(value), Err(error) => {
            let _ = output.event(None, &format!("closed {} 0 0 0 0 0", error.name())).await;
            return 2;
        },
    };
    let (mut conn, sent) = from_transport(transport);
    let mut reader: Option<DirectoryReader> = None;
    let mut active: Option<String> = None;
    let mut observed = 0usize;
    let outcome: Result<(), Issue> = async {
        operation(conn.negotiate(), &mut input).await?;
        let session = operation(Session::setup(&mut conn, "Guest", "", ""), &mut input).await?;
        if session.should_encrypt || session.should_sign { return Err(Issue::Invalid); }
        let tree = operation(Tree::connect(&mut conn, "ExplorerQA"), &mut input).await?;
        if tree.is_dfs || tree.encrypt_data || tree.dfs_origin.is_some() { return Err(Issue::Invalid); }
        output.event(None, "connected").await?;
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
    drop(conn); tokio::task::yield_now().await;
    let tasks = tokio::runtime::Handle::current().metrics().num_alive_tasks();
    let commands = sent.iter().map(|n| n.load(std::sync::atomic::Ordering::Relaxed).to_string()).collect::<Vec<_>>().join(",");
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
}
