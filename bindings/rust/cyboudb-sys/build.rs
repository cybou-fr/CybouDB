use std::env;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=CYBOUDB_LIB_DIR");

    let lib_dir = if let Ok(dir) = env::var("CYBOUDB_LIB_DIR") {
        PathBuf::from(dir)
    } else {
        // Default to the repository root's build/ directory
        let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
        let repo_root = Path::new(&manifest_dir).join("..").join("..").join("..");
        repo_root.join("build")
    };

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=cyboudb");

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "windows" {
        println!("cargo:rustc-link-lib=dylib=kernel32");
    }

    println!("cargo:rerun-if-changed={}", lib_dir.join("cyboudb.lib").display());
    println!("cargo:rerun-if-changed={}", lib_dir.join("libcyboudb.a").display());
}
