//! Experimental protocol4; never selected by the ordinary packaging builder.
fn main(){
    let mut arguments=std::env::args().skip(1);
    if arguments.next().as_deref()!=Some("--upload-paged-worker")||arguments.next().is_some(){std::process::exit(2)}
    std::process::exit(macexplorer_sftp_reader_qualification::worker::run_upload());
}
