#!/usr/bin/env bash
# Build hami-vnpu-origin (原始劫持库) on Ubuntu host.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hami-vnpu-origin/hami-vnpu-core-main}"
OUT="${OUT:-${FT}/ubuntu/release-origin}"
MAIN_LOCK="${MAIN_LOCK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hami-vnpu-core-main/Cargo.lock}"

[[ -f "$ROOT/Cargo.toml" ]] || { echo "missing $ROOT/Cargo.toml"; exit 1; }

echo "=== Ubuntu origin build (hami-vnpu-origin) ==="
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' || true
uname -m

if ! command -v cargo >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || { echo "cargo not found"; exit 1; }

export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

if [[ ! -f "$ROOT/Cargo.lock" && -f "$MAIN_LOCK" ]]; then
  cp "$MAIN_LOCK" "$ROOT/Cargo.lock"
  echo "seeded Cargo.lock from hami-vnpu-core-main"
fi

if [[ -d "${VENDOR:-}" ]]; then
  ln -sfn "$VENDOR" "$ROOT/vendor"
  mkdir -p "$ROOT/.cargo"
  cat > "$ROOT/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF
fi

cd "$ROOT"
cargo build --release -p hook -p limiter

mkdir -p "$OUT"
install -m 755 "$ROOT/target/release/libvnpu.so" "$ROOT/target/release/limiter" "$OUT/"

echo "=== artifacts ==="
ls -la "$OUT/"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter"
