#!/usr/bin/env bash
# Phase 2: start vLLM inside openEuler container on 68 (params from newHamiJobVllm2.yaml).
# Run on host: bash /mnt/local/m00953550/FinalTest/openeuler/run_vllm_openeuler_phase2.sh
set -euo pipefail

IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"
VLLM_WS="${VLLM_WS:-${VNPU_DIR}/vllm-workspace}"
PY_SITE="${PY_SITE:-${VNPU_DIR}/py310-site}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
MODEL_HOST="${MODEL_HOST:-/mnt/local/m00953550/FinalTest/models/Qwen3-1.7B}"
CONTAINER_NAME="${CONTAINER_NAME:-vnpu-openeuler-vllm2}"
PORT="${VLLM_PORT:-18000}"
NPU_DEVICE="${ASCEND_RT_VISIBLE_DEVICES:-0}"
LOG_DIR="${VNPU_DIR}/logs"
WAIT_SECS="${WAIT_SECS:-900}"

mkdir -p "$LOG_DIR"

if [[ ! -d "$PY_SITE" ]] || [[ ! -d "$PY_SITE/uvloop" && ! -f "$PY_SITE/uvloop.py" ]]; then
  echo "py310-site missing — run install_py310_wheels.sh first"
  exit 1
fi

if [[ ! -d "$MODEL_HOST" ]]; then
  echo "Model not found at $MODEL_HOST — mounting NFS..."
  mkdir -p "$MODEL_HOST"
  mountpoint -q "$MODEL_HOST" || \
    mount -t nfs 10.143.2.99:/public/models/huggface_models/Qwen/Qwen3-1.7B "$MODEL_HOST" -o ro,nolock || {
      echo "NFS mount failed. Create $MODEL_HOST or set MODEL_HOST."
      exit 1
    }
fi

if [[ ! -d "$VLLM_WS/vllm" ]]; then
  echo "vllm-workspace missing at $VLLM_WS — extracting from vllm-ascend image..."
  mkdir -p "$VLLM_WS"
  cid=$(docker create quay.io/ascend/vllm-ascend:v0.13.0rc1)
  docker cp "$cid:/vllm-workspace/." "$VLLM_WS/"
  docker rm "$cid" >/dev/null
fi

echo "=== openEuler vLLM phase2 (py310-site wheels) ==="
echo "image:   $IMAGE"
echo "vnpu:    $VNPU_DIR/release"
echo "model:   $MODEL_HOST"
echo "port:    $PORT (host network)"
echo "npu:     $NPU_DEVICE"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

read -r -d '' INNER <<EOF || true
set -eo pipefail

export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:\${LD_LIBRARY_PATH:-}"
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh

export PYTHONPATH="/vllm-workspace/vllm:/vllm-workspace/vllm-ascend"
PY="/root/miniconda3/envs/llm_test/bin/python"
export ASCEND_HOME_PATH="/usr/local/Ascend/ascend-toolkit/latest"
SITE_APPEND="/opt/py310-site"

export LD_PRELOAD=/opt/vnpu/release/libvnpu.so
export VLLM_PLATFORM=ascend
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
export TASK_QUEUE_ENABLE=1
export VLLM_USE_V1=1
export HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1
export VLLM_ASCEND_ENABLE_NZ=2

export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_openeuler_vllm2"
export NPU_LOCAL_SHM_NAME="vnpu_openeuler_vllm2"
export NPU_MEM_QUOTA=16000
export NPU_PRIORITY=25

rm -f "/dev/shm/\${NPU_LOCAL_SHM_NAME}" 2>/dev/null || true
/opt/vnpu/release/limiter > /opt/vnpu/logs/limiter.log 2>&1 &
sleep 2
pgrep -x limiter || { echo "limiter failed:"; cat /opt/vnpu/logs/limiter.log; exit 1; }

echo "=== sanity: torch_npu + vllm import ==="
\$PY -c "import sys; sys.path.append('\${SITE_APPEND}'); import torch, torch_npu; print('torch', torch.__version__, 'npu', torch_npu.__version__)"
\$PY -c "import sys; sys.path.append('\${SITE_APPEND}'); import vllm; print('vllm', vllm.__version__)"
\$PY -c "import sys; sys.path.append('\${SITE_APPEND}'); from vllm.entrypoints.openai import api_server; print('api_server import OK')"

echo "=== starting vLLM api_server on port ${PORT} ==="
exec \$PY -c "
import sys, runpy
sys.path.append('\${SITE_APPEND}')
sys.argv = [
  'api_server',
  '--model=/models',
  '--trust-remote-code',
  '--distributed-executor-backend', 'mp',
  '--tensor-parallel-size', '1',
  '--pipeline-parallel-size', '1',
  '--disable-frontend-multiprocessing',
  '--port', '${PORT}',
  '--host', '0.0.0.0',
  '--gpu-memory-utilization', '0.5',
  '--max-num-seqs', '4',
  '--served-model-name', 'qwen3',
  '--dtype', 'bfloat16',
  '--max_model_len', '4096',
  '--max-num-batched-tokens', '4096',
  '--enable-auto-tool-choice',
  '--tool-call-parser', 'hermes',
  '--no-enable_expert_parallel',
  '--block-size', '128',
  '--async-scheduling',
  '--distributed_executor_backend', 'mp',
  '--compilation-config', '{\"cudagraph_mode\": \"FULL_DECODE_ONLY\",\"cudagraph_capture_sizes\":[1]}',
  '--no-enable-prefix-caching',
]
runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
"
EOF

docker run -d --name "$CONTAINER_NAME" \
  --privileged \
  --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU_DEVICE" \
  -v "${VNPU_DIR}:/opt/vnpu" \
  -v "${VLLM_WS}:/vllm-workspace:ro" \
  -v "${PY_SITE}:/opt/py310-site:ro" \
  -v "${MODEL_HOST}:/models:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v "${HAMi_SHM}:/hami-shared-region" \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c "$INNER"

echo "Container $CONTAINER_NAME started. Waiting for http://127.0.0.1:${PORT}/health ..."
deadline=$((SECONDS + WAIT_SECS))
ok=0
while (( SECONDS < deadline )); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "Container exited. Last logs:"
    docker logs --tail 80 "$CONTAINER_NAME" 2>&1 || true
    exit 1
  fi
  if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Application startup complete"; then
    ok=1
    break
  fi
  sleep 10
done

echo "=== docker logs (tail) ==="
docker logs --tail 40 "$CONTAINER_NAME" 2>&1 || true

if [[ "$ok" -eq 1 ]]; then
  echo "=== PASS: vLLM is up on port ${PORT} ==="
  curl -s "http://127.0.0.1:${PORT}/v1/models" | head -c 500 || true
  echo
  exit 0
fi

echo "=== TIMEOUT waiting for vLLM (${WAIT_SECS}s) ==="
docker logs --tail 120 "$CONTAINER_NAME" 2>&1 || true
exit 1
