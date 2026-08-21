#!/usr/bin/env bash
# A/B perf: Kylin OS runtime + Kylin-built SO (origin vs optimized).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18120}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
MODEL_HOST="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
NPU_MEM_QUOTA="${NPU_MEM_QUOTA:-16000}"
NPU_PRIORITY="${NPU_PRIORITY:-25}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/perf_kylin_native_${TAG}.txt"
OPT_REL="${OPT_REL:-kylin/release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-kylin/release-origin}"
RUN_VLLM="/mnt/local/run_kylin_native_vllm_ms_68.sh"

[[ -x "$RUN_VLLM" ]] || { echo "missing $RUN_VLLM"; exit 1; }

stop_all() {
  docker rm -f vnpu-kylin-native-opt vnpu-kylin-native-origin 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
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
  echo "=== Kylin NATIVE runtime perf ${TAG} ==="
  docker run --rm kylin-server:v11-2503-arm64 cat /etc/os-release | head -3
  echo "NPU=$NPU PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS model=$MODEL_HOST"
  echo "vLLM=Kylin container + mindspeed(openEuler) py3.10 + vllm-workspace"
  echo ""

  echo ">>> [A] optimized+paper (${OPT_REL})"
  stop_all
  SO_REL="$OPT_REL" VLLM_PORT="$PORT" VLLM_NAME=vnpu-kylin-native-opt USE_LIMITER=1 \
    bash "$RUN_VLLM" | tee "${KY}/logs/kylin_native_vllm_opt_${TAG}.log"
  run_aisbench "kylin_native_opt_${TAG}" | tee "${KY}/logs/aisbench_kylin_native_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*kylin_native_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo ">>> [B] origin (${ORIGIN_REL})"
  SO_REL="$ORIGIN_REL" VLLM_PORT="$PORT" VLLM_NAME=vnpu-kylin-native-origin USE_LIMITER=1 \
    bash "$RUN_VLLM" | tee "${KY}/logs/kylin_native_vllm_origin_${TAG}.log"
  run_aisbench "kylin_native_origin_${TAG}" | tee "${KY}/logs/aisbench_kylin_native_origin_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*kylin_native_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo "=== comparison ==="
  printf "%-28s %-22s %-22s\n" "Metric" "optimized+paper" "origin"
  for m in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
    printf "%-28s %-22s %-22s\n" "$m" "$(extract_metric "$CSV_A" "$m")" "$(extract_metric "$CSV_B" "$m")"
  done
  echo "CSV opt: $CSV_A"
  echo "CSV origin: $CSV_B"
} | tee "$REPORT"
echo "report: $REPORT"
