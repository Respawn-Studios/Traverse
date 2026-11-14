// Standalone generated-only experiment. Never linked into Mac Explorer.
#[path = "../../common.rs"]
mod common;

fn main() {
    println!("B10 source-build screen only; no network action");
}

#[cfg(test)]
mod tests {
    use smb::{Connection, ConnectionConfig, Guid};
    use smb::transport::{TcpTransport, SmbTransport, SmbTransportRead};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    #[tokio::test(flavor = "current_thread")]
    async fn oversized_frames_refuse_without_payload_and_preserve_socket_ownership() {
        for header in [[0, 4, 0, 1], [0, 255, 255, 255], [1, 0, 0, 64], [0, 0, 0, 0]] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                socket.write_all(&header).await.unwrap();
                let mut byte = [0]; socket.read(&mut byte).await.unwrap_or(0)
            });
            let mut transport = TcpTransport::new(Duration::from_secs(1));
            transport.connect("127.0.0.1", endpoint).await.unwrap();
            assert!(timeout(Duration::from_secs(1), transport.receive()).await.unwrap().is_err());
            drop(transport);
            assert_eq!(timeout(Duration::from_secs(1), server).await.unwrap().unwrap(), 0);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn fragmented_valid_frame_and_unsupported_transforms() {
        for tag in [b"\xfeSMB", b"\xfcSMB", b"\xfdSMB"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = listener.local_addr().unwrap();
            let mut payload = vec![0; 64]; payload[..4].copy_from_slice(tag);
            let expected = payload.clone();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                for byte in 64u32.to_be_bytes().into_iter().chain(payload) {
                    socket.write_all(&[byte]).await.unwrap();
                    tokio::task::yield_now().await;
                }
            });
            let mut transport = TcpTransport::new(Duration::from_secs(1));
            transport.connect("127.0.0.1", endpoint).await.unwrap();
            let result = timeout(Duration::from_secs(1), transport.receive()).await.unwrap();
            if tag == b"\xfeSMB" { assert_eq!(result.unwrap(), expected); }
            else { assert!(result.is_err()); }
            server.await.unwrap();
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn stopped_negotiate_joins_transport_and_waiter() {
        for partial in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = listener.local_addr().unwrap();
            let (ready, held) = tokio::sync::oneshot::channel();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut header = [0; 4]; socket.read_exact(&mut header).await.unwrap();
                let length = u32::from_be_bytes(header) as usize;
                assert!(length < super::common::FRAME_CAP);
                let mut message = vec![0; length]; socket.read_exact(&mut message).await.unwrap();
                assert!(super::common::permitted_frame(&message));
                if partial { socket.write_all(&[0, 1, 0, 0, 0xfe, b'S', b'M', b'B']).await.unwrap(); }
                ready.send(()).unwrap();
                let mut byte = [0]; socket.read(&mut byte).await.unwrap_or(0)
            });
            let config = ConnectionConfig { disable_notifications: true, smb2_only_negotiate: true,
                timeout: Some(Duration::from_secs(10)), ..Default::default() };
            let conn = Arc::new(Connection::build("127.0.0.1", endpoint, Guid::generate(), config).unwrap());
            let retained = conn.clone();
            let worker = tokio::spawn(async move { retained.connect().await });
            timeout(Duration::from_secs(1), held).await.unwrap().unwrap();
            timeout(Duration::from_secs(2), conn.close()).await.unwrap().unwrap();
            assert!(timeout(Duration::from_secs(1), worker).await.unwrap().unwrap().is_err());
            assert_eq!(timeout(Duration::from_secs(1), server).await.unwrap().unwrap(), 0);
            drop(conn);
            tokio::task::yield_now().await;
            assert_eq!(tokio::runtime::Handle::current().metrics().num_alive_tasks(), 0);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn malformed_transport_finishes_pending_negotiate_without_waiting_for_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut header = [0; 4]; socket.read_exact(&mut header).await.unwrap();
            let length = u32::from_be_bytes(header) as usize;
            let mut request = vec![0; length]; socket.read_exact(&mut request).await.unwrap();
            socket.write_all(&[0, 255, 255, 255]).await.unwrap();
            let mut byte = [0]; socket.read(&mut byte).await.unwrap_or(0)
        });
        let config = ConnectionConfig { disable_notifications: true, smb2_only_negotiate: true,
            timeout: Some(Duration::from_secs(10)), ..Default::default() };
        let conn = Arc::new(Connection::build("127.0.0.1", endpoint, Guid::generate(), config).unwrap());
        let retained = conn.clone();
        let mut worker = tokio::spawn(async move { retained.connect().await });
        let finished = timeout(Duration::from_secs(1), &mut worker).await;
        // Always drain before asserting the semantic failure, including a red run.
        timeout(Duration::from_secs(2), conn.close()).await.unwrap().unwrap();
        let completed_without_deadline = finished.is_ok();
        if let Ok(result) = finished { assert!(result.unwrap().is_err()); }
        else { assert!(timeout(Duration::from_secs(1), worker).await.unwrap().unwrap().is_err()); }
        assert_eq!(timeout(Duration::from_secs(1), server).await.unwrap().unwrap(), 0);
        assert!(completed_without_deadline, "Malformed transport left the request waiting instead of failing it");
    }
}
