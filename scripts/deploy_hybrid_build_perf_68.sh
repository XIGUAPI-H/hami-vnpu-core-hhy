#!/usr/bin/env bash
# Run on 68: sync source, build hybrid in openEuler container, A/B vs release-main.
set -euo pipefail

HOST="${HOST:-root@10.143.2.68}"
SSH_KEY="${SSH_KEY:-}"
ROOT_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FT="/mnt/local/m00953550/FinalTest"
OE="${FT}/openeuler"
REMOTE_ROOT="/mnt/local/m00953550/hami-vnpu-core-hybrid"
TAG="$(date +%Y%m%d_%H%M%S)"
TARBALL="/tmp/hami-vnpu-core-hybrid-${TAG}.tgz"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

echo "=== pack source ==="
tar -czf "$TARBALL" \
  --exclude='target' \
  --exclude='.git' \
  --exclude='hami-vnpu-core-main' \
  --exclude='ubs-virt-master' \
  --exclude='openeuler/wheels*' \
  -C "$ROOT_LOCAL" .

echo "=== upload to 68 ==="
scp "${SSH_OPTS[@]}" "$TARBALL" "${HOST}:/tmp/"

echo "=== remote build + perf ==="
ssh "${SSH_OPTS[@]}" "$HOST" bash -s <<REMOTE
set -euo pipefail
FT="$FT"
OE="$OE"
REMOTE_ROOT="$REMOTE_ROOT"
TAG="$TAG"
MAIN_VENDOR="/mnt/local/m00953550/hami-vnpu-core-main/vendor"

rm -rf "\$REMOTE_ROOT"
mkdir -p "\$REMOTE_ROOT"
tar -xzf "/tmp/hami-vnpu-core-hybrid-\${TAG}.tgz" -C "\$REMOTE_ROOT"

export OUT="\${OE}/release-hybrid"
export VENDOR_DIR="\$MAIN_VENDOR"
export CARGO_NET_OFFLINE=true
bash "\$REMOTE_ROOT/scripts/build_hybrid_openeuler.sh"

# ensure release-main exists for compare
if [[ ! -x "\${OE}/release-main/libvnpu.so" ]]; then
  echo "[WARN] \${OE}/release-main missing; building main..."
  OUT="\${OE}/release-main" bash "\$REMOTE_ROOT/scripts/build_main_openeuler.sh" || true
fi

install -m 755 "\$REMOTE_ROOT/scripts/compare_perf_hybrid_openeuler.sh" "\${OE}/compare_perf_hybrid_openeuler.sh"
HYBRID_REL=release-hybrid MAIN_REL=release-main bash "\${OE}/compare_perf_hybrid_openeuler.sh"
REMOTE

echo "=== done; check ${OE}/logs/perf_hybrid_*.txt on 68 ==="
