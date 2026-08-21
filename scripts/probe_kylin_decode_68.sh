#!/usr/bin/env bash
# Reproduce Kylin SO decode issue and capture vLLM errors.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
KY=$FT/kylin
PORT="${VLLM_PORT:-18113}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
SO_REL="${SO_REL:-release-optimized}"
NAME=vnpu-kylin-probe
MODEL=/mnt/local/m00953550/Qwen3-1.7B
TAG=$(date +%H%M%S)

docker rm -f "$NAME" 2>/dev/null || true
pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
sleep 2

docker run -d --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -e LD_PRELOAD="/opt/ft/kylin/${SO_REL}/libvnpu.so" \
  -e VLLM_PLATFORM=ascend \
  -v "${FT}:/opt/ft" \
  -v "${MODEL}:/models:ro" \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro \
  -v /etc/hccn.conf:/etc/hccn.conf:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/Ascend/toolbox:/usr/local/Ascend/toolbox:ro \
  -v /var/log/npu:/var/log/npu:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  quay.io/ascend/vllm-ascend:v0.13.0rc1 \
  bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:\$LD_LIBRARY_PATH
source /usr/local/Ascend/nnal/atb/set_env.sh
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3 NPU_TOKEN_CHUNK=32
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_kylin_probe_${TAG}
export NPU_LOCAL_SHM_NAME=vnpu_kylin_probe_${TAG}
/opt/ft/kylin/${SO_REL}/limiter > /opt/ft/kylin/logs/limiter-probe-${TAG}.log 2>&1 &
sleep 3
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code --port ${PORT} --host 0.0.0.0 \
  --distributed-executor-backend mp --tensor-parallel-size 1 \
  --disable-frontend-multiprocessing --gpu-memory-utilization 0.5 \
  --max-num-seqs 4 --served-model-name qwen3 --dtype bfloat16 \
  --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
"

echo "waiting health :${PORT}..."
for i in $(seq 1 90); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 5
done
curl -sf "http://127.0.0.1:${PORT}/health" || { docker logs "$NAME" 2>&1 | tail -40; exit 1; }
echo "health_ok"

probe() {
  local label="$1" stream="$2"
  echo "=== probe $label stream=$stream ==="
  curl -s -w "\nHTTP_CODE:%{http_code}\n" "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1=?\"}],\"max_tokens\":32,\"stream\":${stream},\"temperature\":0.01}" \
    | head -c 2000
  echo ""
}

probe "non-stream" false
probe "stream" true

echo "=== docker errors ==="
docker logs "$NAME" 2>&1 | grep -iE 'ERROR|Exception|EngineCore|Worker|limiter|token|500' | tail -40
