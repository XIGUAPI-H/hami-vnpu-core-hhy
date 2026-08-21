#!/usr/bin/env bash
# Build full optimized libvnpu (core_guard + core_scheduler) on Ubuntu host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-${ROOT}/ubuntu/release-optimized}"

cd "$ROOT"

echo "=== Ubuntu optimized build (hook/optimized + limiter/core_scheduler) ==="
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' || true
uname -m
ldd --version 2>&1 | head -1 || true

if ! command -v cargo >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || { echo "cargo not found"; exit 1; }

export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

cargo build --release -p hook -p limiter --features hook/optimized

mkdir -p "$OUT"
install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"

echo "=== artifacts ==="
ls -la "$OUT/"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
echo "=== core_guard symbols ==="
strings "$OUT/libvnpu.so" | grep -E "core limiter|scheduler_thread|wait_for_token|acquire_one" | head -12 || true
