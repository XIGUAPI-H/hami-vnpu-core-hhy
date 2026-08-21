#!/usr/bin/env bash
# Build hami-vnpu-core-main libvnpu.so + limiter for openEuler (glibc in mindspeed image).
set -euo pipefail

ROOT="${ROOT:-/mnt/local/m00953550/hami-vnpu-core-main}"
OUT="${OUT:-/mnt/local/m00953550/FinalTest/openeuler/release-main}"
IMAGE="${OPENEULER_BUILD_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
RUSTUP_DIR="${RUSTUP_DIR:-/root/.rustup}"
CARGO_DIR="${CARGO_DIR:-/root/.cargo}"

[[ -f "$ROOT/Cargo.toml" ]] || { echo "missing $ROOT/Cargo.toml"; exit 1; }
[[ -x "${CARGO_DIR}/bin/cargo" ]] || { echo "missing ${CARGO_DIR}/bin/cargo"; exit 1; }

mkdir -p "$ROOT/target/release" "$OUT"

echo "=== openEuler build: $ROOT -> $OUT ==="
docker run --rm "$IMAGE" bash -c 'grep PRETTY /etc/os-release; ldd --version | head -1; uname -m'

docker run --rm \
  -v "${RUSTUP_DIR}:/root/.rustup:ro" \
  -v "${CARGO_DIR}:/root/.cargo:ro" \
  -v "${ROOT}:/work:rw" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -w /work \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    export PATH="/root/.cargo/bin:${PATH}"
    export CC=gcc CXX=g++
    export CARGO_NET_OFFLINE=true
    export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"
    cargo build --release -p hook -p limiter --offline
    ls -la target/release/libvnpu.so target/release/limiter
    sha256sum target/release/libvnpu.so target/release/limiter
    file target/release/libvnpu.so target/release/limiter
    echo "=== GLIBC (limiter) ==="
    objdump -T target/release/limiter 2>/dev/null | grep GLIBC | sed "s/.*GLIBC/Glibc/" | sort -u | tail -8 || true
  '

install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"
echo "=== installed ==="
ls -la "$OUT/"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
