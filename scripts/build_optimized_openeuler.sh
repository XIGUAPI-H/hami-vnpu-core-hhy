#!/usr/bin/env bash
# Build full optimized libvnpu (core_guard + core_scheduler + apply_quota) in openEuler container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-${ROOT}/openeuler/release-optimized}"
IMAGE="${OPENEULER_BUILD_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
RUSTUP_DIR="${RUSTUP_DIR:-/root/.rustup}"
CARGO_DIR="${CARGO_DIR:-/root/.cargo}"
VENDOR_DIR="${VENDOR_DIR:-}"

mkdir -p "$OUT" "$ROOT/target/release"

echo "=== openEuler optimized build (hook/optimized + limiter/core_scheduler) ==="
echo "ROOT=$ROOT OUT=$OUT"

VENDOR_MOUNT=()
if [[ -n "$VENDOR_DIR" && -d "$VENDOR_DIR" ]]; then
  VENDOR_MOUNT=(-v "${VENDOR_DIR}:/work/vendor:ro")
fi

docker run --rm \
  -v "${RUSTUP_DIR}:/root/.rustup:ro" \
  -v "${CARGO_DIR}:/root/.cargo:ro" \
  -v "${ROOT}:/work:rw" \
  "${VENDOR_MOUNT[@]}" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -w /work \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    export PATH="/root/.cargo/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"
    if [[ "${CARGO_NET_OFFLINE:-false}" == "true" ]]; then
      cargo build --release -p hook -p limiter --features hook/optimized --offline
    else
      cargo build --release -p hook -p limiter --features hook/optimized
    fi
    ls -la target/release/libvnpu.so target/release/limiter
    sha256sum target/release/libvnpu.so target/release/limiter
    echo "=== core_guard symbols ==="
    strings target/release/libvnpu.so | grep -E "core limiter|scheduler_thread|wait_for_token|acquire_one" | head -12
    nm -D target/release/libvnpu.so 2>/dev/null | grep -i CoreLimiter | head -5 || true
  '

install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"
echo "=== installed to $OUT ==="
ls -la "$OUT/"
