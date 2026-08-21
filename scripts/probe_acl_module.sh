#!/usr/bin/env bash
set -eo pipefail
OE_IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"
VLLM_IMAGE="quay.io/ascend/vllm-ascend:v0.13.0rc1"

echo "=== openEuler image ==="
docker run --rm -v /usr/local/Ascend:/usr/local/Ascend:ro "$OE_IMAGE" bash -c '
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash 2>/dev/null || true
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -c "import acl; print(acl.__file__)" 2>&1 || true
find /usr/local/Ascend -name "acl" -type d 2>/dev/null | head -8
find /root/miniconda3 -path "*/acl/__init__.py" 2>/dev/null | head -5
'

echo "=== vllm-ascend image ==="
docker run --rm "$VLLM_IMAGE" bash -c '
python -c "import acl; print(acl.__file__)" 2>&1 || true
find /usr/local -path "*/acl/__init__.py" 2>/dev/null | head -5
'
