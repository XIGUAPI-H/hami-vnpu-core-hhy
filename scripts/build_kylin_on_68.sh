#!/usr/bin/env bash
# Build optimized + main libvnpu/limiter in Ascend container for Kylin V11 deployment track.
# On Kylin V11 hosts, Ascend officially ships openEuler-based mindspeed images (no separate kylin tag).
# Override KYLIN_IMAGE if you have a native Kylin V11 container with gcc + CANN.
set -euo pipefail

ROOT_OPT="${ROOT_OPT:-/mnt/local/m00953550/hami-vnpu-core}"
ROOT_MAIN="${ROOT_MAIN:-/mnt/local/m00953550/hami-vnpu-core-main}"
MAIN_VENDOR="${MAIN_VENDOR:-/mnt/local/m00953550/hami-vnpu-core-main/vendor}"
KY="${KY:-/mnt/local/m00953550/FinalTest/kylin}"
OUT_OPT="${OUT_OPT:-${KY}/release}"
OUT_MAIN="${OUT_MAIN:-${KY}/release-main}"
IMAGE="${KYLIN_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"

build_tree() {
  local root="$1" out="$2" label="$3"
  local vendor_mount=()
  [[ -d "${MAIN_VENDOR}" ]] && vendor_mount=(-v "${MAIN_VENDOR}:/work/vendor:ro")

  echo "=== Kylin-track build [$label] $root -> $out ==="
  docker run --rm \
    -v /root/.rustup:/root/.rustup:ro \
    -v /root/.cargo:/root/.cargo:ro \
    -v "${root}:/work:rw" \
    "${vendor_mount[@]}" \
    -v /usr/local/Ascend:/usr/local/Ascend:ro \
    -w /work "$IMAGE" \
    bash -c '
      set -euo pipefail
      export PATH="/root/.cargo/bin:$PATH"
      export CARGO_NET_OFFLINE=true
      export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"
      cargo build --release -p hook -p limiter --offline
      sha256sum target/release/libvnpu.so target/release/limiter
      ldd target/release/limiter | head -3 || true
    '
  install -m 755 "${root}/target/release/libvnpu.so" "${root}/target/release/limiter" "${out}/"
  ls -la "${out}/"
}

mkdir -p "$OUT_OPT" "$OUT_MAIN" "${KY}/logs"

echo "=== container OS (KYLIN_IMAGE=$IMAGE) ==="
docker run --rm "$IMAGE" bash -c 'grep PRETTY /etc/os-release; ldd --version | head -1; uname -m'

if [[ -f /tmp/hami-vnpu-core-src.tgz ]]; then
  rm -rf "$ROOT_OPT"
  mkdir -p "$ROOT_OPT"
  tar -xzf /tmp/hami-vnpu-core-src.tgz -C "$ROOT_OPT"
fi

build_tree "$ROOT_OPT" "$OUT_OPT" "optimized"
build_tree "$ROOT_MAIN" "$OUT_MAIN" "main"

echo "=== Kylin-track build done ==="
sha256sum "${OUT_OPT}/libvnpu.so" "${OUT_MAIN}/libvnpu.so"
