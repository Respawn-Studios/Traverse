//! Separate generated-only authenticated experiment. No ordinary application entry.
#[path = "../../common.rs"]
mod common;
#[path = "../../auth_security.rs"]
mod security;
#[path = "../../directory_validation.rs"]
#[cfg(test)]
mod directory_validation;

mod ipc;

use async_trait::async_trait;
use smb2::client::Connection;
use smb2::transport::{TcpTransport, TransportSend};
use std::{sync::{Arc, atomic::{AtomicU64, Ordering}}, time::Duration};

struct GuardedSend { transport: Arc<TcpTransport>, plain: Arc<[AtomicU64; 19]>, encrypted: Arc<AtomicU64> }
#[async_trait]
impl TransportSend for GuardedSend {
    async fn send(&self, data: &[u8]) -> smb2::Result<()> {
        if data.starts_with(b"\xfdSMB") {
            // encrypt_bytes in this exact recorded source checked the plaintext
            // command before AEAD. This counter counts transforms, not commands.
            if !(116..=common::FRAME_CAP).contains(&data.len()) {
                return Err(smb2::Error::invalid_data("B10 outbound transform refused"));
            }
            self.encrypted.fetch_add(1, Ordering::Relaxed);
        } else {
            if !common::permitted_frame(data) { return Err(smb2::Error::invalid_data("B10 metadata command refused")); }
            self.plain[u16::from_le_bytes(data[12..14].try_into().unwrap()) as usize].fetch_add(1, Ordering::Relaxed);
        }
        self.transport.send(data).await
    }
}
fn from_transport(transport: Arc<TcpTransport>) -> (Connection, Arc<[AtomicU64; 19]>, Arc<AtomicU64>) {
    let plain = Arc::new(std::array::from_fn(|_| AtomicU64::new(0)));
    let encrypted = Arc::new(AtomicU64::new(0));
    let mut conn = Connection::from_transport(Box::new(GuardedSend {
        transport: transport.clone(), plain: plain.clone(), encrypted: encrypted.clone(),
    }), Box::new(transport), "127.0.0.1");
    conn.set_compression_requested(false); conn.set_reviver(None); conn.set_keepalive(None);
    conn.set_response_timeout(Some(Duration::from_secs(10)));
    (conn, plain, encrypted)
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--ipc-worker"] { std::process::exit(ipc::run()); }
    if !args.is_empty() { std::process::exit(2); }
    println!("B10 authenticated offline controls; ordinary Connect remains disabled");
}

#[cfg(test)]
mod tests {
    use super::*;
    use smb2::{crypto::{encryption::{self, Cipher}, signing::{self, SigningAlgorithm}},
        msg::echo::EchoRequest, types::{Command, SessionId}};
    use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{TcpListener, TcpStream}, time::timeout};

    async fn receive(socket: &mut TcpStream) -> Vec<u8> {
        let n = socket.read_u32().await.unwrap() as usize;
        assert!((64..=common::FRAME_CAP).contains(&n));
        let mut bytes = vec![0; n]; socket.read_exact(&mut bytes).await.unwrap(); bytes
    }
    async fn send(socket: &mut TcpStream, bytes: &[u8]) {
        socket.write_u32(bytes.len() as u32).await.unwrap(); socket.write_all(bytes).await.unwrap();
    }
    fn header(request: &[u8], length: usize) -> Vec<u8> {
        let mut bytes = vec![0; length]; bytes[..4].copy_from_slice(b"\xfeSMB"); bytes[4] = 64;
        bytes[12..14].copy_from_slice(&request[12..14]); bytes[14] = 16; bytes[16] = 1;
        bytes[24..32].copy_from_slice(&request[24..32]); bytes[40..48].copy_from_slice(&request[40..48]); bytes
    }
    fn negotiation(request: &[u8]) -> Vec<u8> {
        let mut bytes = header(request, 128);
        bytes[64..66].copy_from_slice(&65u16.to_le_bytes()); bytes[66] = 3;
        bytes[68..70].copy_from_slice(&0x0311u16.to_le_bytes()); bytes[70] = 2;
        for offset in [92, 96, 100] { bytes[offset..offset + 4].copy_from_slice(&65536u32.to_le_bytes()); }
        bytes[124] = 128;
        bytes.extend([1, 0, 6, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]);
        bytes.extend([2, 0, 4, 0, 0, 0, 0, 0, 1, 0, 2, 0]); bytes
    }
    async fn connect(port: u16) -> Connection {
        let transport = Arc::new(TcpTransport::connect(format!("127.0.0.1:{port}"), Duration::from_secs(1)).await.unwrap());
        from_transport(transport).0
    }
    async fn stop(conn: &Connection) {
        assert_eq!(timeout(Duration::from_secs(2), conn.qualification_stop_and_join()).await.unwrap().unwrap(), 4);
        assert!(conn.outstanding_requests().is_empty());
    }
    fn activate(conn: &mut Connection, encrypt: bool) {
        conn.set_session_id(SessionId(42)); conn.activate_signing(vec![3; 16], SigningAlgorithm::AesCmac);
        if encrypt { conn.activate_encryption(vec![7; 16], vec![9; 16], Cipher::Aes128Gcm); }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn wire_negotiation_offers_only_reviewed_policy_and_refuses_downgrade() {
        for altered in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap(); let port = listener.local_addr().unwrap().port();
            let peer = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap(); let request = receive(&mut socket).await;
                assert_eq!(&request[66..70], &[1, 0, 3, 0]); // One dialect, signing enabled|required.
                assert_eq!(&request[100..102], &[0x11, 3]);
                let mut response = negotiation(&request); if altered { response[68..70].copy_from_slice(&0x0302u16.to_le_bytes()); }
                send(&mut socket, &response).await;
                let mut byte = [0]; assert_eq!(socket.read(&mut byte).await.unwrap(), 0); // No credential retry.
            });
            let mut conn = connect(port).await;
            let result = timeout(Duration::from_secs(1), conn.negotiate()).await.unwrap();
            assert_eq!(result.is_err(), altered); stop(&conn).await; drop(conn);
            timeout(Duration::from_secs(1), peer).await.unwrap().unwrap();
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn actual_receiver_enforces_encryption_and_rejects_tampering() {
        for fault in ["none", "plaintext", "tag", "session", "length", "flags", "nonce", "nested", "compound"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap(); let port = listener.local_addr().unwrap().port();
            let peer = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap(); let request = receive(&mut socket).await;
                send(&mut socket, &negotiation(&request)).await;
                let wire = receive(&mut socket).await;
                assert!(security::transform(&wire, 42).is_ok());
                let request = encryption::decrypt_message(&wire[..52], &wire[52..], &[7; 16], Cipher::Aes128Gcm).unwrap();
                assert!(common::permitted_frame(&request)); assert_eq!(request[12], 13);
                let mut response = header(&request, 68); response[64] = 4;
                if fault == "nested" { response[..4].copy_from_slice(b"\xfcSMB"); }
                if fault == "compound" { response[20] = 64; }
                let mut wire = if fault == "plaintext" {
                    response[16] |= 8;
                    signing::sign_message(&mut response, &[3; 16], SigningAlgorithm::AesCmac, u64::from_le_bytes(request[24..32].try_into().unwrap()), false).unwrap(); response
                } else {
                    let (mut h, body) = encryption::encrypt_message(&response, &[9; 16], Cipher::Aes128Gcm, &[0; 16], 42).unwrap(); h.extend(body); h
                };
                match fault { "tag" => wire[4] ^= 1, "session" => wire[44] ^= 1, "length" => wire[36] ^= 1,
                    "flags" => wire[42] ^= 1, "nonce" => wire[32] ^= 1, _ => {} }
                send(&mut socket, &wire).await;
                let mut byte = [0]; assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
            });
            let mut conn = connect(port).await; conn.negotiate().await.unwrap(); activate(&mut conn, true);
            let result = timeout(Duration::from_secs(1), conn.execute(Command::Echo, &EchoRequest, None)).await.unwrap();
            assert_eq!(result.is_ok(), fault == "none", "receiver fault {fault}");
            stop(&conn).await; drop(conn); timeout(Duration::from_secs(1), peer).await.unwrap().unwrap();
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn signed_compatibility_verifies_signature_even_if_signed_flag_is_removed() {
        for fault in ["none", "body", "stripped", "wrong-session"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap(); let port = listener.local_addr().unwrap().port();
            let peer = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap(); let request = receive(&mut socket).await;
                send(&mut socket, &negotiation(&request)).await;
                let request = receive(&mut socket).await; assert!(common::permitted_frame(&request));
                let message = u64::from_le_bytes(request[24..32].try_into().unwrap());
                signing::verify_signature(&request, &[3; 16], SigningAlgorithm::AesCmac, message, false).unwrap();
                let mut response = header(&request, 68); response[64] = 4; response[16] |= 8;
                if fault == "wrong-session" { response[40] ^= 1; }
                signing::sign_message(&mut response, &[3; 16], SigningAlgorithm::AesCmac, message, false).unwrap();
                if fault == "body" { response[64] ^= 1; } if fault == "stripped" { response[16] &= !8; }
                send(&mut socket, &response).await;
                let mut byte = [0]; assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
            });
            let mut conn = connect(port).await; conn.b10_negotiate(false).await.unwrap(); activate(&mut conn, false);
            let result = timeout(Duration::from_secs(1), conn.execute(Command::Echo, &EchoRequest, None)).await.unwrap();
            assert_eq!(result.is_ok(), fault == "none", "signed fault {fault}");
            stop(&conn).await; drop(conn); timeout(Duration::from_secs(1), peer).await.unwrap().unwrap();
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn metadata_guard_applies_before_encryption() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap(); let port = listener.local_addr().unwrap().port();
        let peer = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap(); let request = receive(&mut socket).await;
            send(&mut socket, &negotiation(&request)).await;
            let mut byte = [0]; assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
        });
        let mut conn = connect(port).await; conn.negotiate().await.unwrap(); activate(&mut conn, true);
        for command in [Command::Read, Command::Write, Command::Ioctl, Command::SetInfo] {
            assert!(timeout(Duration::from_secs(1), conn.execute(command, &EchoRequest, None)).await.unwrap().is_err());
        }
        stop(&conn).await; drop(conn); timeout(Duration::from_secs(1), peer).await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn named_authentication_refuses_guest_null_missing_and_forged_final_signatures() {
        use smb2::client::Session;
        for fault in ["guest", "null", "unsigned", "forged"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap(); let port = listener.local_addr().unwrap().port();
            let peer = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap(); let request = receive(&mut socket).await;
                send(&mut socket, &negotiation(&request)).await;
                let first = receive(&mut socket).await; assert_eq!(first[12], 1);
                let mut challenge = vec![0; 60]; challenge[..8].copy_from_slice(b"NTLMSSP\0"); challenge[8] = 2;
                challenge[16] = 56; challenge[20..24].copy_from_slice(&0xE0880231u32.to_le_bytes());
                challenge[24..32].copy_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]); challenge[40] = 4; challenge[42] = 4; challenge[44] = 56;
                let mut response = header(&first, 72); response[8..12].copy_from_slice(&0xC0000016u32.to_le_bytes());
                response[40..48].copy_from_slice(&42u64.to_le_bytes());
                response[64] = 9; response[68] = 72; response[70] = 60; response.extend(challenge);
                send(&mut socket, &response).await;
                let second = receive(&mut socket).await; assert_eq!(second[12], 1);
                let mut response = header(&second, 72); response[64] = 9; response[68] = 72;
                if fault == "guest" { response[66] = 1; } if fault == "null" { response[66] = 2; }
                if fault == "forged" { response[16] |= 8; response[48..64].fill(0x55); }
                send(&mut socket, &response).await;
                let mut byte = [0]; assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
            });
            let mut conn = connect(port).await; conn.negotiate().await.unwrap();
            let outcome = timeout(Duration::from_secs(1), Session::setup(&mut conn, "generated", "generated-only-test", "")).await.unwrap();
            match fault {
                "guest" | "null" => assert!(matches!(outcome, Err(smb2::Error::GuestSessionRefused { .. }))),
                _ => assert!(matches!(outcome, Err(smb2::Error::SignatureInvalid { .. }))),
            }
            assert!(!conn.should_encrypt()); stop(&conn).await; drop(conn);
            timeout(Duration::from_secs(1), peer).await.unwrap().unwrap();
        }
    }
}
