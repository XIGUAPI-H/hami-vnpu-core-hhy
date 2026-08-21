#!/usr/bin/env bash
# Build LLM-turbo optimized SO on 68 openEuler container and install to openeuler/release-optimized.
set -euo pipefail

ROOT_LOCAL="${1:-}"
FT=/mnt/local/m00953550/FinalTest
OE="$FT/openeuler"
IMAGE=swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm
VENDOR=/mnt/project/dongpengmin/hami_integration/hami-vnpu-core_build/vendor
WORK=/mnt/local/hami-vnpu-core-turbo-build

if [[ -n "$ROOT_LOCAL" && -d "$ROOT_LOCAL" ]]; then
  echo "=== sync sources to $WORK ==="
  rm -rf "$WORK"
  mkdir -p "$WORK"
  tar --exclude=target --exclude=.git -cf - -C "$ROOT_LOCAL" . | tar -xf - -C "$WORK"
else
  echo "=== use existing $WORK ==="
  [[ -f "$WORK/Cargo.toml" ]] || { echo "missing $WORK"; exit 1; }
fi

mkdir -p "$OE/release-optimized" "$OE/logs"

docker run --rm \
  -v /root/.rustup:/root/.rustup:ro \
  -v /root/.cargo:/root/.cargo:ro \
  -v "$WORK:/work:rw" \
  -v "$VENDOR:/work/vendor:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -w /work "$IMAGE" \
  bash -c '
set -euo pipefail
export PATH="/root/.cargo/bin:$PATH"
export CARGO_NET_OFFLINE=true
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64"
mkdir -p /work/.cargo
cat > /work/.cargo/config.toml <<EOF
[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "vendor"
EOF
cargo build --release -p hook -p limiter --features hook/optimized --offline
sha256sum target/release/libvnpu.so target/release/limiter
'

install -m 755 "$WORK/target/release/libvnpu.so" "$WORK/target/release/limiter" "$OE/release-optimized/"
sha256sum "$OE/release-optimized/libvnpu.so" "$OE/release-optimized/limiter"
echo "BUILD_OE_TURBO_OK"
