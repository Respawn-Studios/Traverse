//! Bundled catalog helper. Body mode must be explicitly selected by its parent;
//! metadata protocol2 still refuses every body command. No diagnostic entry.
fn main() {
    let mut arguments=std::env::args().skip(1);
    let mode=arguments.next();
    if arguments.next().is_some() { std::process::exit(2); }
    let outcome=match mode.as_deref(){
        Some("--paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_paged(),
        Some("--key-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_key_paged(),
        #[cfg(feature="agent-qualification")]
        Some("--agent-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_agent_paged(),
        Some("--interactive-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_interactive_paged(),
        Some("--jump-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_jump_paged(),
        Some("--remembered-jump-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_remembered_jump_paged(),
        #[cfg(feature="folder-download-qualification")]
        Some("--folder-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_folders(),
        #[cfg(feature="folder-download-qualification")]
        Some("--routed-folder-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_routed_folders(),
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
        Some("--folder-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_folder_uploads(),
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
        Some("--exclusive-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_exclusive_uploads(),
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
        Some("--fresh-folder-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_fresh_folder_uploads(),
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
        Some("--routed-exclusive-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_routed_exclusive_uploads(),
        #[cfg(all(feature="folder-download-qualification",feature="upload-qualification"))]
        Some("--routed-fresh-folder-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_routed_fresh_folder_uploads(),
        #[cfg(feature="download-qualification")]
        Some("--transfer-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_transfer(),
        #[cfg(feature="download-qualification")]
        Some("--key-transfer-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_key_transfer(),
        #[cfg(feature="download-qualification")]
        Some("--interactive-transfer-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_interactive_transfer(),
        #[cfg(feature="upload-qualification")]
        Some("--upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_upload(),
        #[cfg(feature="upload-qualification")]
        Some("--key-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_key_upload(),
        #[cfg(feature="upload-qualification")]
        Some("--interactive-upload-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_interactive_upload(),
        #[cfg(feature="inplace-edit-v1")]
        Some("--guarded-inplace-v1-startup3-worker")=>macexplorer_sftp_reader_qualification::worker::run_inplace(),
        #[cfg(feature="inplace-edit-v1")]
        Some("--routed-guarded-inplace-v1-startup3-worker")=>macexplorer_sftp_reader_qualification::worker::run_routed_inplace(),
        #[cfg(feature="remote-action-qualification")]
        Some("--remote-actions-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_remote_actions(),
        #[cfg(feature="remote-action-qualification")]
        Some("--routed-remote-actions-paged-worker")=>macexplorer_sftp_reader_qualification::worker::run_routed_remote_actions(),
        _=>2,
    };
    std::process::exit(outcome);
}
