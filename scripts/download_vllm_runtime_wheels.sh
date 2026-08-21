#!/usr/bin/env bash
# Windows or any host with PyPI: download cp310 aarch64 wheels for openEuler vLLM.
#   bash scripts/download_vllm_runtime_wheels.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQ="${REQ:-$ROOT/scripts/requirements_vllm_runtime.txt}"
OUT="${OUT:-$ROOT/openeuler/wheels-full}"
PY="${PY:-python}"

mkdir -p "$OUT"
# relax pins that lack aarch64 cp310 wheels
sed -e 's/outlines_core==0.2.11/outlines_core==0.2.3/' \
    -e 's/jiter==0.12.0/jiter==0.15.0/' \
    -e 's/pyzmq==27.1.0/pyzmq==26.4.0/' \
    -e '/^opencv-python-headless/d' \
    -e '/^modelscope/d' \
    -e '/^anthropic/d' \
    "$REQ" > "$OUT/requirements.resolved.txt"

echo "downloading to $OUT ..."
$PY -m pip download -r "$OUT/requirements.resolved.txt" -d "$OUT" \
  --platform manylinux2014_aarch64 \
  --platform linux_aarch64 \
  --python-version 310 \
  --implementation cp \
  --abi cp310 \
  --only-binary=:all: \
  --no-deps \
  -i https://pypi.org/simple 2>&1 | tail -20 || true

# packages that may need no-binary or second pass
for pkg in xgrammar outlines outlines_core; do
  $PY -m pip download "$pkg" -d "$OUT" \
    --platform manylinux2014_aarch64 --python-version 310 \
    --implementation cp --abi cp310 --only-binary=:all: \
    -i https://pypi.org/simple 2>/dev/null || true
done

echo "wheels: $(ls -1 "$OUT"/*.whl 2>/dev/null | wc -l)"
