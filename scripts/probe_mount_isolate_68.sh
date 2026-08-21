#!/usr/bin/env bash
# Isolate: full /usr/local/Ascend mount vs ubuntu-style mounts.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
PORT="${VLLM_PORT:-18117}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
MODEL=/mnt/local/m00953550/Qwen3-1.7B
MOUNT_MODE="${MOUNT_MODE:-full_ascend}"  # full_ascend | ubuntu_style
NAME=vnpu-probe-mount-${MOUNT_MODE}
TAG=$(date +%H%M%S)

docker rm -f "$NAME" 2>/dev/null || true
pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
sleep 2

vols=(
  -v "${FT}:/opt/ft"
  -v "${MODEL}:/models:ro"
  -v /etc/hccn.conf:/etc/hccn.conf:ro
  -v /usr/local/dcmi:/usr/local/dcmi:ro
  -v /usr/local/hami-shared-region:/hami-shared-region
  -v /dev/davinci_manager:/dev/davinci_manager
  -v /dev/devmm_svm:/dev/devmm_svm
  -v /dev/hisi_hdc:/dev/hisi_hdc
)
if [[ "$MOUNT_MODE" == "full_ascend" ]]; then
  vols+=(-v /usr/local/Ascend:/usr/local/Ascend:ro -e LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64")
else
  vols+=(
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro
    -v /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro
    -v /usr/local/Ascend/toolbox:/usr/local/Ascend/toolbox:ro
    -v /var/log/npu:/var/log/npu:ro
  )
fi

docker run -d --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -e VLLM_PLATFORM=ascend \
  "${vols[@]}" \
  quay.io/ascend/vllm-ascend:v0.13.0rc1 \
  bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:\${LD_LIBRARY_PATH:-}
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/nnal/atb/set_env.sh
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code --port ${PORT} --host 0.0.0.0 \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --gpu-memory-utilization 0.5 \
  --max-num-seqs 4 --served-model-name qwen3 --dtype bfloat16 \
  --max_model_len 4096 --max-num-batched-tokens 4096 \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
"

for i in $(seq 1 90); do curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break; sleep 5; done
curl -sf "http://127.0.0.1:${PORT}/health" || { docker logs "$NAME" 2>&1 | tail -30; exit 1; }
echo "mount=$MOUNT_MODE health_ok"
curl -s -w "\nHTTP:%{http_code}\n" "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":8,"stream":false}' | head -c 1200
echo ""
docker rm -f "$NAME" 2>/dev/null || true
