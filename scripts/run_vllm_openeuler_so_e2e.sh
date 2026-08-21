#!/usr/bin/env bash
# E2E: vllm-ascend runtime + openEuler-built libvnpu.so/limiter (same params as newHamiJobVllm2.yaml).
# Validates openEuler hijack library under real vLLM workload when openEuler userland lacks vllm stack.
set -euo pipefail

VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"
IMAGE="${VLLM_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
MODEL_HOST="${MODEL_HOST:-/mnt/local/m00953550/FinalTest/models/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
CONTAINER_NAME="${CONTAINER_NAME:-vnpu-openeuler-so-e2e}"
PORT="${VLLM_PORT:-18000}"
NPU_DEVICE="${ASCEND_RT_VISIBLE_DEVICES:-0}"
WAIT_SECS="${WAIT_SECS:-900}"

mkdir -p "${VNPU_DIR}/logs"

if [[ ! -d "$MODEL_HOST" ]]; then
  mkdir -p "$MODEL_HOST"
  mountpoint -q "$MODEL_HOST" || \
    mount -t nfs 10.143.2.99:/public/models/huggface_models/Qwen/Qwen3-1.7B "$MODEL_HOST" -o ro,nolock
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d --name "$CONTAINER_NAME" \
  --privileged \
  --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU_DEVICE" \
  -e LD_PRELOAD="/opt/vnpu/release/libvnpu.so" \
  -e VLLM_PLATFORM=ascend \
  -v "${VNPU_DIR}:/opt/vnpu" \
  -v "${MODEL_HOST}:/models:ro" \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro \
  -v /etc/hccn.conf:/etc/hccn.conf:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/Ascend/toolbox:/usr/local/Ascend/toolbox:ro \
  -v /var/log/npu:/var/log/npu:ro \
  -v "${HAMi_SHM}:/hami-shared-region" \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  -v /mnt/local/m00953550/FinalTest:/mnt/local/m00953550/FinalTest \
  "$IMAGE" \
  bash -c "
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:\$LD_LIBRARY_PATH
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/nnal/atb/set_env.sh
export TASK_QUEUE_ENABLE=1
export VLLM_USE_V1=1
export HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1
export VLLM_ASCEND_ENABLE_NZ=2
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_openeuler_e2e
export NPU_LOCAL_SHM_NAME=vnpu_openeuler_e2e
export NPU_MEM_QUOTA=16000
export NPU_PRIORITY=25
rm -f /dev/shm/\${NPU_LOCAL_SHM_NAME} 2>/dev/null || true
/opt/vnpu/release/limiter > /opt/vnpu/logs/limiter-e2e.log 2>&1 &
sleep 2
pgrep -x limiter || { cat /opt/vnpu/logs/limiter-e2e.log; exit 1; }
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models \
  --trust-remote-code \
  --distributed-executor-backend mp \
  --tensor-parallel-size 1 \
  --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing \
  --port ${PORT} \
  --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 \
  --max-num-seqs 4 \
  --served-model-name qwen3 \
  --dtype bfloat16 \
  --max_model_len 4096 \
  --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --no-enable_expert_parallel \
  --block-size 128 \
  --async-scheduling \
  --distributed_executor_backend mp \
  --compilation-config '{\"cudagraph_mode\": \"FULL_DECODE_ONLY\",\"cudagraph_capture_sizes\":[1]}' \
  --no-enable-prefix-caching
"

echo "Waiting for vLLM on :${PORT} ..."
deadline=$((SECONDS + WAIT_SECS))
while (( SECONDS < deadline )); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "=== PASS: openEuler SO e2e vLLM up on :${PORT} ==="
    curl -s "http://127.0.0.1:${PORT}/v1/models" | head -c 400; echo
    docker logs --tail 20 "$CONTAINER_NAME" 2>&1
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker logs --tail 100 "$CONTAINER_NAME" 2>&1; exit 1
  fi
  if docker logs "$CONTAINER_NAME" 2>&1 | grep -q 'Application startup complete'; then
    echo "=== PASS (log): openEuler SO e2e vLLM up ==="
    curl -s "http://127.0.0.1:${PORT}/v1/models" | head -c 400; echo
    exit 0
  fi
  sleep 10
done
docker logs --tail 120 "$CONTAINER_NAME" 2>&1
exit 1
