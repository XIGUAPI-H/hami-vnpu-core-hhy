#!/usr/bin/env bash
# Reproduce podA-style limiter env from production screenshot, then aisbench stress.
# Goal: verify whether fixed+FCSP=1 + priority=25 crashes on Kylin.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18120}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
SO_REL="${SO_REL:-kylin/release-optimized}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/poda_params_${TAG}.txt"
LOG="${KY}/logs/poda_params_run_${TAG}.log"

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

stop_all() {
  docker ps -aq --filter 'name=vnpu-poda-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

mkdir -p "${KY}/logs"
stop_all

# --- podA screenshot params (limiter block) ---
export ASCEND_RT_VISIBLE_DEVICES="$NPU"
export NPU_FIXED_SHARE_RATIO=1
export NPU_FCSP_REFILL=1
export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_poda_${TAG}"
export NPU_MEM_QUOTA=16000
export NPU_PRIORITY=25
export NPU_BURST_CONTINUOUS=1
export NPU_BURST_ALPHA=0.3
export NPU_TOKEN_CHUNK=32
export NPU_KERNEL_BURST=1
export VXPU_MEMINFO_USE_DCMI=0
export VXPU_ENABLE_MALLOC_QUOTA=0
export VXPU_MEMINFO_TRACE=0
# Screenshot did not set these; keep off so we test prod-like fixed+FCSP only.
export NPU_KYLIN_PRESET=0
export NPU_KYLIN_LITE=0

{
  echo "=== podA-params Kylin stress ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT SO=$SO_REL"
  echo "NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_PRIORITY=25 NPU_MEM_QUOTA=16000"
  echo "NPU_GLOBAL_SHM_PATH=$NPU_GLOBAL_SHM_PATH"
  echo "aisbench: prompts=$NUM_PROMPTS concurrency=$CONCURRENCY max_out=$MAX_OUT_LEN"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo ""

  echo ">>> [1] start vLLM + limiter"
  SO_REL="$SO_REL" VLLM_PORT="$PORT" VLLM_NAME="vnpu-poda-${TAG}" USE_LIMITER=1 \
    bash "$RUN_VLLM" 2>&1 | tee "${KY}/logs/poda_vllm_${TAG}.log"

  echo ""
  echo ">>> [2] aisbench (single client, same pod)"
  OUT_TAG="poda_params_${TAG}" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    CONCURRENCY="$CONCURRENCY" MAX_OUT_LEN="$MAX_OUT_LEN" \
    bash "${UB}/aisbench_perf_ubuntu.sh" 2>&1 | tee "${KY}/logs/poda_bench_${TAG}.log"

  CSV=$(find /mnt/local/m00953550/benchmark/outputs -path "*poda_params_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  echo ""
  echo "=== metrics ==="
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    printf "%-24s %s\n" "$m" "$(extract_metric "$CSV" "$m")"
  done
  echo "CSV: $CSV"

  echo ""
  echo "=== crash signals in vllm log ==="
  grep -iE 'shm_broadcast|EngineDead|sample_tokens timed out|panic|AssertionError|WorkerProc initialization failed' \
    "${KY}/logs/poda_vllm_${TAG}.log" || echo "(none)"

  echo ""
  echo "=== limiter log tail ==="
  docker logs "vnpu-poda-${TAG}" 2>&1 | grep -iE 'limiter|Manager|error|panic' | tail -20 || true

  if docker ps --format '{{.Names}}' | grep -qx "vnpu-poda-${TAG}"; then
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "RESULT: health OK after bench"
    else
      echo "RESULT: container up but health FAILED"
    fi
  else
    echo "RESULT: container EXITED (crashed)"
    docker logs "vnpu-poda-${TAG}" 2>&1 | tail -40 || true
  fi
} 2>&1 | tee "$LOG"

cp -f "$LOG" "$REPORT"
echo "report: $REPORT"
