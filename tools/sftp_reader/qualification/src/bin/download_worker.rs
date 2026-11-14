//! Experimental version3 catalog/body helper, never ordinarily bundled.
fn main(){
    let mut arguments=std::env::args().skip(1);
    if arguments.next().as_deref()!=Some("--transfer-paged-worker")||arguments.next().is_some(){std::process::exit(2)}
    std::process::exit(macexplorer_sftp_reader_qualification::worker::run_transfer());
}
