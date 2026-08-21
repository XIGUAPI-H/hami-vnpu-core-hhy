#!/usr/bin/env bash
# Kylin V11 A/B: kylin-lite (wait_for_token + infra) vs origin baseline.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18123}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/perf_kylin_lite_${TAG}.txt"
LITE_REL="${LITE_REL:-kylin/release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-kylin/release-origin}"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"

[[ -x "$RUN_VLLM" ]] || RUN_VLLM="$(dirname "$0")/run_kylin_native_vllm_ms_68.sh"

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

mkdir -p "${KY}/logs"
stop_all

{
  echo "=== Kylin lite A/B ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT NPU_KYLIN_LITE=1 (wait_for_token + file-shmem + meminfo-cache)"
  echo "lite=${LITE_REL} origin=${ORIGIN_REL}"
  echo ""

  echo ">>> [A] kylin-lite"
  SO_REL="$LITE_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-kylin-lite-${TAG}" \
    NPU_KYLIN_LITE=1 NPU_KYLIN_PRESET=1 bash "$RUN_VLLM" | tee "${KY}/logs/kylin_lite_vllm_${TAG}.log"
  run_aisbench "kylin_lite_${TAG}" | tee "${KY}/logs/aisbench_kylin_lite_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*kylin_lite_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo ">>> [B] origin"
  SO_REL="$ORIGIN_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-kylin-origin-${TAG}" \
    NPU_KYLIN_LITE=0 NPU_KYLIN_PRESET=0 bash "$RUN_VLLM" | tee "${KY}/logs/kylin_lite_origin_vllm_${TAG}.log"
  run_aisbench "kylin_lite_origin_${TAG}" | tee "${KY}/logs/aisbench_kylin_lite_origin_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*kylin_lite_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo "=== comparison ==="
  printf "%-28s %-22s %-22s\n" "Metric" "kylin-lite" "origin"
  for m in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    printf "%-28s %-22s %-22s\n" "$m" "$a" "$b"
  done
  thr_a=$(extract_metric "$CSV_A" "OutputTokenThroughput" | awk '{print $1}')
  thr_b=$(extract_metric "$CSV_B" "OutputTokenThroughput" | awk '{print $1}')
  if [[ -n "$thr_a" && -n "$thr_b" && "$thr_b" != "0" ]]; then
    python3 - <<PY
a=float("${thr_a}"); b=float("${thr_b}")
print(f"speedup_vs_origin: {a/b:.2f}x")
PY
  fi
  echo "CSV lite: $CSV_A"
  echo "CSV origin: $CSV_B"
} | tee "$REPORT"
echo "report: $REPORT"
