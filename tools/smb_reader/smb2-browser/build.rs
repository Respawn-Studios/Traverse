use std::{env,path::PathBuf,process::Command};
fn main(){
    let source=PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../catalog/StoreAuthority.c");
    let object=PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("StoreAuthority.o");
    assert!(Command::new("/usr/bin/clang").args(["-O2","-Wall","-Wextra","-Werror","-mmacosx-version-min=15.0","-c"])
        .arg(&source).arg("-o").arg(&object).status().unwrap().success());
    println!("cargo:rustc-link-arg={}",object.display());println!("cargo:rerun-if-changed={}",source.display());
    println!("cargo:rustc-check-cfg=cfg(smb_catalog_qualification)");
}
