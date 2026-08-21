#!/usr/bin/env bash
# Download Python 3.10 / aarch64 wheels on a machine WITH internet.
# Run on: aarch64 Linux (recommended: 61) OR any host with pip>=21 cross-download support.
#
#   bash scripts/download_py310_wheels.sh
#   scp -r openeuler/wheels root@10.143.2.68:/mnt/local/m00953550/FinalTest/openeuler/
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQ="${REQ:-$ROOT/scripts/openeuler_py310_requirements.txt}"
OUT="${OUT:-$ROOT/openeuler/wheels}"
PY="${PY:-python3.10}"
PIP="${PIP:-$PY -m pip}"

mkdir -p "$OUT"

echo "=== download py3.10 aarch64 wheels ==="
echo "requirements: $REQ"
echo "output:       $OUT"

# Prefer native aarch64 + py3.10 host (simplest, most reliable for compiled wheels).
if [[ "$(uname -m)" == "aarch64" ]] && "$PY" -c 'import sys; exit(0 if sys.version_info[:2]==(3,10) else 1)' 2>/dev/null; then
  echo "mode: native aarch64 python3.10"
  $PIP download -r "$REQ" -d "$OUT" \
    -i https://pypi.org/simple \
    --extra-index-url https://pypi.tuna.tsinghua.edu.cn/simple
else
  echo "mode: cross-download (manylinux aarch64, cp310)"
  echo "note: some packages may have no prebuilt wheel; use aarch64 build host if download fails."
  $PIP download -r "$REQ" -d "$OUT" \
    --platform manylinux2014_aarch64 \
    --platform linux_aarch64 \
    --python-version 310 \
    --implementation cp \
    --abi cp310 \
    --only-binary=:all: \
    -i https://pypi.org/simple
fi

echo ""
echo "=== downloaded $(ls -1 "$OUT" | wc -l) files ==="
ls -lh "$OUT" | head -20
echo "..."
echo ""
echo "Next:"
echo "  scp -r $OUT root@10.143.2.68:/mnt/local/m00953550/FinalTest/openeuler/"
echo "  ssh root@10.143.2.68 bash /mnt/local/m00953550/FinalTest/openeuler/install_py310_wheels.sh"
