//! Bundled SMB browser and explicit file-operation worker.
//! Metadata browsing and each selected transfer/action use separate bounded policies.
#[path = "../../common.rs"] mod common;
#[path = "../../auth_security.rs"] mod security;
#[path = "../../catalog/catalog.rs"] mod catalog;
mod wire;
mod store;
mod channel;
mod network;
mod download_wire;
mod download_network;
mod folder_wire;
mod folder_network;
mod folder_size;
mod upload_wire;
mod action_wire;
mod upload_network;
mod edit_wire;
mod edit_network;
mod edit_source;
mod folder_upload_network;
#[cfg(test)]mod tests;
#[cfg(all(test,feature="b12-action-qualification"))]
mod action_controls{
    #[test]fn vendor_frames_are_narrow(){assert_eq!(smb2::client::selected_action::qualification_action_frames(),3);}
    #[tokio::test]async fn volume_witness_is_object_scoped(){assert_eq!(smb2::client::selected_action::qualification_volume_witness().await,1);}
    #[tokio::test]async fn directory_actions_are_bounded(){assert_eq!(smb2::client::selected_action::qualification_directory_actions().await,3);}
    #[tokio::test]async fn rename_collision_needs_exact_reply_and_closes(){assert_eq!(smb2::client::selected_action::qualification_rename_collision().await,3);}
    #[tokio::test]async fn same_session_move_keeps_no_replace_and_both_chains(){assert_eq!(smb2::client::selected_action::qualification_same_session_move().await,5);}
    #[tokio::test]async fn same_session_copy_has_exact_stage_and_copychunk_acks(){assert_eq!(smb2::client::selected_action::qualification_same_session_copy().await,8);}
}

use async_trait::async_trait;
use smb2::{client::Connection,transport::{TcpTransport,TransportSend}};
use std::{sync::{Arc,atomic::{AtomicU64,Ordering}},time::Duration};

#[derive(Clone)]enum SendPolicy{Metadata,File(Arc<smb2::client::selected_download::SelectedDownloadPolicy>),Folder(Arc<smb2::client::selected_folder_download::SelectedFolderPolicy>),Upload(Arc<smb2::client::selected_upload::SelectedUploadPolicy>)}
impl SendPolicy{fn permits(&self,data:&[u8])->bool{match self{Self::Metadata=>common::permitted_frame(data),Self::File(p)=>p.permits_frame(data),Self::Folder(p)=>p.permits_frame(data),Self::Upload(p)=>p.permits_frame(data)}}}
struct GuardedSend{transport:Arc<TcpTransport>,download:SendPolicy,plain:Arc<[AtomicU64;19]>,encrypted:Arc<AtomicU64>}
#[async_trait]
impl TransportSend for GuardedSend{
    async fn send(&self,data:&[u8])->smb2::Result<()>{
        if data.starts_with(b"\xfdSMB"){
            // The pinned encrypt_bytes checks the plaintext command before AEAD.
            if !(116..=common::FRAME_CAP).contains(&data.len()){return Err(smb2::Error::invalid_data("B10 outbound transform refused"));}
            self.encrypted.fetch_add(1,Ordering::Relaxed);
        }else{
            if !self.download.permits(data){return Err(smb2::Error::invalid_data("B10 metadata command refused"));}
            self.plain[u16::from_le_bytes(data[12..14].try_into().unwrap())as usize].fetch_add(1,Ordering::Relaxed);
        }
        self.transport.send(data).await
    }
}
fn from_transport(transport:Arc<TcpTransport>,host:&str)->Connection{from_transport_policy(transport,host,SendPolicy::Metadata)}
fn from_transport_download(transport:Arc<TcpTransport>,host:&str)->Connection{from_transport_policy(transport,host,SendPolicy::File(smb2::client::selected_download::SelectedDownloadPolicy::new()))}
fn from_transport_folder(transport:Arc<TcpTransport>,host:&str)->Connection{from_transport_policy(transport,host,SendPolicy::Folder(smb2::client::selected_folder_download::SelectedFolderPolicy::new()))}
fn from_transport_upload(transport:Arc<TcpTransport>,host:&str)->Connection{from_transport_policy(transport,host,SendPolicy::Upload(smb2::client::selected_upload::SelectedUploadPolicy::new()))}
fn from_transport_policy(transport:Arc<TcpTransport>,host:&str,policy:SendPolicy)->Connection{
    let mut conn=Connection::from_transport(Box::new(GuardedSend{transport:transport.clone(),download:policy.clone(),plain:Arc::new(std::array::from_fn(|_|AtomicU64::new(0))),encrypted:Arc::new(AtomicU64::new(0))}),Box::new(transport),host);
    match policy{SendPolicy::Metadata=>{},SendPolicy::File(p)=>conn.set_selected_download_policy(p).expect("new file policy"),SendPolicy::Folder(p)=>conn.set_selected_folder_policy(p).expect("new folder policy"),SendPolicy::Upload(p)=>conn.set_selected_upload_policy(p).expect("new upload policy")}
    conn.set_compression_requested(false);conn.set_reviver(None);conn.set_keepalive(None);conn.set_response_timeout(Some(Duration::from_secs(10)));conn
}
fn main(){
    let args=std::env::args().skip(1).collect::<Vec<_>>();
    if args==["--browser-worker"]{std::process::exit(channel::run());}
    if args==["--selected-download-browser-worker"]{std::process::exit(channel::run_download());}
    if args==["--folder-download-browser-worker"]{std::process::exit(channel::run_folder());}
    if args==["--selected-upload-browser-worker"]{std::process::exit(channel::run_upload());}
    std::process::exit(2);
}
