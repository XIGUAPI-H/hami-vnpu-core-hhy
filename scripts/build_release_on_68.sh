#!/usr/bin/env bash
set -euo pipefail
ROOT=/mnt/local/m00953550/hami-vnpu-core
OUT=/mnt/local/m00953550/FinalTest/openeuler/release
MAIN=/mnt/local/m00953550/hami-vnpu-core-main
OE=/mnt/local/m00953550/FinalTest/openeuler
IMAGE=swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm

rm -rf "$ROOT"
mkdir -p "$ROOT"
tar -xzf /tmp/hami-vnpu-core-src.tgz -C "$ROOT"
if [[ -f "$ROOT/scripts/compare_perf_release_main.sh" ]]; then
  install -m 755 "$ROOT/scripts/compare_perf_release_main.sh" "$OE/compare_perf_release_main.sh"
fi

docker run --rm \
  -v /root/.rustup:/root/.rustup:ro \
  -v /root/.cargo:/root/.cargo:ro \
  -v "$ROOT:/work:rw" \
  -v "$MAIN/vendor:/work/vendor:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -w /work "$IMAGE" \
  bash -c '
    set -euo pipefail
    export PATH="/root/.cargo/bin:$PATH"
    export CARGO_NET_OFFLINE=true
    export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"
    cargo build --release -p hook -p limiter --offline
    sha256sum target/release/libvnpu.so target/release/limiter
  '

install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"
ls -la "$OUT/"
