// Standalone generated-only experiment. Never linked into Mac Explorer.
#[path = "../../common.rs"]
mod common;
#[path = "../../directory_validation.rs"]
#[cfg(test)]
mod directory_validation;
mod live;
mod ipc;

use async_trait::async_trait;
use smb2::client::Connection;
use smb2::transport::{TcpTransport, TransportSend};
#[cfg(test)]
use smb2::transport::TransportReceive;
use std::sync::{Arc, atomic::{AtomicU64, Ordering}};
use std::time::Duration;

struct GuardedSend {
    transport: Arc<TcpTransport>,
    sent: Arc<[AtomicU64; 19]>,
}

#[async_trait]
impl TransportSend for GuardedSend {
    async fn send(&self, data: &[u8]) -> smb2::Result<()> {
        if !common::permitted_frame(data) {
            return Err(smb2::Error::Io(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "B10 command refused")));
        }
        let command = u16::from_le_bytes(data[12..14].try_into().unwrap()) as usize;
        self.sent[command].fetch_add(1, Ordering::Relaxed);
        self.transport.send(data).await
    }
}

#[cfg(test)]
async fn connection(port: u16) -> smb2::Result<(Connection, Arc<[AtomicU64; 19]>)> {
    let transport = Arc::new(TcpTransport::connect(format!("127.0.0.1:{port}"), Duration::from_secs(10)).await?);
    Ok(from_transport(transport))
}

fn from_transport(transport: Arc<TcpTransport>) -> (Connection, Arc<[AtomicU64; 19]>) {
    let sent = Arc::new(std::array::from_fn(|_| AtomicU64::new(0)));
    let mut conn = Connection::from_transport(
        Box::new(GuardedSend { transport: transport.clone(), sent: sent.clone() }),
        Box::new(transport), "127.0.0.1");
    conn.set_compression_requested(false);
    conn.set_reviver(None);
    conn.set_keepalive(None);
    conn.set_response_timeout(Some(Duration::from_secs(10)));
    (conn, sent)
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--ipc-worker"] { std::process::exit(ipc::run()); }
    if !args.is_empty() { std::process::exit(live::run(&args)); }
    println!("B10 source-build screen only; no network action");
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    #[tokio::test(flavor = "current_thread")]
    async fn malformed_or_oversized_frames_fail_before_waiting_for_payload() {
        for header in [[0, 4, 0, 1], [0, 255, 255, 255], [1, 0, 0, 64]] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                socket.write_all(&header).await.unwrap();
                let mut byte = [0];
                socket.read(&mut byte).await.unwrap_or(0)
            });
            let transport = TcpTransport::connect(format!("127.0.0.1:{port}"), Duration::from_secs(1)).await.unwrap();
            let result = timeout(Duration::from_secs(1), transport.receive()).await.unwrap();
            assert!(result.is_err());
            drop(transport);
            assert_eq!(timeout(Duration::from_secs(1), server).await.unwrap().unwrap(), 0);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unsupported_transforms_and_truncated_frames_refuse() {
        let mut compressed = vec![0; 64]; compressed[..4].copy_from_slice(b"\xfcSMB");
        let mut encrypted = vec![0; 64]; encrypted[..4].copy_from_slice(b"\xfdSMB");
        for (length, payload) in [(64u32, compressed), (64, encrypted), (64, vec![1, 2])] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                socket.write_all(&length.to_be_bytes()).await.unwrap();
                socket.write_all(&payload).await.unwrap();
            });
            let transport = TcpTransport::connect(format!("127.0.0.1:{port}"), Duration::from_secs(1)).await.unwrap();
            assert!(timeout(Duration::from_secs(1), transport.receive()).await.unwrap().is_err());
            server.await.unwrap();
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn fragmented_valid_transport_preserves_bytes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let mut expected = vec![0; 64]; expected[..4].copy_from_slice(b"\xfeSMB");
        let bytes = expected.clone();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            for byte in 64u32.to_be_bytes().into_iter().chain(bytes) {
                socket.write_all(&[byte]).await.unwrap();
                tokio::task::yield_now().await;
            }
        });
        let transport = TcpTransport::connect(format!("127.0.0.1:{port}"), Duration::from_secs(1)).await.unwrap();
        assert_eq!(timeout(Duration::from_secs(1), transport.receive()).await.unwrap().unwrap(), expected);
        server.await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn stalled_negotiate_and_partial_payload_stop_joins_all_owners() {
        for partial in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let (ready, held) = tokio::sync::oneshot::channel();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut header = [0; 4]; socket.read_exact(&mut header).await.unwrap();
                let length = u32::from_be_bytes(header) as usize;
                assert!(length < common::FRAME_CAP);
                let mut message = vec![0; length]; socket.read_exact(&mut message).await.unwrap();
                assert!(common::permitted_frame(&message));
                if partial { socket.write_all(&[0, 1, 0, 0, 0xfe, b'S', b'M', b'B']).await.unwrap(); }
                ready.send(()).unwrap();
                let mut byte = [0]; socket.read(&mut byte).await.unwrap_or(0)
            });
            let (conn, sent) = connection(port).await.unwrap();
            let mut copy = conn.clone();
            let worker = tokio::spawn(async move { copy.negotiate().await });
            timeout(Duration::from_secs(1), held).await.unwrap().unwrap();
            let started = std::time::Instant::now();
            assert_eq!(timeout(Duration::from_secs(2), conn.qualification_stop_and_join()).await.unwrap().unwrap(), 4);
            assert!(started.elapsed() < Duration::from_secs(2));
            assert!(timeout(Duration::from_secs(1), worker).await.unwrap().unwrap().is_err());
            assert_eq!(timeout(Duration::from_secs(1), server).await.unwrap().unwrap(), 0);
            assert_eq!(conn.qualification_stop_and_join().await.unwrap(), 0);
            assert!(conn.is_disconnected() && conn.outstanding_requests().is_empty());
            assert_eq!(sent[0].load(Ordering::Relaxed), 1);
            assert_eq!(sent.iter().map(|n| n.load(Ordering::Relaxed)).sum::<u64>(), 1);
            drop(conn);
            tokio::task::yield_now().await;
            assert_eq!(tokio::runtime::Handle::current().metrics().num_alive_tasks(), 0);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn hostname_is_refused_without_resolution() {
        assert!(TcpTransport::connect("not-admitted.invalid:445", Duration::from_secs(1)).await.is_err());
    }

    #[test]
    fn directory_parser_rejects_out_of_range_links_and_truncated_record_headers() {
        use smb2::msg::directory_info::parse_entries;
        use smb2::msg::query_directory::FileInformationClass::FileBothDirectoryInformation;
        // Independent class-3 fixture, 94 fixed bytes + three UTF-16 code units.
        let mut valid = vec![0u8; 100];
        valid[40..48].copy_from_slice(&42u64.to_le_bytes());
        valid[60..64].copy_from_slice(&6u32.to_le_bytes());
        valid[94..100].copy_from_slice(&[b'O', 0, b'n', 0, b'e', 0]);
        let parsed = parse_entries(FileBothDirectoryInformation, &valid).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].file_name, "One");
        assert_eq!(parsed[0].end_of_file, 42);
        let mut beyond = valid.clone(); beyond[..4].copy_from_slice(&u32::MAX.to_le_bytes());
        let mut overlapping = valid; overlapping[..4].copy_from_slice(&96u32.to_le_bytes());
        let verdicts = [beyond, overlapping, vec![0; 93]].map(|bytes|
            parse_entries(FileBothDirectoryInformation, &bytes).is_err());
        assert_eq!(verdicts, [true, true, true], "Malformed directory chains must not become complete-looking partial data");
    }

    #[test]
    fn directory_success_requires_an_actual_nonempty_output_extent() {
        use smb2::msg::query_directory::QueryDirectoryResponse;
        use smb2::pack::{ReadCursor, Unpack};
        let mut response = vec![0; 8 + 100];
        response[..2].copy_from_slice(&9u16.to_le_bytes());
        response[2..4].copy_from_slice(&72u16.to_le_bytes());
        response[4..8].copy_from_slice(&100u32.to_le_bytes());
        assert_eq!(QueryDirectoryResponse::unpack(&mut ReadCursor::new(&response)).unwrap().output_buffer.len(), 100);
        for (offset, length) in [(0u16, 100u32), (64, 100), (71, 100), (72, 0), (72, 65537), (200, 100)] {
            let mut malformed = response.clone();
            malformed[2..4].copy_from_slice(&offset.to_le_bytes());
            malformed[4..8].copy_from_slice(&length.to_le_bytes());
            assert!(QueryDirectoryResponse::unpack(&mut ReadCursor::new(&malformed)).is_err());
        }
    }
}
