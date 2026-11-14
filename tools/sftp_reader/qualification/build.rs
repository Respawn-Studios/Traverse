// Link the already-qualified private temporary-store authority, no crate or
// global toolchain dependency. All products land in Cargo's isolated OUT_DIR.
use std::{env,path::PathBuf,process::Command};
fn main(){
    println!("cargo:rustc-check-cfg=cfg(sftp_catalog_qualification)");
    let root=PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest"));
    let source=root.join("../../smb_reader/catalog/StoreAuthority.c");
    let out=PathBuf::from(env::var_os("OUT_DIR").expect("output"));
    assert!(Command::new("/usr/bin/xcrun").args(["clang","-std=c11","-O2","-Wall","-Wextra","-Werror","-c"])
        .arg(&source).arg("-o").arg(out.join("authority.o")).status().expect("compiler").success());
    assert!(Command::new("/usr/bin/ar").arg("rcs").arg(out.join("libmex_remote_authority.a")).arg(out.join("authority.o"))
        .status().expect("archiver").success());
    println!("cargo:rustc-link-search=native={}",out.display());
    println!("cargo:rustc-link-lib=static=mex_remote_authority");
    println!("cargo:rerun-if-changed={}",source.display());
}
