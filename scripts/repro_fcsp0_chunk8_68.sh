#!/usr/bin/env bash
# Reproduce Jun-24 Kylin best: fcsp0_chunk8 (E2EL-focused A/B).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
BUILD_SCRIPT="${BUILD_SCRIPT:-/mnt/local/m00953550/hami-vnpu-core/scripts/build_kylin_jun24_snapshot_68.sh}"
PORT="${VLLM_PORT:-18120}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
OPT_REL="${OPT_REL:-kylin/release-jun24-snapshot}"
ORIGIN_REL="${ORIGIN_REL:-kylin/release-origin}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/fcsp0_chunk8_repro_${TAG}.txt"

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

stop_all() {
  docker ps -aq --filter 'name=vnpu-kylin' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

# Jun-24 sweep fcsp0_chunk8 env (same as compare_perf_kylin_native_sweep_68.sh).
export ASCEND_RT_VISIBLE_DEVICES="$NPU"
export NPU_FCSP_REFILL=0
export NPU_BURST_CONTINUOUS=1
export NPU_TOKEN_CHUNK=8
export VXPU_MEMINFO_TRACE=0
export NPU_BURST_ALPHA=0.3
export VXPU_MEMINFO_USE_DCMI=0
export VXPU_ENABLE_MALLOC_QUOTA=0
# Jun-24 tree has no kylin_preset; disable if run script defaults preset/lite on.
export NPU_KYLIN_PRESET=0
export NPU_KYLIN_LITE=0
export NPU_LOCAL_SHM_BACKEND=shm
export NPU_MEMINFO_STARTUP_CACHE=0

mkdir -p "${KY}/logs"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "=== [0] build jun24-snapshot SO ==="
  bash "$BUILD_SCRIPT"
fi

{
  echo "=== fcsp0_chunk8 repro ${TAG} (Kylin best scenario) ==="
  echo "runtime_image=kylin-server:v11-2503-arm64"
  echo "python_stack=mindspeed-openeuler-py3.10 enforce-eager"
  echo "model=/mnt/local/m00953550/Qwen3-1.7B NPU=${NPU} NPU_PRIORITY=25"
  echo ""
  echo "=== limiter env (Jun-24 winner) ==="
  echo "NPU_FCSP_REFILL=0"
  echo "NPU_BURST_CONTINUOUS=1"
  echo "NPU_TOKEN_CHUNK=8"
  echo "NPU_BURST_ALPHA=0.3"
  echo "VXPU_MEMINFO_USE_DCMI=0"
  echo "VXPU_ENABLE_MALLOC_QUOTA=0"
  echo "VXPU_MEMINFO_TRACE=0"
  echo ""
  echo "=== hijack paths ==="
  echo "opt=${FT}/${OPT_REL}/libvnpu.so"
  echo "opt_limiter=${FT}/${OPT_REL}/limiter"
  echo "origin=${FT}/${ORIGIN_REL}/libvnpu.so"
  sha256sum "${FT}/${OPT_REL}/libvnpu.so" "${FT}/${OPT_REL}/limiter" "${FT}/${ORIGIN_REL}/libvnpu.so" 2>/dev/null || true
  echo ""

  echo ">>> [A] optimized (paper-best, opt_first)"
  stop_all
  SO_REL="$OPT_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-kylin-fcsp0-opt-${TAG}" \
    bash "$RUN_VLLM" | tee "${KY}/logs/fcsp0_opt_vllm_${TAG}.log"
  OUT_TAG="fcsp0_chunk8_opt_${TAG}" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh" | tee "${KY}/logs/fcsp0_opt_bench_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*fcsp0_chunk8_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo ">>> [B] origin"
  SO_REL="$ORIGIN_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-kylin-fcsp0-origin-${TAG}" \
    bash "$RUN_VLLM" | tee "${KY}/logs/fcsp0_origin_vllm_${TAG}.log"
  OUT_TAG="fcsp0_chunk8_origin_${TAG}" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${UB}/aisbench_perf_ubuntu.sh" | tee "${KY}/logs/fcsp0_origin_bench_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*fcsp0_chunk8_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo "=== results (historical target: E2EL opt=20888ms origin=22078ms) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "paper-best" "origin"
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    printf "%-28s %-22s %-22s\n" "$m" "$a" "$b"
  done
  e2el_a=$(extract_metric "$CSV_A" "E2EL" | awk '{print $1}')
  e2el_b=$(extract_metric "$CSV_B" "E2EL" | awk '{print $1}')
  if [[ -n "$e2el_a" && -n "$e2el_b" && "$e2el_b" != "0" ]]; then
    python3 - <<PY
ea=float("${e2el_a}"); eb=float("${e2el_b}")
print(f"e2el_lead_vs_origin: {(eb-ea)/eb*100:.2f}% faster (positive=opt wins)")
PY
  fi
  echo "CSV opt: $CSV_A"
  echo "CSV origin: $CSV_B"
  echo "report: $REPORT"
} | tee "$REPORT"
