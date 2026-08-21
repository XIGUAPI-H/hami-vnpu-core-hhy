#!/usr/bin/env bash
# Offline install minimal py3.10 wheels into persistent site dir on 68 host.
set -euo pipefail
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"
WHEELS="${WHEELS:-${VNPU_DIR}/wheels}"
SITE="${SITE:-${VNPU_DIR}/py310-site}"
REQ="${REQ:-${VNPU_DIR}/openeuler_py310_requirements_min.txt}"
PY="/root/miniconda3/envs/llm_test/bin/python"

if [[ ! -f "$REQ" ]]; then
  echo "Missing $REQ"
  exit 1
fi

echo "=== offline pip install (minimal) -> $SITE ==="
rm -rf "$SITE"
mkdir -p "$SITE"

docker run --rm \
  -v "${WHEELS}:/wheels:ro" \
  -v "${SITE}:/target" \
  -v "${REQ}:/requirements.txt:ro" \
  "$IMAGE" \
  bash -c '
set -eo pipefail
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -m pip install --no-index --find-links=/wheels -r /requirements.txt --target=/target exceptiongroup 2>&1 | tail -15
PYTHONPATH=/target $PY -c "import fastapi, uvicorn, openai, model_hosting_container_standards, uvloop; print(\"deps OK\")"
'

echo "=== minimal site ready at $SITE ==="
