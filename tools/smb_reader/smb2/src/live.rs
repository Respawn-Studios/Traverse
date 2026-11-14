//! Finite generated-share entry. No generic endpoint, credentials or file APIs.

use super::{common, from_transport};
use smb2::client::{DirectoryReader, Session, Tree};
use smb2::transport::TcpTransport;
use std::{future::Future, io::Write, os::fd::AsFd, sync::Arc, time::{Duration, Instant}};
use tokio::{io::AsyncReadExt, net::UnixStream};

#[derive(Debug)]
enum Issue { Remote, Deadline, Stop, IPC, Invalid }

async fn admitted<T>(operation: impl Future<Output = smb2::Result<T>>, control: &mut UnixStream) -> Result<T, Issue> {
    tokio::select! {
        result = operation => result.map_err(|_| Issue::Remote),
        message = control.read_u8() => match message {
            Ok(b'S') => Err(Issue::Stop),
            _ => Err(Issue::IPC),
        },
        _ = tokio::time::sleep(Duration::from_secs(10)) => Err(Issue::Deadline),
    }
}

async fn barrier(stage: &str, control: &mut UnixStream) -> Result<(), Issue> {
    println!("B10_STAGE {stage}");
    std::io::stdout().flush().map_err(|_| Issue::IPC)?;
    match tokio::time::timeout(Duration::from_secs(45), control.read_u8()).await {
        Ok(Ok(b'R')) => Ok(()),
        Ok(Ok(b'S')) => Err(Issue::Stop),
        _ => Err(Issue::IPC),
    }
}

fn publish(scope: &str, entries: Vec<smb2::DirectoryEntry>, total: &mut usize, retained: &mut usize) -> Result<(), Issue> {
    for entry in entries {
        let raw = String::from_utf16(&entry.qualification_wire_name).map_err(|_| Issue::Invalid)?;
        if raw == "." || raw == ".." { continue; }
        if !common::permitted_name(&raw) { return Err(Issue::Invalid); }
        *total += 1;
        *retained += raw.len() + entry.qualification_wire_name.len() * 2 + std::mem::size_of::<smb2::DirectoryEntry>();
        if *total > 4096 || *retained > 8 * 1024 * 1024 { return Err(Issue::Invalid); }
        let wire: String = entry.qualification_wire_name.iter().map(|unit| format!("{unit:04x}")).collect();
        println!("B10_ROW {scope} {} {} {wire}", entry.attributes.bits(), entry.size);
    }
    std::io::stdout().flush().map_err(|_| Issue::IPC)
}

async fn execute(mode: &str, mut control: UnixStream) -> i32 {
    let beginning = Instant::now();
    let transport = match admitted(TcpTransport::connect("127.0.0.1:15445", Duration::from_secs(10)), &mut control).await {
        Ok(value) => Arc::new(value),
        Err(_) => { println!("B10_CONNECT_FAILED"); return 2; }
    };
    let (mut conn, sent) = from_transport(transport);
    let mut reader: Option<DirectoryReader> = None;
    let mut total = 0usize;
    let mut retained = 0usize;
    let mut first_page_micros = 0u128;
    let mut eof = false;
    let outcome: Result<(), Issue> = async {
        admitted(conn.negotiate(), &mut control).await?;
        if mode == "auth" { barrier("auth", &mut control).await?; }
        let session = admitted(Session::setup(&mut conn, "Guest", "", ""), &mut control).await?;
        if session.should_encrypt || session.should_sign { return Err(Issue::Invalid); }
        let tree = admitted(Tree::connect(&mut conn, "ExplorerQA"), &mut control).await?;
        if tree.is_dfs || tree.encrypt_data || tree.dfs_origin.is_some() { return Err(Issue::Invalid); }
        reader = Some(admitted(tree.open_directory_reader(conn.clone(), ""), &mut control).await?);
        if mode == "query" || mode == "stop" || mode == "ipc" { barrier("query", &mut control).await?; }
        let mut batches = 0;
        loop {
            let next = admitted(reader.as_mut().ok_or(Issue::Invalid)?.next_batch(), &mut control).await?;
            match next {
                None => { eof = true; break; },
                Some(entries) => {
                    batches += 1;
                    if batches > 32 { return Err(Issue::Invalid); }
                    if first_page_micros == 0 { first_page_micros = beginning.elapsed().as_micros(); }
                    publish("root", entries, &mut total, &mut retained)?;
                    if mode == "close" {
                        barrier("close", &mut control).await?;
                        admitted(reader.take().ok_or(Issue::Invalid)?.close(), &mut control).await?;
                        return Err(Issue::Invalid); // An outage close must not turn into a baseline pass.
                    }
                },
            }
        }
        reader = None;
        reader = Some(admitted(tree.open_directory_reader(conn.clone(), "Folder"), &mut control).await?);
        loop {
            match admitted(reader.as_mut().ok_or(Issue::Invalid)?.next_batch(), &mut control).await? {
                None => break,
                Some(entries) => {
                    batches += 1;
                    if batches > 32 { return Err(Issue::Invalid); }
                    publish("nested", entries, &mut total, &mut retained)?;
                },
            }
        }
        reader = None;
        // Deliberately named generated links never authorize traversal.
        for link in ["Inside link", "Outside link", "Broken link"] {
            match admitted(tree.open_directory_reader(conn.clone(), link), &mut control).await {
                Err(Issue::Remote) => {},
                Ok(value) => { reader = Some(value); return Err(Issue::Invalid); },
                Err(error) => return Err(error),
            }
        }
        admitted(tree.disconnect(&mut conn), &mut control).await?;
        Ok(())
    }.await;
    let stopping = Instant::now();
    conn.mark_dead(); // Admission closes before a reader can drop/queue cleanup.
    drop(reader.take());
    let joined = tokio::time::timeout(Duration::from_secs(2), conn.qualification_stop_and_join()).await;
    let joins = match joined { Ok(Ok(count)) => count, _ => { println!("B10_DRAIN_FAILED"); return 3; } };
    let pending = conn.outstanding_requests().len();
    drop(conn);
    tokio::task::yield_now().await;
    let tasks = tokio::runtime::Handle::current().metrics().num_alive_tasks();
    let counts: Vec<_> = sent.iter().map(|n| n.load(std::sync::atomic::Ordering::Relaxed)).collect();
    let kind = match outcome { Ok(()) => "complete", Err(Issue::Remote) => "remote-error",
        Err(Issue::Deadline) => "request-deadline", Err(Issue::Stop) => "stopped",
        Err(Issue::IPC) => "ipc-closed", Err(Issue::Invalid) => "invalid-result" };
    println!("B10_RESULT {{\"outcome\":\"{kind}\",\"joined\":{joins},\"pending\":{pending},\"tasks\":{tasks},\"rows\":{total},\"eof\":{eof},\"firstPageMicros\":{first_page_micros},\"drainMicros\":{},\"elapsedMicros\":{},\"commands\":{counts:?}}}",
        stopping.elapsed().as_micros(), beginning.elapsed().as_micros());
    if joins == 4 && tasks == 0 && pending == 0 { 0 } else { 3 }
}

pub fn run(args: &[String]) -> i32 {
    if args.len() != 3 || args[0] != "--generated-case" || args[1].len() != 36
        || !args[1].bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
        || !["baseline", "query", "auth", "close", "stop", "ipc"].contains(&args[2].as_str()) {
        return 2;
    }
    let descriptor = match std::io::stdin().as_fd().try_clone_to_owned() { Ok(value) => value, Err(_) => return 2 };
    let stream = std::os::unix::net::UnixStream::from(descriptor);
    if stream.peer_addr().is_err() || stream.set_nonblocking(true).is_err() { return 2; }
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() { Ok(value) => value, Err(_) => return 2 };
    runtime.block_on(async {
        match UnixStream::from_std(stream) { Ok(control) => execute(&args[2], control).await, Err(_) => 2 }
    })
}
