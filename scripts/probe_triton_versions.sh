#!/usr/bin/env bash
set -eo pipefail
OE_IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"
VLLM_IMAGE="quay.io/ascend/vllm-ascend:v0.13.0rc1"

echo "=== vllm-ascend triton ==="
docker run --rm "$VLLM_IMAGE" bash -c 'python --version; pip show triton | grep -E "Name|Version|Location"; find /usr/local -path "*/triton/backends/ascend/*" -name "*.so" 2>/dev/null | head -8'

echo "=== openEuler mindspeed triton ==="
docker run --rm "$OE_IMAGE" bash -c '/root/miniconda3/envs/llm_test/bin/pip show triton | grep -E "Name|Version|Location"; ls /root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton/backends/ascend/ 2>/dev/null | head -8'

echo "=== host CANN ==="
ls -la /usr/local/Ascend/ascend-toolkit/ 2>/dev/null | head -5
