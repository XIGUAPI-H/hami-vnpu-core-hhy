#!/usr/bin/env bash
# Kylin native A/B sweep: FCSP off, order swap, chunk tuning, meminfo trace.
# Usage on 68:
#   bash compare_perf_kylin_native_sweep_68.sh
#   SCENARIOS="fcsp0_swap" bash compare_perf_kylin_native_sweep_68.sh
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18120}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
OPT_REL="${OPT_REL:-kylin/release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-kylin/release-origin}"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/kylin_native_sweep_${TAG}.csv"
SUMMARY="${KY}/logs/kylin_native_sweep_${TAG}.txt"

[[ -x "$RUN_VLLM" ]] || { echo "missing $RUN_VLLM"; exit 1; }

# scenario|order|fcsp|burst_cont|chunk|meminfo_trace
# order: opt_first | origin_first
DEFAULT_SCENARIOS=(
  "fcsp0_opt_first|opt_first|0|1|32|0"
  "fcsp0_origin_first|origin_first|0|1|32|0"
  "fcsp0_burst_off|opt_first|0|0|32|0"
  "fcsp0_chunk8|opt_first|0|1|8|0"
  "fcsp0_meminfo_trace|opt_first|0|1|32|1"
  "fcsp1_baseline|opt_first|1|1|32|0"
)

if [[ -n "${SCENARIOS:-}" ]]; then
  SCENARIO_LIST=()
  for item in $SCENARIOS; do
    if [[ "$item" == *"|"* ]]; then
      SCENARIO_LIST+=("$item")
    else
      found=0
      for def in "${DEFAULT_SCENARIOS[@]}"; do
        if [[ "$def" == "${item}|"* ]]; then
          SCENARIO_LIST+=("$def")
          found=1
          break
        fi
      done
      [[ "$found" == 1 ]] || { echo "unknown scenario alias: $item" >&2; exit 1; }
    fi
  done
else
  SCENARIO_LIST=("${DEFAULT_SCENARIOS[@]}")
fi

stop_all() {
  docker ps -aq --filter 'name=vnpu-kylin-native-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  sleep 3
}

wait_port_free() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: port ${PORT} still serving after stop_all" >&2
  return 1
}

run_aisbench() {
  local out_tag="$1"
  OUT_TAG="$out_tag" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh"
}

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

run_side() {
  local side="$1" so_rel="$2" scen="$3"
  export NPU_FCSP_REFILL="$4" NPU_BURST_CONTINUOUS="$5" NPU_TOKEN_CHUNK="$6"
  export VXPU_MEMINFO_TRACE="$7"
  local name="vnpu-kylin-native-${side}-${scen}"
  local vllm_log="${KY}/logs/kylin_${scen}_${side}_vllm_${TAG}.log"
  local bench_log="${KY}/logs/aisbench_kylin_${scen}_${side}_${TAG}.log"
  stop_all
  wait_port_free
  SO_REL="$so_rel" VLLM_PORT="$PORT" VLLM_NAME="$name" USE_LIMITER=1 \
    bash "$RUN_VLLM" >>"$vllm_log" 2>&1
  run_aisbench "kylin_${scen}_${side}_${TAG}" >>"$bench_log" 2>&1
  local csv
  csv=$(find /mnt/local/m00953550/benchmark/outputs -path "*kylin_${scen}_${side}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  [[ -n "$csv" && -f "$csv" ]] || { echo "missing csv for ${scen}/${side}" >&2; return 1; }
}

mkdir -p "${KY}/logs"
echo "scenario,order,fcsp,burst_cont,chunk,meminfo_trace,side,E2EL,TTFT,TPOT,OutputTokenThroughput,winner_vs_other" > "$REPORT"
{
  echo "=== Kylin native sweep ${TAG} ==="
  echo "report_csv=$REPORT"
  echo ""
} | tee "$SUMMARY"

for spec in "${SCENARIO_LIST[@]}"; do
  IFS='|' read -r scen order fcsp burst_cont chunk trace <<< "$spec"
  stop_all

  {
    echo ">>> scenario=$scen order=$order fcsp=$fcsp burst_cont=$burst_cont chunk=$chunk trace=$trace"
  } | tee -a "$SUMMARY"

  if [[ "$order" == "origin_first" ]]; then
    sides=(origin "$ORIGIN_REL" opt "$OPT_REL")
  else
    sides=(opt "$OPT_REL" origin "$ORIGIN_REL")
  fi

  declare -A CSV_PATH
  declare -A TRACE_COUNT
  for ((i=0; i<${#sides[@]}; i+=2)); do
    side="${sides[i]}"
    so_rel="${sides[i+1]}"
    cname="vnpu-kylin-native-${side}-${scen}"
    run_side "$side" "$so_rel" "$scen" "$fcsp" "$burst_cont" "$chunk" "$trace"
    CSV_PATH[$side]=$(find /mnt/local/m00953550/benchmark/outputs -path "*kylin_${scen}_${side}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
    [[ -n "${CSV_PATH[$side]}" && -f "${CSV_PATH[$side]}" ]] || { echo "missing csv for ${scen}/${side}" >&2; exit 1; }
    TRACE_COUNT[$side]=$(docker logs "$cname" 2>&1 | grep -c '\[meminfo#' || true)
    docker rm -f "$cname" 2>/dev/null || true
    stop_all
  done

  e2el_opt=$(extract_metric "${CSV_PATH[opt]}" E2EL)
  e2el_origin=$(extract_metric "${CSV_PATH[origin]}" E2EL)
  ttft_opt=$(extract_metric "${CSV_PATH[opt]}" TTFT)
  ttft_origin=$(extract_metric "${CSV_PATH[origin]}" TTFT)
  tpot_opt=$(extract_metric "${CSV_PATH[opt]}" TPOT)
  tpot_origin=$(extract_metric "${CSV_PATH[origin]}" TPOT)
  tok_opt=$(extract_metric "${CSV_PATH[opt]}" OutputTokenThroughput)
  tok_origin=$(extract_metric "${CSV_PATH[origin]}" OutputTokenThroughput)

  winner="tie"
  opt_n=$(echo "$tok_opt" | awk '{print $1}')
  origin_n=$(echo "$tok_origin" | awk '{print $1}')
  if awk -v a="$opt_n" -v b="$origin_n" 'BEGIN{exit !(a>b)}'; then
    winner="optimized"
  elif awk -v a="$opt_n" -v b="$origin_n" 'BEGIN{exit !(a<b)}'; then
    winner="origin"
  fi

  trace_opt=${TRACE_COUNT[opt]:-0}
  trace_origin=${TRACE_COUNT[origin]:-0}

  for side in opt origin; do
    csv="${CSV_PATH[$side]}"
    echo "$scen,$order,$fcsp,$burst_cont,$chunk,$trace,$side,$(extract_metric "$csv" E2EL),$(extract_metric "$csv" TTFT),$(extract_metric "$csv" TPOT),$(extract_metric "$csv" OutputTokenThroughput),$winner" >> "$REPORT"
  done

  {
    echo "  E2EL: opt=$e2el_opt origin=$e2el_origin"
    echo "  TTFT: opt=$ttft_opt origin=$ttft_origin"
    echo "  TPOT: opt=$tpot_opt origin=$tpot_origin"
    echo "  Throughput: opt=$tok_opt origin=$tok_origin => winner=$winner"
    echo "  meminfo# lines in vllm log: opt=$trace_opt origin=$trace_origin"
    echo ""
  } | tee -a "$SUMMARY"
done

{
  echo "=== winners by scenario (throughput) ==="
  awk -F, 'NR>1 && $7=="opt" {print $1, $12}' "$REPORT" | sort -u
  echo ""
  echo "csv: $REPORT"
} | tee -a "$SUMMARY"

echo "done: $SUMMARY"
