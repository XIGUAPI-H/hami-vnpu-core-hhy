#!/usr/bin/env bash
set -eo pipefail
VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"
PY_DEPS="${PY_DEPS:-${VNPU_DIR}/py-deps}"
SRC_IMAGE="${SRC_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
SP="/usr/local/python3.11.13/lib/python3.11/site-packages"

rm -rf "$PY_DEPS"
mkdir -p "$PY_DEPS"

docker run --rm "$SRC_IMAGE" bash -c "
cd '$SP'
tar cf - \$(ls | grep -vE '^(torch|torch_npu|numpy|vllm)(-|\$)')
" | tar -C "$PY_DEPS" -xf -

echo "py-deps ready: $(ls \"$PY_DEPS\" | wc -l) entries at $PY_DEPS"
