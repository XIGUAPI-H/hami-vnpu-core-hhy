fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rustc-link-search=native=/usr/local/Ascend/ascend-toolkit/latest/lib64");
    // Some deployments ship `libruntime.so` in `.../lib64` but place its transitive
    // dependencies (e.g. `libruntime_common.so`, `liberror_manager.so`) under
    // the `aarch64-linux/lib64` prefix. Add it so linking works reliably.
    println!(
        "cargo:rustc-link-search=native=/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64"
    );
    // Help the linker resolve DT_NEEDED deps of `libruntime.so` during link.
    // (Without this, ld may warn "needed by ... not found" even if the .so exists.)
    println!("cargo:rustc-link-arg=-Wl,-rpath-link=/usr/local/Ascend/ascend-toolkit/latest/lib64");
    println!(
        "cargo:rustc-link-arg=-Wl,-rpath-link=/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64"
    );

    // Explicitly link common runtime deps to avoid undefined symbols on some toolchain layouts.
    println!("cargo:rustc-link-lib=dylib=runtime_common");
    println!("cargo:rustc-link-lib=dylib=profapi");
    println!("cargo:rustc-link-lib=dylib=error_manager");
    println!("cargo:rustc-link-lib=dylib=ascendalog");
    Ok(())
}
