use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    // The linker's INCLUDE memory.x (from cortex-m-rt's link.x) resolves via the link search path. CWD (project root) is on that path, so any memory.x in the project root shadows the one we write to OUT_DIR. We keep the source files as memory.x (flash) / memory-ram.x (RAM) and only the generated OUT_DIR file gets the canonical name link.x looks for — but build.rs always picks one and writes it as memory.x in OUT_DIR. To avoid the project-root shadow, we copy from a uniquely-named source file based on feature.
    let ram_image = env::var("CARGO_FEATURE_RAM_IMAGE").is_ok();
    let source = if ram_image { "memory-ram.x" } else { "memory-flash.x" };
    let bytes = fs::read(source).expect("read memory layout");
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::write(out.join("memory.x"), bytes).expect("write memory.x");
    println!("cargo:rustc-link-search={}", out.display());
    println!("cargo:rerun-if-changed=memory-flash.x");
    println!("cargo:rerun-if-changed=memory-ram.x");
    println!("cargo:rerun-if-changed=build.rs");
}
