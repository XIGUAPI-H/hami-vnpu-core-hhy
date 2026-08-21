#!/usr/bin/env bash
# Build the optimized hook+limiter INSIDE the Kylin container so the artifact is
# linked against Kylin's glibc/cc (true Kylin release), then deploy to release-optimized.
set -euo pipefail

REPO="${REPO:-/mnt/local/m00953550/hami-vnpu-core}"
OUT="${OUT:-/mnt/local/m00953550/FinalTest/kylin/release-optimized}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
KYLIN_DIR="$(dirname "$OUT")"

[[ -f "$REPO/Cargo.toml" ]] || { echo "missing repo at $REPO"; exit 1; }
[[ -x /root/.cargo/bin/cargo ]] || { echo "missing host cargo at /root/.cargo/bin"; exit 1; }
install -d "$OUT"

docker run --rm \
  -v "$REPO:/work" \
  -v /root/.cargo:/root/.cargo \
  -v /root/.rustup:/root/.rustup \
  -v "$KYLIN_DIR:$KYLIN_DIR" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -e OUT="$OUT" \
  -w /work \
  "$IMAGE" \
  bash /work/scripts/kylin_container_build_inner.sh
