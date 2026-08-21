#!/usr/bin/env bash
# A/B perf on Ubuntu: optimized (core_guard) vs release-main (native).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
UB="${FT}/ubuntu"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18003}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
MODEL_PATH="${MODEL_PATH:-/mnt/project/mhw_68/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${UB}/logs/perf_optimized_${TAG}.txt"
OPT_REL="${OPT_REL:-release-optimized}"
MAIN_REL="${MAIN_REL:-release-main}"
LOG_DIR="${UB}/logs"

run_vllm() {
  local so_rel="$1" gshm="$2" lshm="$3" limlog="$4" extra_env="${5:-}"
  local so_dir="${UB}/${so_rel}"

  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 3

  export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"
  set +u
  # shellcheck disable=SC1091
  [[ -f /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash ]] && source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
  # shellcheck disable=SC1091
  [[ -f /usr/local/Ascend/nnal/atb/set_env.sh ]] && source /usr/local/Ascend/nnal/atb/set_env.sh
  set -u

  export LD_PRELOAD="${so_dir}/libvnpu.so"
  export ASCEND_RT_VISIBLE_DEVICES="${NPU}"
  export NPU_GLOBAL_SHM_PATH="${HAMi_SHM}/${gshm}"
  export NPU_LOCAL_SHM_NAME="${lshm}"
  export NPU_MEM_QUOTA=16000
  export NPU_PRIORITY=25
  export VXPU_MEMINFO_USE_DCMI=0
  export VXPU_ENABLE_MALLOC_QUOTA=0
  export VLLM_PLATFORM=ascend
  export VLLM_USE_V1=1
  export TASK_QUEUE_ENABLE=1
  export HCCL_OP_EXPANSION_MODE=AIV
  export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
  export OMP_NUM_THREADS=1
  export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1
  export VLLM_ASCEND_ENABLE_NZ=2
  export TORCH_COMPILE_DISABLE=1

  eval "$extra_env"

  rm -f "/dev/shm/${lshm}" 2>/dev/null || true
  echo "SO=${so_rel} sha=$(sha256sum "${so_dir}/libvnpu.so" | cut -c1-16)"
  "${so_dir}/limiter" > "${LOG_DIR}/${limlog}" 2>&1 &
  sleep 3
  pgrep -x limiter || { cat "${LOG_DIR}/${limlog}"; return 1; }

  python3 -m vllm.entrypoints.openai.api_server \
    --model="${MODEL_PATH}" \
    --trust-remote-code \
    --distributed-executor-backend mp \
    --tensor-parallel-size 1 \
    --pipeline-parallel-size 1 \
    --disable-frontend-multiprocessing \
    --port "${PORT}" \
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
    --enforce-eager \
    --no-enable-prefix-caching \
    > "${LOG_DIR}/vllm_${so_rel}_${TAG}.log" 2>&1 &

  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "health_ok elapsed=$((SECONDS))s"
      grep -E 'vnpu|core limiter|Application startup' "${LOG_DIR}/vllm_${so_rel}_${TAG}.log" | tail -5 || true
      return 0
    fi
    if ! pgrep -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" >/dev/null; then
      tail -40 "${LOG_DIR}/vllm_${so_rel}_${TAG}.log"
      return 1
    fi
    sleep 10
  done
  tail -40 "${LOG_DIR}/vllm_${so_rel}_${TAG}.log"
  return 1
}

stop_vllm() {
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 10
}

run_aisbench() {
  local label="$1" out_tag="$2"
  OUT_TAG="$out_tag" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh"
}

extract_metric() {
  local csv="$1" key="$2"
  awk -F, -v k="$key" '$1==k && $2=="total" {print $3; exit}' "$csv"
}

mkdir -p "${UB}/logs"

{
  echo "=== Ubuntu optimized vs native perf ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS"
  echo "optimized=$OPT_REL main=$MAIN_REL"
  echo "model=$MODEL_PATH"
  echo ""

  echo ">>> [A] release-optimized (core_guard + apply_quota)"
  t0=$SECONDS
  run_vllm "$OPT_REL" "global_registry_perf_opt_${TAG}" "vnpu_perf_opt_${TAG}" "limiter-opt-${TAG}.log" \
    'export VXPU_CORE_SCHEDULER=1 VXPU_WORKER_ROLE=worker'
  opt_up=$((SECONDS - t0))
  run_aisbench optimized "opt_${TAG}" | tee "${UB}/logs/aisbench_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*opt_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  stop_vllm

  echo ""
  echo ">>> [B] release-main (native wait_for_token + get_hbm_info)"
  t0=$SECONDS
  run_vllm "$MAIN_REL" "global_registry_perf_main_${TAG}" "vnpu_perf_main_${TAG}" "limiter-main-${TAG}.log"
  main_up=$((SECONDS - t0))
  run_aisbench main "main_${TAG}" | tee "${UB}/logs/aisbench_main_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*main_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  stop_vllm

  echo ""
  echo "=== startup wall (health) ==="
  echo "optimized health: ${opt_up}s"
  echo "main health:      ${main_up}s"
  echo ""
  echo "=== aisbench (demo_gsm8k perf) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "optimized" "release-main"
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
