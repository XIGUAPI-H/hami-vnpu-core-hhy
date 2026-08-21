#!/usr/bin/env bash
# Build Kylin opt SO from Jun-24-era tree (FCSP + burst, no kylin_preset).
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
KY=$FT/kylin
ROOT="${ROOT_JUN24:-$FT/ubuntu/src}"
VENDOR="${VENDOR:-/mnt/local/m00953550/hami-vnpu-core-main/vendor}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
OUT="${OUT:-$KY/release-jun24-snapshot}"
TAG="$(date +%Y%m%d_%H%M%S)"

[[ -f "$ROOT/Cargo.toml" ]] || { echo "missing $ROOT/Cargo.toml"; exit 1; }

mkdir -p "$OUT" "$KY/logs"

docker run --rm \
  -v /root/.rustup:/root/.rustup:ro \
  -v /root/.cargo:/root/.cargo:ro \
  -v "$ROOT:/work:rw" \
  -v "$VENDOR:/work/vendor:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -w /work "$IMAGE" \
  bash -c "
    set -euo pipefail
    export PATH=\"/root/.cargo/bin:\$PATH\"
    export CARGO_NET_OFFLINE=true
    export LD_LIBRARY_PATH=\"/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:\${LD_LIBRARY_PATH:-}\"
    mkdir -p /work/.cargo
    cat > /work/.cargo/config.toml <<EOF
[source.crates-io]
replace-with = \"vendored-sources\"
[source.vendored-sources]
directory = \"vendor\"
EOF
    cargo build --release -p hook -p limiter --offline
    sha256sum target/release/libvnpu.so target/release/limiter
  " | tee "${KY}/logs/build_kylin_jun24_${TAG}.log"

install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"
MANIFEST="$OUT/MANIFEST_${TAG}.txt"
{
  echo "build_tag=$TAG"
  echo "profile=jun24-snapshot (ubuntu/src, FCSP+burst, no kylin_preset)"
  echo "source_root=$ROOT"
  echo "target_sha_jun24_winner=3ccf2b4b4322eaf7c3936721a316fee02ecc07d1daf9a03a0ff709dfa9d19fff"
  echo "repro_env=NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8"
  sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
} | tee "$MANIFEST"
ln -sfn "$MANIFEST" "$OUT/MANIFEST.latest"
echo "BUILD_KYLIN_JUN24_OK out=$OUT"
