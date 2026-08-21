#!/usr/bin/env bash
# A/B perf on 68: Ubuntu SO + Ubuntu vLLM runtime + Ubuntu host aisbench.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
UB="${FT}/ubuntu"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18003}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
MODEL_HOST="${MODEL_HOST:-${FT}/models/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
VLLM_IMAGE="${VLLM_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
NPU_FIXED_SHARE_RATIO="${NPU_FIXED_SHARE_RATIO:-0}"
NPU_PRIORITY="${NPU_PRIORITY:-25}"
NPU_MEM_QUOTA="${NPU_MEM_QUOTA:-16000}"
SPLIT_TENANTS="${SPLIT_TENANTS:-1}"
# 6400MiB 配额下 0.5 利用率不够放权重+KV；大配额仍用 0.5
if [[ -z "${GPU_MEM_UTIL:-}" ]]; then
  if [[ "$NPU_MEM_QUOTA" -le 8000 ]]; then
    GPU_MEM_UTIL=0.9
  else
    GPU_MEM_UTIL=0.5
  fi
fi
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${UB}/logs/perf_ubuntu_p${NPU_PRIORITY}_split${SPLIT_TENANTS}_fixed${NPU_FIXED_SHARE_RATIO}_${TAG}.txt"
OPT_REL="${OPT_REL:-release-optimized}"
MAIN_REL="${MAIN_REL:-release-main}"
CONTENDER_PIDS=()

if [[ "$SPLIT_TENANTS" -gt 1 ]]; then
  GSHM_BASE="global_registry_split${SPLIT_TENANTS}_${TAG}"
else
  GSHM_BASE=""
fi

start_contenders() {
  local gshm="$1" so_rel="${MAIN_REL}"
  stop_contenders
  [[ "$SPLIT_TENANTS" -le 1 ]] && return 0
  local n=$((SPLIT_TENANTS - 1))
  echo ">>> starting ${n} contender limiters (1切${SPLIT_TENANTS}, prio=${NPU_PRIORITY} mem=${NPU_MEM_QUOTA})"
  local ascend_ld="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64"
  for ((i = 1; i <= n; i++)); do
    LD_LIBRARY_PATH="${ascend_ld}:${LD_LIBRARY_PATH:-}" \
    NPU_GLOBAL_SHM_PATH="${HAMi_SHM}/${gshm}" \
    NPU_LOCAL_SHM_NAME="vnpu_contender_${TAG}_${i}" \
    NPU_MEM_QUOTA="$NPU_MEM_QUOTA" \
    NPU_PRIORITY="$NPU_PRIORITY" \
    NPU_FIXED_SHARE_RATIO="$NPU_FIXED_SHARE_RATIO" \
      "${UB}/${so_rel}/limiter" > "${UB}/logs/contender-${TAG}-${i}.log" 2>&1 &
    CONTENDER_PIDS+=("$!")
    rm -f "/dev/shm/vnpu_contender_${TAG}_${i}" 2>/dev/null || true
  done
  sleep 2
  echo "contenders_up=$(pgrep -cf limiter || true)"
}

stop_contenders() {
  if ((${#CONTENDER_PIDS[@]} > 0)); then
    for pid in "${CONTENDER_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    CONTENDER_PIDS=()
  fi
  pkill -f "${UB}/${MAIN_REL}/limiter" 2>/dev/null || true
}

run_vllm() {
  local so_rel="$1" name="$2" gshm="$3" lshm="$4" limlog="$5"

  docker rm -f "$name" 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 3

  start_contenders "$gshm"

  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -e LD_PRELOAD="/opt/ft/ubuntu/${so_rel}/libvnpu.so" \
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
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2
export TORCH_COMPILE_DISABLE=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/${gshm}
export NPU_LOCAL_SHM_NAME=${lshm}
echo runtime=\$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)
echo SO=${so_rel} sha=\$(sha256sum /opt/ft/ubuntu/${so_rel}/libvnpu.so | cut -c1-16)
rm -f /dev/shm/${lshm} 2>/dev/null || true
/opt/ft/ubuntu/${so_rel}/limiter > /opt/ft/ubuntu/logs/${limlog} 2>&1 &
sleep 3
pgrep -x limiter || { cat /opt/ft/ubuntu/logs/${limlog}; exit 1; }
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
      docker logs "$name" 2>&1 | grep -E 'runtime=|SO=|vnpu|Application startup' | tail -6 || true
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
      docker logs --tail 50 "$name" 2>&1
      return 1
    fi
    sleep 10
  done
  docker logs --tail 50 "$name" 2>&1
  return 1
}

stop_vllm() {
  docker rm -f vnpu-ubuntu-perf-opt vnpu-ubuntu-perf-main 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  stop_contenders
  sleep 10
}

run_aisbench() {
  local out_tag="$1"
  OUT_TAG="$out_tag" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh"
}

extract_metric() {
  local csv="$1" key="$2"
  awk -F, -v k="$key" '$1==k && $2=="total" {print $3; exit}' "$csv"
}

mkdir -p "${UB}/logs"
{
  echo "=== Ubuntu full-stack perf on 68 ${TAG} ==="
  echo "host=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
  echo "vllm_image=${VLLM_IMAGE}"
  echo "NPU=$NPU PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS"
  echo "NPU_FIXED_SHARE_RATIO=$NPU_FIXED_SHARE_RATIO NPU_PRIORITY=$NPU_PRIORITY NPU_MEM_QUOTA=$NPU_MEM_QUOTA GPU_MEM_UTIL=$GPU_MEM_UTIL"
  echo "SPLIT_TENANTS=$SPLIT_TENANTS (1切${SPLIT_TENANTS} = ${SPLIT_TENANTS} tenants @ ${NPU_PRIORITY}% core each)"
  echo "optimized=$OPT_REL main=$MAIN_REL model=$MODEL_HOST"
  echo ""

  GSHM_OPT="${GSHM_BASE:-global_registry_ubuntu_opt_${TAG}}"
  GSHM_MAIN="${GSHM_BASE:-global_registry_ubuntu_main_${TAG}}"

  echo ">>> [A] ${OPT_REL} (Ubuntu SO + Ubuntu vLLM)"
  run_vllm "$OPT_REL" vnpu-ubuntu-perf-opt "$GSHM_OPT" "vnpu_ubuntu_opt_${TAG}" \
    "limiter-ubuntu-opt-${TAG}.log"
  run_aisbench "opt_${TAG}" | tee "${UB}/logs/aisbench_ubuntu_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*ubuntu_vllm_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_vllm

  echo ""
  echo ">>> [B] ${MAIN_REL} (Ubuntu SO + Ubuntu vLLM)"
  run_vllm "$MAIN_REL" vnpu-ubuntu-perf-main "$GSHM_MAIN" "vnpu_ubuntu_main_${TAG}" \
    "limiter-ubuntu-main-${TAG}.log"
  run_aisbench "main_${TAG}" | tee "${UB}/logs/aisbench_ubuntu_main_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*ubuntu_vllm_main_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_vllm

  echo ""
  echo "=== comparison (demo_gsm8k perf) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "optimized (Ubuntu)" "main (Ubuntu)"
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    printf "%-28s %-22s %-22s\n" "$m" "$a" "$b"
  done
  echo ""
  echo "CSV optimized: $CSV_A"
  echo "CSV main:      $CSV_B"
} | tee "$REPORT"

echo "report: $REPORT"
