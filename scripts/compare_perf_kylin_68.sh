#!/usr/bin/env bash
# Kylin-built SO A/B perf: origin vs optimized+paper, vLLM via ascend runtime container.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
KY_BUILD_IMAGE="${KYLIN_BUILD_IMAGE:-kylin-server:v11-2503-arm64}"
VLLM_IMAGE="${VLLM_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18103}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
MODEL_HOST="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
NPU_FIXED_SHARE_RATIO="${NPU_FIXED_SHARE_RATIO:-0}"
NPU_PRIORITY="${NPU_PRIORITY:-25}"
NPU_MEM_QUOTA="${NPU_MEM_QUOTA:-16000}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/perf_kylin_${TAG}.txt"
OPT_REL="${OPT_REL:-release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-release-origin}"

[[ -f "${KY}/${OPT_REL}/libvnpu.so" ]] || { echo "run build_kylin_native_68.sh first"; exit 1; }

run_vllm() {
  local so_rel="$1" name="$2" gshm="$3" lshm="$4" limlog="$5"

  docker rm -f "$name" 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 3

  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -e LD_PRELOAD="/opt/ft/kylin/${so_rel}/libvnpu.so" \
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
    "$VLLM_IMAGE" \
    bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:\$LD_LIBRARY_PATH
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/nnal/atb/set_env.sh
export NPU_MEM_QUOTA=${NPU_MEM_QUOTA} NPU_PRIORITY=${NPU_PRIORITY}
export NPU_FIXED_SHARE_RATIO=${NPU_FIXED_SHARE_RATIO}
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_FCSP_REFILL=${NPU_FCSP_REFILL:-1} NPU_BURST_CONTINUOUS=${NPU_BURST_CONTINUOUS:-1}
export NPU_BURST_ALPHA=${NPU_BURST_ALPHA:-0.3} NPU_TOKEN_CHUNK=${NPU_TOKEN_CHUNK:-32}
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/${gshm}
export NPU_LOCAL_SHM_NAME=${lshm}
echo build_os=${KY_BUILD_IMAGE}
echo runtime=\$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)
echo SO=${so_rel} sha=\$(sha256sum /opt/ft/kylin/${so_rel}/libvnpu.so | cut -c1-16)
rm -f /dev/shm/${lshm} 2>/dev/null || true
/opt/ft/kylin/${so_rel}/limiter > /opt/ft/kylin/logs/${limlog} 2>&1 &
sleep 3
pgrep -x limiter || { cat /opt/ft/kylin/logs/${limlog}; exit 1; }
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port ${PORT} --host 0.0.0.0 \
  --gpu-memory-utilization ${GPU_MEM_UTIL} --max-num-seqs 4 --served-model-name qwen3 \
  --dtype bfloat16 --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
"

  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "health_ok elapsed=$((SECONDS))s"
      docker logs "$name" 2>&1 | grep -E 'build_os|runtime=|SO=|Application startup' | tail -6 || true
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
      docker logs --tail 60 "$name" 2>&1
      return 1
    fi
    sleep 10
  done
  docker logs --tail 60 "$name" 2>&1
  return 1
}

stop_vllm() {
  docker rm -f vnpu-kylin-perf-opt vnpu-kylin-perf-origin 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 8
}

run_aisbench() {
  local out_tag="$1"
  OUT_TAG="$out_tag" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh"
}

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

mkdir -p "${KY}/logs"
{
  echo "=== Kylin SO perf on 68 ${TAG} ==="
  echo "kylin_build_image=${KY_BUILD_IMAGE}"
  echo "vllm_runtime=${VLLM_IMAGE}"
  docker run --rm "$KY_BUILD_IMAGE" cat /etc/os-release | head -3
  echo "NPU=$NPU PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS"
  echo "NPU_FIXED_SHARE_RATIO=$NPU_FIXED_SHARE_RATIO NPU_PRIORITY=$NPU_PRIORITY NPU_MEM_QUOTA=$NPU_MEM_QUOTA"
  echo "optimized=${OPT_REL} origin=${ORIGIN_REL} model=${MODEL_HOST}"
  echo ""

  echo ">>> [A] optimized+paper (Kylin-built ${OPT_REL})"
  run_vllm "$OPT_REL" vnpu-kylin-perf-opt "global_registry_kylin_opt_${TAG}" \
    "vnpu_kylin_opt_${TAG}" "limiter-kylin-opt-${TAG}.log"
  run_aisbench "kylin_opt_${TAG}" | tee "${KY}/logs/aisbench_kylin_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*ubuntu_vllm_kylin_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_vllm

  echo ""
  echo ">>> [B] origin (Kylin-built ${ORIGIN_REL})"
  run_vllm "$ORIGIN_REL" vnpu-kylin-perf-origin "global_registry_kylin_origin_${TAG}" \
    "vnpu_kylin_origin_${TAG}" "limiter-kylin-origin-${TAG}.log"
  run_aisbench "kylin_origin_${TAG}" | tee "${KY}/logs/aisbench_kylin_origin_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*ubuntu_vllm_kylin_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_vllm

  echo ""
  echo "=== comparison (demo_gsm8k perf) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "optimized+paper" "origin"
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    printf "%-28s %-22s %-22s\n" "$m" "$(extract_metric "$CSV_A" "$m")" "$(extract_metric "$CSV_B" "$m")"
  done
  echo "CSV opt: $CSV_A"
  echo "CSV origin: $CSV_B"
} | tee "$REPORT"
echo "report: $REPORT"
