#!/usr/bin/env bash
# Run vLLM natively inside Kylin V11 container (OS runtime = Kylin, not vllm-ascend Ubuntu).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
PY_ROOT="${KY}/vllm-extract/python3.11.13"
VLLM_WS="${KY}/vllm-extract/vllm-workspace"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18120}"
SO_REL="${SO_REL:-kylin/release-optimized}"
USE_LIMITER="${USE_LIMITER:-1}"
NAME="${VLLM_NAME:-vnpu-kylin-native-vllm}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
TAG="$(date +%H%M%S)"

[[ -d "$PY_ROOT" ]] || { echo "missing $PY_ROOT — extract from vllm-ascend first"; exit 1; }
[[ -d "$VLLM_WS" ]] || { echo "missing $VLLM_WS"; exit 1; }

docker rm -f "$NAME" 2>/dev/null || true
pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
sleep 2

lim=""
preload_export=""
if [[ -n "$SO_REL" ]]; then
  preload_export="export LD_PRELOAD=/opt/ft/${SO_REL}/libvnpu.so"
  if [[ "$USE_LIMITER" == "1" ]]; then
    lim="/opt/ft/${SO_REL}/limiter > /opt/ft/kylin/logs/limiter-native-${TAG}.log 2>&1 & sleep 3"
  fi
fi

docker run -d --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -e VLLM_PLATFORM=ascend \
  -v "${FT}:/opt/ft" \
  -v "${MODEL}:/models:ro" \
  -v "${PY_ROOT}:/usr/local/python3.11.13:ro" \
  -v "${VLLM_WS}:/vllm-workspace:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v "${HAMi_SHM}:/hami-shared-region" \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c "set -eo pipefail
mkdir -p /tmp/pylib
# Ubuntu-built CPython extensions expect soname libbz2.so.1.0; Kylin ships libbz2.so.1.0.8.
ln -sf /usr/lib64/libbz2.so.1.0.8 /tmp/pylib/libbz2.so.1.0 2>/dev/null || true
export LD_LIBRARY_PATH=/usr/local/python3.11.13/lib:/tmp/pylib:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/lib64:/lib64
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
${preload_export}
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/usr/local/python3.11.13/lib/python3.11/site-packages:/usr/local/Ascend/ascend-toolkit/latest/python/site-packages
export ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3 NPU_TOKEN_CHUNK=32
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_kylin_native_${TAG}
export NPU_LOCAL_SHM_NAME=vnpu_kylin_native_${TAG}
echo runtime=\$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)
echo SO=${SO_REL}
rm -f /dev/shm/vnpu_kylin_native_${TAG} 2>/dev/null || true
${lim}
/usr/local/python3.11.13/bin/python3.11 -c 'import torch,torch_npu; print(\"torch_npu_ok\")' || exit 1
exec /usr/local/python3.11.13/bin/python3.11 -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port ${PORT} --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 --max-num-seqs 4 --served-model-name qwen3 \
  --dtype bfloat16 --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
"

echo "waiting health :${PORT} ..."
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "health_ok elapsed=$((SECONDS))s"
    docker logs "$NAME" 2>&1 | grep -E 'runtime=|SO=|Application startup' | tail -6
    curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":8,"stream":false}' | head -c 800
    echo ""
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "container exited"
    docker logs "$NAME" 2>&1 | tail -50
    exit 1
  fi
  sleep 10
done
docker logs "$NAME" 2>&1 | tail -50
exit 1
