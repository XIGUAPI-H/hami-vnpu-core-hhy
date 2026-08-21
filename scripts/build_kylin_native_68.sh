#!/usr/bin/env bash
# Build origin + optimized libvnpu/limiter inside native Kylin V11 container.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
KY=$FT/kylin
VENDOR=/mnt/project/dongpengmin/hami_integration/hami-vnpu-core_build/vendor
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
ROOT_OPT="${ROOT_OPT:-/mnt/local/m00953550/hami-vnpu-core}"
ROOT_ORIGIN="${ROOT_ORIGIN:-$FT/ubuntu/hami-vnpu-origin/hami-vnpu-core-main}"
OUT_OPT="${OUT_OPT:-$KY/release-optimized}"
OUT_ORIGIN="${OUT_ORIGIN:-$KY/release-origin}"

build_tree() {
  local root="$1" out="$2" label="$3" features="${4:-}"
  echo "=== Kylin native build [$label] features=${features:-none} ==="
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
      ldd target/release/limiter | head -5 || true
    "
  install -m 755 "$root/target/release/libvnpu.so" "$root/target/release/limiter" "$out/"
  sha256sum "$out/libvnpu.so" "$out/limiter"
}

mkdir -p "$KY/logs" "$OUT_OPT" "$OUT_ORIGIN"

echo "=== Kylin build image ==="
docker run --rm "$IMAGE" bash -c 'cat /etc/os-release | head -3; ldd --version | head -1; uname -m'

[[ -f "$ROOT_ORIGIN/Cargo.lock" ]] || cp "$ROOT_OPT/../hami-vnpu-core-main/Cargo.lock" "$ROOT_ORIGIN/" 2>/dev/null || \
  cp /mnt/local/m00953550/hami-vnpu-core-main/Cargo.lock "$ROOT_ORIGIN/" 2>/dev/null || true

build_tree "$ROOT_OPT" "$OUT_OPT" "kylin-lite" "--features hook/kylin_lite"
build_tree "$ROOT_ORIGIN" "$OUT_ORIGIN" "origin" ""

echo "BUILD_KYLIN_NATIVE_OK"
ls -la "$OUT_OPT" "$OUT_ORIGIN"
