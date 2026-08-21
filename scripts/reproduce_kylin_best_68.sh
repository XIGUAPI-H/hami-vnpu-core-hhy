#!/usr/bin/env bash
# Reproduce 2026-06-24 Kylin best A/B: fcsp0_chunk8 (paper hook + burst limiter).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18120}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
OPT_REL="${OPT_REL:-kylin/release-optimized-best}"
ORIGIN_REL="${ORIGIN_REL:-kylin/release-origin}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/reproduce_kylin_best_${TAG}.txt"
ROOT="${ROOT:-/mnt/local/m00953550/hami-vnpu-core}"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"

[[ -x "$RUN_VLLM" ]] || RUN_VLLM="$ROOT/scripts/run_kylin_native_vllm_ms_68.sh"

# Jun-24 best env (sweep overrides; no kylin preset/lite/industry stack).
BEST_ENV='export NPU_KYLIN_PRESET=0 NPU_KYLIN_LITE=0 NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8 NPU_BURST_ALPHA=0.3 VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0'

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

run_aisbench() {
  OUT_TAG="$1" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh"
}

stop_all() {
  docker ps -aq --filter 'name=vnpu-kylin-native-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 3
}

echo "=== [1/3] build paper-best SO in Kylin container ==="
bash "$ROOT/scripts/build_kylin_paper_best_68.sh" 2>&1 | tee "${KY}/logs/build_kylin_paper_best_${TAG}.log"

mkdir -p "${KY}/logs"
stop_all

{
  echo "=== Reproduce Kylin best fcsp0_chunk8 ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT repro_env: $BEST_ENV"
  echo "opt=${OPT_REL} origin=${ORIGIN_REL}"
  sha256sum "${FT}/${OPT_REL}/libvnpu.so" "${FT}/${ORIGIN_REL}/libvnpu.so" 2>/dev/null || true
  echo ""

  echo ">>> [A] paper-best optimized"
  eval "$BEST_ENV"
  SO_REL="$OPT_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-kylin-best-opt-${TAG}" \
    bash "$RUN_VLLM" | tee "${KY}/logs/repro_best_opt_vllm_${TAG}.log"
  run_aisbench "repro_kylin_best_opt_${TAG}" | tee "${KY}/logs/aisbench_repro_best_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*repro_kylin_best_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo ">>> [B] origin"
  eval "$BEST_ENV"
  SO_REL="$ORIGIN_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-kylin-best-origin-${TAG}" \
    bash "$RUN_VLLM" | tee "${KY}/logs/repro_best_origin_vllm_${TAG}.log"
  run_aisbench "repro_kylin_best_origin_${TAG}" | tee "${KY}/logs/aisbench_repro_best_origin_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*repro_kylin_best_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo "=== comparison (target: E2EL ~20888ms opt / ~22078ms origin, thr ~23.94/22.65) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "paper-best" "origin"
  for m in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    printf "%-28s %-22s %-22s\n" "$m" "$a" "$b"
  done
  e2el_a=$(extract_metric "$CSV_A" "E2EL" | awk '{print $1}')
  e2el_b=$(extract_metric "$CSV_B" "E2EL" | awk '{print $1}')
  thr_a=$(extract_metric "$CSV_A" "OutputTokenThroughput" | awk '{print $1}')
  thr_b=$(extract_metric "$CSV_B" "OutputTokenThroughput" | awk '{print $1}')
  if [[ -n "$e2el_a" && -n "$e2el_b" && "$e2el_b" != "0" ]]; then
    python3 - <<PY
ea=float("${e2el_a}"); eb=float("${e2el_b}")
print(f"e2el_lead_vs_origin: {(eb-ea)/eb*100:.2f}% faster (positive=opt wins)")
PY
  fi
  if [[ -n "$thr_a" && -n "$thr_b" && "$thr_b" != "0" ]]; then
    python3 - <<PY
a=float("${thr_a}"); b=float("${thr_b}")
print(f"throughput_speedup_vs_origin: {a/b:.4f}x")
PY
  fi
  echo "CSV opt: $CSV_A"
  echo "CSV origin: $CSV_B"
  echo "SO best: ${FT}/${OPT_REL}/libvnpu.so"
  echo "manifest: ${FT}/kylin/release-optimized-best/MANIFEST.latest"
} | tee "$REPORT"
echo "report: $REPORT"
