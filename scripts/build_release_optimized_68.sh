#!/usr/bin/env bash
set -euo pipefail
ROOT=/mnt/local/m00953550/hami-vnpu-core
OUT=/mnt/local/m00953550/FinalTest/kylin/release-optimized
IMAGE=swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm
docker run --rm \
  -v /root/.rustup:/root/.rustup:ro \
  -v /root/.cargo:/root/.cargo:ro \
  -v "${ROOT}:/work:rw" \
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
install -m 755 "${ROOT}/target/release/libvnpu.so" "${ROOT}/target/release/limiter" "${OUT}/"
sha256sum "${OUT}/libvnpu.so" "${OUT}/limiter"
