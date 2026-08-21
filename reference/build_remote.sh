#!/bin/bash
set -e
SRC=/mnt/local/build/hami-vnpu-core
cp /tmp/hook.rs "$SRC/crates/hook/src/hook.rs"
cp /tmp/Cargo.toml "$SRC/crates/hook/Cargo.toml"
cp /tmp/worker.rs "$SRC/crates/limiter/src/worker.rs"
cd "$SRC"
~/.cargo/bin/cargo build --release -p hook -p limiter 2>&1 | tail -30
sha256sum target/release/libvnpu.so target/release/limiter
