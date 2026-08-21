#!/usr/bin/env bash
set -euo pipefail
IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"
FT="/mnt/local/m00953550/FinalTest"
OE="${FT}/openeuler"
NAME="vnpu-ubuntu-so-oe-test"
PORT=18001
NPU=1
WAIT=300

docker rm -f "$NAME" 2>/dev/null || true

docker run -d --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${FT}:/opt/ft:ro" \
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
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend
PY=/root/miniconda3/envs/llm_test/bin/python
export LD_PRELOAD=/opt/ft/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_ubuntu_so_oe_test
export NPU_LOCAL_SHM_NAME=vnpu_ubuntu_so_oe_test
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 VLLM_PLATFORM=ascend VLLM_USE_V1=1 TASK_QUEUE_ENABLE=1
echo "=== Ubuntu so + openEuler container ==="
ldd /opt/ft/limiter | head -2
rm -f /dev/shm/${NPU_LOCAL_SHM_NAME} 2>/dev/null || true
/opt/ft/limiter > /tmp/limiter.log 2>&1 & sleep 2
pgrep -x limiter || { cat /tmp/limiter.log; exit 1; }
$PY -c "import sys; sys.path.append(\"/opt/py310-site\"); import torch, torch_npu; print(\"torch_ok\")"
$PY -c "import sys; sys.path.append(\"/opt/py310-site\"); from vllm.entrypoints.openai import api_server; print(\"api_server_ok\")"
exec $PY -c "import sys,runpy; sys.path.append(\"/opt/py310-site\"); sys.argv=[\"api_server\",\"--model=/models\",\"--trust-remote-code\",\"--port\",\"18001\",\"--host\",\"0.0.0.0\",\"--served-model-name\",\"qwen3\",\"--dtype\",\"bfloat16\",\"--max_model_len\",\"4096\",\"--gpu-memory-utilization\",\"0.5\",\"--max-num-seqs\",\"4\",\"--distributed-executor-backend\",\"mp\",\"--tensor-parallel-size\",\"1\"]; runpy.run_module(\"vllm.entrypoints.openai.api_server\",run_name=\"__main__\")"'

echo "container started, polling :${PORT} ..."
deadline=$((SECONDS + WAIT))
while (( SECONDS < deadline )); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "RESULT: PASS - vLLM health OK (Ubuntu so, openEuler container)"
    docker logs --tail 12 "$NAME" 2>&1
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "RESULT: FAIL - container exited"
    docker logs --tail 35 "$NAME" 2>&1
    exit 1
  fi
  if docker logs "$NAME" 2>&1 | grep -q 'Application startup complete'; then
    echo "RESULT: PASS - startup complete"
    exit 0
  fi
  sleep 12
done
echo "RESULT: TIMEOUT (no health in ${WAIT}s)"
docker logs --tail 40 "$NAME" 2>&1
exit 1
