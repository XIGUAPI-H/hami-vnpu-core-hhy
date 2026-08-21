#!/usr/bin/env bash
# Rebuild Jun-24 "best" Kylin hijack: paper limiter + default hook.rs (no kylin_lite / no hook/optimized).
# Installs to kylin/release-optimized-best and kylin/release-optimized.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
KY=$FT/kylin
VENDOR="${VENDOR:-/mnt/local/m00953550/hami-vnpu-core-main/vendor}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
ROOT_OPT="${ROOT_OPT:-/mnt/local/m00953550/hami-vnpu-core}"
ROOT_ORIGIN="${ROOT_ORIGIN:-$FT/ubuntu/hami-vnpu-origin/hami-vnpu-core-main}"
OUT_BEST="${OUT_BEST:-$KY/release-optimized-best}"
OUT_OPT="${OUT_OPT:-$KY/release-optimized}"
OUT_ORIGIN="${OUT_ORIGIN:-$KY/release-origin}"
TAG="$(date +%Y%m%d_%H%M%S)"

build_tree() {
  local root="$1" out="$2" label="$3" features="${4:-}"
  echo "=== Kylin paper build [$label] features=${features:-none} ==="
  mkdir -p "$out"
  docker run --rm \
    -v /root/.rustup:/root/.rustup:ro \
    -v /root/.cargo:/root/.cargo:ro \
    -v "$root:/work:rw" \
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
      cargo build --release -p hook -p limiter ${features} --offline
      sha256sum target/release/libvnpu.so target/release/limiter
      nm -D target/release/libvnpu.so 2>/dev/null | grep -E 'wait_for_token|end_kernel_burst|core_guard' | head -5 || true
    "
  install -m 755 "$root/target/release/libvnpu.so" "$root/target/release/limiter" "$out/"
  sha256sum "$out/libvnpu.so" "$out/limiter"
}

mkdir -p "$KY/logs" "$OUT_BEST" "$OUT_OPT" "$OUT_ORIGIN"

echo "=== Kylin build image ==="
docker run --rm "$IMAGE" bash -c 'cat /etc/os-release | head -3; ldd --version | head -1; uname -m'

[[ -f "$ROOT_ORIGIN/Cargo.lock" ]] || cp "$ROOT_OPT/../hami-vnpu-core-main/Cargo.lock" "$ROOT_ORIGIN/" 2>/dev/null || \
  cp /mnt/local/m00953550/hami-vnpu-core-main/Cargo.lock "$ROOT_ORIGIN/" 2>/dev/null || true

# Paper stack: burst limiter + hook.rs (matches 2026-06-24 fcsp0_chunk8 winner).
build_tree "$ROOT_OPT" "$OUT_BEST" "paper-best" ""
cp -a "$OUT_BEST/libvnpu.so" "$OUT_BEST/limiter" "$OUT_OPT/"

if [[ ! -f "$OUT_ORIGIN/libvnpu.so" ]]; then
  build_tree "$ROOT_ORIGIN" "$OUT_ORIGIN" "origin" ""
fi

MANIFEST="$OUT_BEST/MANIFEST_${TAG}.txt"
{
  echo "build_tag=$TAG"
  echo "profile=kylin-paper-best (hook.rs, no kylin_lite, no hook/optimized)"
  echo "repro_env=NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8"
  echo "reference=kylin_native_sweep_20260624_020946 fcsp0_chunk8"
  echo "paths:"
  echo "  best=$OUT_BEST/libvnpu.so"
  echo "  opt=$OUT_OPT/libvnpu.so"
  echo "  origin=$OUT_ORIGIN/libvnpu.so"
  sha256sum "$OUT_BEST/libvnpu.so" "$OUT_BEST/limiter" "$OUT_ORIGIN/libvnpu.so" 2>/dev/null || true
  ls -la "$OUT_BEST" "$OUT_OPT" "$OUT_ORIGIN"
} | tee "$MANIFEST"

ln -sfn "$MANIFEST" "$OUT_BEST/MANIFEST.latest"
echo "BUILD_KYLIN_PAPER_BEST_OK manifest=$MANIFEST"
