#!/usr/bin/env bash
set -euo pipefail
FT=/mnt/local/m00953550/FinalTest
UB=$FT/ubuntu
SRC=$UB/src
VENDOR=/mnt/project/dongpengmin/hami_integration/hami-vnpu-core_build/vendor

rm -rf "$SRC"
mkdir -p "$UB/logs"
tar -xzf /tmp/hami-vnpu-ubuntu-sync.tgz -C "$UB"
mkdir -p "$SRC"
mv "$UB/.cargo" "$UB/crates" "$UB/scripts" "$UB/Cargo.toml" "$UB/Cargo.lock" "$UB/hami-vnpu-core-main" "$SRC/"
ln -sfn "$VENDOR" "$SRC/vendor"
ln -sfn "$VENDOR" "$SRC/hami-vnpu-core-main/vendor"
chmod +x "$SRC/scripts/"*.sh
export PATH="/root/.cargo/bin:$PATH"
export CARGO_NET_OFFLINE=true
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

echo "=== build optimized (offline) ==="
cd "$SRC"
cargo build --release -p hook -p limiter --features hook/optimized --offline
mkdir -p "$UB/release-optimized"
install -m 755 target/release/libvnpu.so target/release/limiter "$UB/release-optimized/"
sha256sum "$UB/release-optimized/libvnpu.so" "$UB/release-optimized/limiter"
strings "$UB/release-optimized/libvnpu.so" | grep -E "core limiter|scheduler_thread" | head -5 || true

echo "=== build main (offline) ==="
cd "$SRC/hami-vnpu-core-main"
cargo build --release -p hook -p limiter --offline
mkdir -p "$UB/release-main"
install -m 755 target/release/libvnpu.so target/release/limiter "$UB/release-main/"
sha256sum "$UB/release-main/libvnpu.so" "$UB/release-main/limiter"

cp "$SRC/scripts/compare_perf_optimized_ubuntu.sh" "$SRC/scripts/aisbench_perf_ubuntu.sh" "$UB/"
chmod +x "$UB/"*.sh
ls -la "$UB/release-optimized" "$UB/release-main"
echo "BUILD_OK"
