#!/usr/bin/env bash
# A/B: single Pod独占 + fixed=1 + priority=25, origin vs optimized (new lib).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18125}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/singlepod_fixed_ab_${TAG}.txt"
LOG="${KY}/logs/singlepod_fixed_ab_run_${TAG}.log"

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

stop_all() {
  docker ps -aq --filter 'name=vnpu-spfixed-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

warmup() {
  local port="$1"
  echo ">>> warmup :${port}"
  for i in 1 2; do
    curl -sf "http://127.0.0.1:${port}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":256,"temperature":0.01}' \
      >/dev/null || true
  done
}

run_side() {
  local label="$1"
  local so_rel="$2"
  local kernel_burst="$3"
  local vllm_name="vnpu-spfixed-${label}-${TAG}"
  local out_tag="spfixed_${label}_${TAG}"

  export ASCEND_RT_VISIBLE_DEVICES="$NPU"
  export VXPU_ORIGIN_COMPAT=0
  export VXPU_COMPUTE_LIMIT=1
  export VXPU_ACL_MEMINFO_HOOK=1
  export VXPU_SYNC_HOOK=0
  export NPU_PRIORITY=25
  export NPU_FIXED_SHARE_RATIO=1
  export NPU_FCSP_REFILL=1
  export NPU_FCSP_REFILL_INTERVAL_US=50
  export NPU_TOKEN_CHUNK=8
  export NPU_KERNEL_BURST="$kernel_burst"
  export NPU_BURST_CONTINUOUS=1
  export NPU_BURST_ALPHA=0.3
  export NPU_KYLIN_PRESET=0
  export NPU_KYLIN_LITE=0
  export NPU_MEM_QUOTA=16000
  export VXPU_MEMINFO_USE_DCMI=0
  export VXPU_ENABLE_MALLOC_QUOTA=0
  export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_spfixed_${label}_${TAG}"
  export NPU_LOCAL_SHM_NAME="local_spfixed_${label}_${TAG}"

  echo ""
  echo ">>> [$label] SO=$so_rel KERNEL_BURST=$kernel_burst fixed=1 prio=25 FCSP=1 chunk=8"
  sha256sum "${FT}/${so_rel}/libvnpu.so" "${FT}/${so_rel}/limiter" 2>/dev/null || true

  stop_all
  SO_REL="$so_rel" VLLM_PORT="$PORT" VLLM_NAME="$vllm_name" USE_LIMITER=1 \
    bash "$RUN_VLLM" 2>&1 | tee "${KY}/logs/spfixed_vllm_${label}_${TAG}.log"

  warmup "$PORT"

  OUT_TAG="$out_tag" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    CONCURRENCY="$CONCURRENCY" MAX_OUT_LEN="$MAX_OUT_LEN" \
    bash "${UB}/aisbench_perf_ubuntu.sh" 2>&1 | tee "${KY}/logs/spfixed_bench_${label}_${TAG}.log"

  local csv
  csv=$(find /mnt/local/m00953550/benchmark/outputs -path "*${out_tag}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  CSV_MAP[$label]="$csv"

  local crash=0
  grep -qiE 'shm_broadcast|No available shared memory|EngineDead|TimeoutError' \
    "${KY}/logs/spfixed_vllm_${label}_${TAG}.log" && crash=1 || true
  CRASH_MAP[$label]="$crash"

  local health=fail
  if docker ps --format '{{.Names}}' | grep -qx "$vllm_name"; then
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && health=ok
  fi
  HEALTH_MAP[$label]="$health"

  stop_all
}

declare -A CSV_MAP CRASH_MAP HEALTH_MAP

mkdir -p "${KY}/logs"
stop_all

{
  echo "=== single Pod fixed A/B ${TAG} ==="
  echo "scenario: 1 Pod独占, NPU_FIXED_SHARE_RATIO=1, NPU_PRIORITY=25, FCSP=1, chunk=8"
  echo "NPU=$NPU PORT=$PORT prompts=$NUM_PROMPTS concurrency=$CONCURRENCY max_out=$MAX_OUT_LEN"
  echo ""

  run_side origin kylin/release-origin 0
  run_side optimized kylin/release-optimized 1

  echo ""
  echo "=== comparison ==="
  printf "%-28s %-26s %-26s\n" "Metric" "origin" "optimized"
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    o=$(extract_metric "${CSV_MAP[origin]}" "$m")
    p=$(extract_metric "${CSV_MAP[optimized]}" "$m")
    printf "%-28s %-26s %-26s\n" "$m" "$o" "$p"
  done

  o_th=$(extract_metric "${CSV_MAP[origin]}" "OutputTokenThroughput" | awk '{print $1}')
  p_th=$(extract_metric "${CSV_MAP[optimized]}" "OutputTokenThroughput" | awk '{print $1}')
  if [[ -n "$o_th" && -n "$p_th" ]]; then
  python3 - <<PY
o=float("$o_th"); p=float("$p_th")
delta=(p-o)/o*100 if o>0 else 0
print(f"throughput_delta: optimized vs origin = {delta:+.1f}%")
PY
  fi

  echo ""
  printf "%-28s %-26s %-26s\n" "health_after_bench" "${HEALTH_MAP[origin]}" "${HEALTH_MAP[optimized]}"
  printf "%-28s %-26s %-26s\n" "crash_signals" "${CRASH_MAP[origin]}" "${CRASH_MAP[optimized]}"
  echo "CSV origin: ${CSV_MAP[origin]}"
  echo "CSV optimized: ${CSV_MAP[optimized]}"
} 2>&1 | tee "$LOG"

cp -f "$LOG" "$REPORT"
echo "report: $REPORT"
