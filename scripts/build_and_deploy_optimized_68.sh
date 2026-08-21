#!/usr/bin/env bash
# Build optimized hook+limiter on 68 and install to FinalTest/kylin/release-optimized.
set -euo pipefail

REPO="${REPO:-/mnt/local/m00953550/hami-vnpu-core}"
OUT="${OUT:-/mnt/local/m00953550/FinalTest/kylin/release-optimized}"

cd "$REPO"
export PATH="/root/.cargo/bin:$PATH"
export RUSTFLAGS="-C target-cpu=native"
cargo build --release -p hook -p limiter --features optimized

install -d "$OUT"
install -m 755 target/release/libvnpu.so "$OUT/libvnpu.so"
install -m 755 target/release/limiter "$OUT/limiter"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter" | tee "${OUT}/sha256.txt"
echo "deployed to $OUT"
