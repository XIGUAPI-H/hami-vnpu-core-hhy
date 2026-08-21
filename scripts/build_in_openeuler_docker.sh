#!/usr/bin/env bash
# Build libvnpu.so + limiter inside an openEuler container (openEuler glibc).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${OPENEULER_BUILD_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
RUSTUP_DIR="${RUSTUP_DIR:-/root/.rustup}"
CARGO_DIR="${CARGO_DIR:-/root/.cargo}"

mkdir -p "$ROOT/target/release"

echo "=== openEuler build image ==="
echo "$IMAGE"
docker run --rm "$IMAGE" bash -c 'cat /etc/os-release | grep PRETTY; ldd --version | head -1; uname -m'

if [[ ! -x "${CARGO_DIR}/bin/cargo" ]]; then
  echo "[ERROR] host cargo not found at ${CARGO_DIR}/bin/cargo" >&2
  echo "Install rust on the host first: curl https://sh.rustup.rs | sh" >&2
  exit 1
fi

echo "=== compiling in openEuler container (host rust + container gcc) ==="
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
    export CC=gcc
    export CXX=g++
    export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"
    cargo build --release -p hook -p limiter
    ls -la target/release/libvnpu.so target/release/limiter
    sha256sum target/release/libvnpu.so target/release/limiter
    echo "=== GLIBC deps (limiter) ==="
    objdump -T target/release/limiter 2>/dev/null | grep GLIBC | sed "s/.*GLIBC/Glibc/" | sort -u | tail -8 || true
  '

echo "=== host artifacts ==="
ls -la "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter"
file "$ROOT/target/release/libvnpu.so"
ldd "$ROOT/target/release/limiter" 2>&1 | head -6
