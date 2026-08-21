#!/usr/bin/env bash
# Probe decode with ubuntu-perf mount/env (no full /usr/local/Ascend bind).
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
PORT="${VLLM_PORT:-18115}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
MODEL="${MODEL:-/mnt/local/m00953550/Qwen3-1.7B}"
SO_REL="${SO_REL:-ubuntu/release-optimized}"
USE_LIMITER="${USE_LIMITER:-1}"
NAME=vnpu-probe-ubuntu-mount
TAG=$(date +%H%M%S)

docker rm -f "$NAME" 2>/dev/null || true
pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
sleep 2

preload=()
lim=""
if [[ -n "${SO_REL}" ]]; then
  preload=(-e "LD_PRELOAD=/opt/ft/${SO_REL}/libvnpu.so")
  if [[ "$USE_LIMITER" == "1" ]]; then
    lim="/opt/ft/${SO_REL}/limiter > /opt/ft/ubuntu/logs/limiter-probe-${TAG}.log 2>&1 & sleep 3"
  fi
fi

docker run -d --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  "${preload[@]}" \
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
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/nnal/atb/set_env.sh
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3 NPU_TOKEN_CHUNK=32
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_probe_um_${TAG}
export NPU_LOCAL_SHM_NAME=vnpu_probe_um_${TAG}
rm -f /dev/shm/vnpu_probe_um_${TAG} 2>/dev/null || true
${lim}
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port ${PORT} --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 --max-num-seqs 4 --served-model-name qwen3 \
  --dtype bfloat16 --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
"

for i in $(seq 1 90); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 5
done
curl -sf "http://127.0.0.1:${PORT}/health" || { docker logs "$NAME" 2>&1 | tail -40; exit 1; }
echo health_ok

resp=$(curl -s -w "\nHTTP:%{http_code}" "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":32,"stream":false,"temperature":0.01}')
echo "$resp" | head -c 2500
echo ""

tok=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens','?'))" 2>/dev/null || echo parse_fail)
echo "completion_tokens=$tok"

echo "--- Worker errors ---"
docker logs "$NAME" 2>&1 | grep -iE 'Worker pid.*ERROR|Worker.*Exception|Worker.*Traceback|Worker.*died|SIGSEGV|aclError' | tail -30

docker rm -f "$NAME" 2>/dev/null || true
