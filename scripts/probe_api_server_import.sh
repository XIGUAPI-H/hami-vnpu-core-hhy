#!/usr/bin/env bash
set -eo pipefail
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"

docker run --rm \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v "${VNPU_DIR}/vllm-workspace:/vllm-workspace:ro" \
  -v "${VNPU_DIR}/py-deps:/opt/py-deps:ro" \
  -v "${VNPU_DIR}/py-stubs:/opt/py-stubs:ro" \
  "$IMAGE" \
  bash -c '
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/opt/py-stubs:/vllm-workspace/vllm:/vllm-workspace/vllm-ascend
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -c "import sys; sys.path.append(\"/opt/py-deps\"); from vllm.entrypoints.openai import api_server; print(\"api_server import OK\")"
'
