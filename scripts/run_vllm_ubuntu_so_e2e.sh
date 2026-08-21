#!/usr/bin/env bash
# E2E: vllm-ascend runtime + Ubuntu-built (61) libvnpu.so/limiter
set -euo pipefail

FT="/mnt/local/m00953550/FinalTest"
IMAGE="${VLLM_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
MODEL_HOST="${MODEL_HOST:-${FT}/models/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
CONTAINER_NAME="${CONTAINER_NAME:-vnpu-ubuntu-so-e2e}"
PORT="${VLLM_PORT:-18002}"
NPU_DEVICE="${ASCEND_RT_VISIBLE_DEVICES:-1}"
WAIT_SECS="${WAIT_SECS:-600}"

mkdir -p "${FT}/logs"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d --name "$CONTAINER_NAME" \
  --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU_DEVICE" \
  -e LD_PRELOAD="/opt/ft/libvnpu.so" \
  -e VLLM_PLATFORM=ascend \
  -v "${FT}:/opt/ft" \
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
  "$IMAGE" \
  bash -c "
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:\$LD_LIBRARY_PATH
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/nnal/atb/set_env.sh
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_ubuntu_so_e2e
export NPU_LOCAL_SHM_NAME=vnpu_ubuntu_so_e2e
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
rm -f /dev/shm/\${NPU_LOCAL_SHM_NAME} 2>/dev/null || true
/opt/ft/limiter > /opt/ft/logs/limiter-ubuntu-e2e.log 2>&1 &
sleep 2
pgrep -x limiter || { cat /opt/ft/logs/limiter-ubuntu-e2e.log; exit 1; }
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port ${PORT} --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 --max-num-seqs 4 --served-model-name qwen3 \
  --dtype bfloat16 --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --compilation-config '{\"cudagraph_mode\": \"FULL_DECODE_ONLY\",\"cudagraph_capture_sizes\":[1]}' \
  --no-enable-prefix-caching
"

echo "Waiting :${PORT} ..."
deadline=$((SECONDS + WAIT_SECS))
while (( SECONDS < deadline )); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && {
    echo "=== PASS: Ubuntu so + vllm-ascend on :${PORT} ==="
    curl -s "http://127.0.0.1:${PORT}/v1/models" | head -c 300; echo
    docker logs "$CONTAINER_NAME" 2>&1 | grep -E 'vnpu|limiter|Application startup' | tail -5
    exit 0
  }
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "=== FAIL: container exited ==="
    docker logs --tail 50 "$CONTAINER_NAME" 2>&1; exit 1
  fi
  docker logs "$CONTAINER_NAME" 2>&1 | grep -q 'Application startup complete' && {
    echo "=== PASS (log) ==="; exit 0
  }
  sleep 12
done
docker logs --tail 60 "$CONTAINER_NAME" 2>&1
exit 1
