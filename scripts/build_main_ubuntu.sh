#!/usr/bin/env bash
# Build hami-vnpu-core-main (native wait_for_token + get_hbm_info) on Ubuntu host.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hami-vnpu-core-main}"
OUT="${OUT:-${FT}/ubuntu/release-main}"

[[ -f "$ROOT/Cargo.toml" ]] || { echo "missing $ROOT/Cargo.toml"; exit 1; }

echo "=== Ubuntu native/main build ==="
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' || true
uname -m

if ! command -v cargo >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || { echo "cargo not found"; exit 1; }

export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

cd "$ROOT"
cargo build --release -p hook -p limiter

mkdir -p "$OUT"
install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"

echo "=== artifacts ==="
ls -la "$OUT/"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
