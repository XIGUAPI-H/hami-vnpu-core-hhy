#!/usr/bin/env bash
# Build hami-vnpu-origin on 68 Ubuntu host (offline vendor).
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
UB=$FT/ubuntu
ORIGIN_SRC=$UB/hami-vnpu-origin/hami-vnpu-core-main
VENDOR=/mnt/project/dongpengmin/hami_integration/hami-vnpu-core_build/vendor
MAIN_LOCK=$UB/src/hami-vnpu-core-main/Cargo.lock

export PATH="/root/.cargo/bin:$PATH"
export CARGO_NET_OFFLINE=true
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

[[ -d "$ORIGIN_SRC" ]] || { echo "missing $ORIGIN_SRC (sync hami-vnpu-origin first)"; exit 1; }
[[ -d "$VENDOR" ]] || { echo "missing vendor at $VENDOR"; exit 1; }

ln -sfn "$VENDOR" "$ORIGIN_SRC/vendor"
mkdir -p "$ORIGIN_SRC/.cargo"
cat > "$ORIGIN_SRC/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF

if [[ ! -f "$ORIGIN_SRC/Cargo.lock" ]]; then
  if [[ -f "$MAIN_LOCK" ]]; then
    cp "$MAIN_LOCK" "$ORIGIN_SRC/Cargo.lock"
  elif [[ -f "$UB/../hami-vnpu-core-main/Cargo.lock" ]]; then
    cp "$UB/../hami-vnpu-core-main/Cargo.lock" "$ORIGIN_SRC/Cargo.lock"
  fi
fi

echo "=== Ubuntu origin build on 68 ==="
grep PRETTY_NAME /etc/os-release || true
/root/.cargo/bin/rustc --version

cd "$ORIGIN_SRC"
cargo build --release -p hook -p limiter --offline

OUT=$UB/release-origin
mkdir -p "$OUT"
install -m 755 target/release/libvnpu.so target/release/limiter "$OUT/"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
ls -la "$OUT"
echo "BUILD_ORIGIN_OK $OUT"
