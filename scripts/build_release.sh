#!/usr/bin/env bash
# Build libvnpu.so + limiter on the CURRENT host (must match runtime OS/glibc).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== host ==="
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' || true
uname -m
ldd --version 2>&1 | head -1 || true

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
  echo "[ERROR] Ascend libvnpu requires aarch64, got: $ARCH" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "[INFO] installing rustup (stable)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

echo "=== build ==="
cargo build --release -p hook -p limiter

OUT="$ROOT/target/release"
echo "=== artifacts ==="
ls -la "$OUT/libvnpu.so" "$OUT/limiter"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
echo
echo "Deploy pair together:"
echo "  LD_PRELOAD=$OUT/libvnpu.so"
echo "  $OUT/limiter"
