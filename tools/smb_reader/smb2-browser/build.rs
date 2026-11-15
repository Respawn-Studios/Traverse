use std::{env,path::PathBuf,process::Command};
fn main(){
    let source=PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../catalog/StoreAuthority.c");
    let object=PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("StoreAuthority.o");
    let target=match env::var("TARGET").as_deref(){
        Ok("aarch64-apple-darwin")=>"arm64-apple-macos15.0",
        Ok("x86_64-apple-darwin")=>"x86_64-apple-macos15.0",
        _=>panic!("The private store authority requires a supported macOS target"),
    };
    assert!(Command::new("/usr/bin/clang").args(["-target",target,"-O2","-Wall","-Wextra","-Werror","-c"])
        .arg(&source).arg("-o").arg(&object).status().unwrap().success());
    println!("cargo:rustc-link-arg={}",object.display());println!("cargo:rerun-if-changed={}",source.display());
    println!("cargo:rustc-check-cfg=cfg(smb_catalog_qualification)");
}
