#!/usr/bin/env bash
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18125}"
TAG="${TAG:-$(date +%Y%m%d_%H%M%S)}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
LOG="${KY}/logs/singlepod_fixed_ab_manual_${TAG}.log"

extract() { awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }

stop_all() {
  docker ps -aq --filter 'name=vnpu-spfixed-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

run_one() {
  local label=$1 so_rel=$2 burst=$3
  local name=vnpu-spfixed-${label}-${TAG}
  local out_tag=spfixed_${label}_${TAG}
  stop_all
  export ASCEND_RT_VISIBLE_DEVICES=$NPU
  export VXPU_ORIGIN_COMPAT=0 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=0
  export NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50
  export NPU_TOKEN_CHUNK=8 NPU_KERNEL_BURST=$burst NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
  export NPU_KYLIN_PRESET=0 NPU_KYLIN_LITE=0 NPU_MEM_QUOTA=16000
  export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_spfixed_${label}_${TAG}
  export NPU_LOCAL_SHM_NAME=local_spfixed_${label}_${TAG}
  echo "=== RUN $label SO=$so_rel burst=$burst ==="
  sha256sum "${FT}/${so_rel}/libvnpu.so" "${FT}/${so_rel}/limiter" 2>/dev/null || true
  SO_REL=$so_rel VLLM_PORT=$PORT VLLM_NAME=$name USE_LIMITER=1 bash "$RUN_VLLM" >"${KY}/logs/spfixed_vllm_${label}_${TAG}.log" 2>&1
  for _ in 1 2; do
    curl -sf "http://127.0.0.1:${PORT}/v1/chat/completions" -H 'Content-Type: application/json' \
      -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":256}' >/dev/null || true
  done
  set +e
  OUT_TAG=$out_tag VLLM_PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS CONCURRENCY=$CONCURRENCY MAX_OUT_LEN=$MAX_OUT_LEN \
    bash "$UB/aisbench_perf_ubuntu.sh" >"${KY}/logs/spfixed_bench_${label}_${TAG}.log" 2>&1
  local rc=$?
  set -e
  echo "aisbench_rc=$rc"
  local csv
  csv=$(find /mnt/local/m00953550/benchmark/outputs -path "*${out_tag}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  echo "CSV=$csv"
  RESULT_E2EL[$label]=$(extract "$csv" E2EL)
  RESULT_TTFT[$label]=$(extract "$csv" TTFT)
  RESULT_TPOT[$label]=$(extract "$csv" TPOT)
  RESULT_THR[$label]=$(extract "$csv" OutputTokenThroughput)
  echo "$label E2EL=${RESULT_E2EL[$label]:-na}"
  echo "$label TTFT=${RESULT_TTFT[$label]:-na}"
  echo "$label TPOT=${RESULT_TPOT[$label]:-na}"
  echo "$label OutputTokenThroughput=${RESULT_THR[$label]:-na}"
  stop_all
}

declare -A RESULT_E2EL RESULT_TTFT RESULT_TPOT RESULT_THR

mkdir -p "${KY}/logs"
{
  echo "=== single Pod fixed manual A/B ${TAG} ==="
  echo "fixed=1 prio=25 FCSP=1 chunk=8"
  run_one origin kylin/release-origin 0
  run_one optimized kylin/release-optimized 1
  echo ""
  echo "=== comparison ==="
  printf "%-24s %-22s %-22s\n" Metric origin optimized
  printf "%-24s %-22s %-22s\n" E2EL "${RESULT_E2EL[origin]:-na}" "${RESULT_E2EL[optimized]:-na}"
  printf "%-24s %-22s %-22s\n" TTFT "${RESULT_TTFT[origin]:-na}" "${RESULT_TTFT[optimized]:-na}"
  printf "%-24s %-22s %-22s\n" TPOT "${RESULT_TPOT[origin]:-na}" "${RESULT_TPOT[optimized]:-na}"
  printf "%-24s %-22s %-22s\n" OutputTokenThroughput "${RESULT_THR[origin]:-na}" "${RESULT_THR[optimized]:-na}"
  o=$(echo "${RESULT_THR[origin]:-}" | awk '{print $1}')
  p=$(echo "${RESULT_THR[optimized]:-}" | awk '{print $1}')
  if [[ -n "$o" && -n "$p" && "$o" != "0" ]]; then
    python3 -c "o=float('$o'); p=float('$p'); print(f'throughput_delta: {((p-o)/o*100):+.1f}%')"
  fi
} 2>&1 | tee "$LOG"
echo "log: $LOG"
