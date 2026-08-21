#!/usr/bin/env bash
# Add vLLM extra wheels to py310-site (--no-deps, no wipe).
set -euo pipefail
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"
WHEELS="${WHEELS:-${VNPU_DIR}/wheels}"
SITE="${SITE:-${VNPU_DIR}/py310-site}"

docker run --rm \
  -v "${WHEELS}:/wheels:ro" \
  -v "${SITE}:/target" \
  "$IMAGE" \
  bash -c '
set -eo pipefail
PY=/root/miniconda3/envs/llm_test/bin/python
shopt -s nullglob
for w in /wheels/*.whl; do
  base=$(basename "$w")
  case "$base" in
    pydantic*|torch*|numpy*|transformers*|tokenizers*|safetensors*|huggingface_hub*|sympy*|mpmath*|pillow*)
      continue ;;
  esac
  $PY -m pip install --no-index --find-links=/wheels --target=/target --no-deps "$w" -q 2>/dev/null || true
done
PYTHONPATH=/target $PY -c "import gguf, cbor2; print(\"gguf+cbor2 OK\")"
'
