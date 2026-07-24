use std::env;

fn main() {
    println!("cargo:rerun-if-changed=native/miniaudio_shim.c");
    println!("cargo:rerun-if-changed=native/miniaudio_shim.h");
    println!("cargo:rerun-if-changed=vendor/miniaudio/miniaudio.c");
    println!("cargo:rerun-if-changed=vendor/miniaudio/miniaudio.h");

    cc::Build::new()
        .file("vendor/miniaudio/miniaudio.c")
        .file("native/miniaudio_shim.c")
        .include("vendor/miniaudio")
        .include("native")
        .warnings(false)
        .compile("zmusic_miniaudio");

    match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("linux") => {
            println!("cargo:rustc-link-lib=dl");
            println!("cargo:rustc-link-lib=m");
            println!("cargo:rustc-link-lib=pthread");
        }
        Ok("windows") => {
            println!("cargo:rustc-link-lib=winmm");
            println!("cargo:rustc-link-lib=ole32");
            println!("cargo:rustc-link-lib=uuid");
        }
        Ok("macos") => {
            println!("cargo:rustc-link-lib=framework=CoreAudio");
            println!("cargo:rustc-link-lib=framework=AudioToolbox");
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
        }
        _ => {}
    }
}
