fn main() {
    let args=std::env::args().skip(1).collect::<Vec<_>>();
    let code=if args==["--metadata-worker"]{macexplorer_sftp_reader_qualification::worker::run()}
        else if args==["--paged-worker"]{macexplorer_sftp_reader_qualification::worker::run_paged()}else{2};
    std::process::exit(code);
}
