#!/usr/bin/env bash
# openEuler container + Ubuntu so + vLLM (vllm-workspace + offline py deps).
set -euo pipefail

IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"
FT="/mnt/local/m00953550/FinalTest"
OE="${FT}/openeuler"
NAME="vnpu-ubuntu-so-oe-vllm"
PORT="${VLLM_PORT:-18003}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-2}"
WAIT=600

mkdir -p "${OE}/logs" "${FT}/logs"

docker rm -f "$NAME" 2>/dev/null || true

docker run -d --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${FT}:/opt/ft" \
  -v "${OE}/vllm-workspace:/vllm-workspace:ro" \
  -v "${OE}/py310-site:/opt/py310-site:ro" \
  -v "${FT}/models/Qwen3-1.7B:/models:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c 'set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site${PYTHONPATH:+:$PYTHONPATH}
PY=/root/miniconda3/envs/llm_test/bin/python
SITE="/opt/py310-site"
export LD_PRELOAD=/opt/ft/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_ubuntu_so_oe_vllm
export NPU_LOCAL_SHM_NAME=vnpu_ubuntu_so_oe_vllm
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
export VLLM_PLATFORM=ascend VLLM_USE_V1=1 TASK_QUEUE_ENABLE=1
export HCCL_OP_EXPANSION_MODE=AIV PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=1 VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2
export TORCH_COMPILE_DISABLE=1
export ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest

# Host CANN 8.1 headers break triton ascend JIT; hide triton so vLLM skips FLA patches.
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d "$TRITON_PKG" && ! -d "${TRITON_PKG}.disabled" ]] && mv "$TRITON_PKG" "${TRITON_PKG}.disabled"

echo "=== openEuler container + Ubuntu so ==="
ldd /opt/ft/limiter | head -2
rm -f /dev/shm/${NPU_LOCAL_SHM_NAME} 2>/dev/null || true
/opt/ft/limiter > /opt/ft/logs/limiter-ubuntu-oe.log 2>&1 & sleep 5
pgrep -f /opt/ft/limiter || { cat /opt/ft/logs/limiter-ubuntu-oe.log; exit 1; }

$PY -c "import sys; sys.path.insert(0,\"/opt/py310-site\"); import torch,torch_npu; print(\"torch_ok\")"
$PY -c "import sys; sys.path.insert(0,\"/opt/py310-site\"); from vllm.entrypoints.openai import api_server; print(\"api_server_ok\")"

exec $PY -c "
import sys, runpy
sys.path.insert(0, \"/opt/py310-site\")
sys.argv = [
  \"api_server\", \"--model=/models\", \"--trust-remote-code\",
  \"--distributed-executor-backend\", \"mp\", \"--tensor-parallel-size\", \"1\",
  \"--pipeline-parallel-size\", \"1\", \"--disable-frontend-multiprocessing\",
  \"--port\", \"18003\", \"--host\", \"0.0.0.0\",
  \"--gpu-memory-utilization\", \"0.5\", \"--max-num-seqs\", \"4\",
  \"--served-model-name\", \"qwen3\", \"--dtype\", \"bfloat16\",
  \"--max_model_len\", \"4096\", \"--max-num-batched-tokens\", \"4096\",
  \"--enable-auto-tool-choice\", \"--tool-call-parser\", \"hermes\",
  \"--no-enable_expert_parallel\", \"--block-size\", \"128\",
  \"--async-scheduling\", \"--distributed_executor_backend\", \"mp\",
  \"--enforce-eager\",
  \"--no-enable-prefix-caching\",
]
runpy.run_module(\"vllm.entrypoints.openai.api_server\", run_name=\"__main__\")
"'

echo "polling :${PORT} ..."
deadline=$((SECONDS + WAIT))
while (( SECONDS < deadline )); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && {
    echo "=== PASS: openEuler container + Ubuntu so + vLLM :${PORT} ==="
    docker logs "$NAME" 2>&1 | grep -E 'vnpu|Application startup' | tail -5
    curl -s "http://127.0.0.1:${PORT}/v1/models" | head -c 280; echo
    exit 0
  }
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "=== FAIL: exited ==="; docker logs --tail 45 "$NAME" 2>&1; exit 1
  fi
  docker logs "$NAME" 2>&1 | grep -q 'Application startup complete' && {
    echo "=== PASS (startup log) ==="; exit 0
  }
  sleep 15
done
docker logs --tail 50 "$NAME" 2>&1; exit 1
