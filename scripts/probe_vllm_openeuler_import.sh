#!/usr/bin/env bash
set -euo pipefail
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VLLM_WS="${VLLM_WS:-/mnt/local/m00953550/FinalTest/openeuler/vllm-workspace}"

docker run --rm \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v "${VLLM_WS}:/vllm-workspace:ro" \
  "$IMAGE" \
  bash -c '
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -c "import sys; print(sys.version)"
$PY -c "import torch, torch_npu; print(torch.__version__, torch_npu.__version__)"
$PY -c "import vllm; print(vllm.__version__)"
'
