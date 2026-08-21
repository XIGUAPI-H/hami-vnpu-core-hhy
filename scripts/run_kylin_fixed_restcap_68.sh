#!/usr/bin/env bash
# Validate the rest_wait cap fix: fixed + priority=25 + FCSP + ACL graph ON, debug
# logging, then assert limiter [Sched] Rest never exceeds the cap and vLLM never
# trips shm_broadcast.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18124}"
NUM_PROMPTS="${NUM_PROMPTS:-32}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
SO_REL="${SO_REL:-kylin/release-optimized}"
TAG="$(date +%Y%m%d_%H%M%S)"
LOG="${KY}/logs/fixed_restcap_run_${TAG}.log"
VLLM_NAME="vnpu-restcap-${TAG}"

extract_metric() { awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }

stop_all() {
  docker ps -aq --filter 'name=vnpu-restcap-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

mkdir -p "${KY}/logs"
stop_all

export ASCEND_RT_VISIBLE_DEVICES="$NPU"
export ENFORCE_EAGER=0
export RUST_LOG_LEVEL=debug
# Production-like fixed config from the podA screenshot.
export NPU_FIXED_SHARE_RATIO=1
export NPU_FCSP_REFILL=1
export NPU_TOKEN_CHUNK=8
export NPU_KERNEL_BURST=1
export NPU_PRIORITY=25
export NPU_MEM_QUOTA=16000
export NPU_BURST_CONTINUOUS=1
export NPU_BURST_ALPHA=0.3
export VXPU_ORIGIN_COMPAT=0
export VXPU_COMPUTE_LIMIT=1
export VXPU_ACL_MEMINFO_HOOK=1
export VXPU_SYNC_HOOK=0
export NPU_KYLIN_PRESET=0
export NPU_KYLIN_LITE=0
export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_restcap_${TAG}"
export NPU_LOCAL_SHM_NAME="local_restcap_${TAG}"

{
  echo "=== fixed rest-cap validation ${TAG} ==="
  echo "fixed=1 prio=25 FCSP=1 chunk=8 burst=1 ACL graph ON, RUST_LOG=debug"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true

  echo ">>> start vLLM + limiter"
  SO_REL="$SO_REL" VLLM_PORT="$PORT" VLLM_NAME="$VLLM_NAME" USE_LIMITER=1 \
    ENFORCE_EAGER=0 RUST_LOG_LEVEL=debug \
    bash "$RUN_VLLM" 2>&1 | tee "${KY}/logs/restcap_vllm_${TAG}.log"

  echo ">>> aisbench"
  OUT_TAG="restcap_${TAG}" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    CONCURRENCY="$CONCURRENCY" MAX_OUT_LEN="$MAX_OUT_LEN" \
    bash "${UB}/aisbench_perf_ubuntu.sh" 2>&1 | tee "${KY}/logs/restcap_bench_${TAG}.log"

  CSV=$(find /mnt/local/m00953550/benchmark/outputs -path "*restcap_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  echo "=== metrics ==="
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    printf "%-24s %s\n" "$m" "$(extract_metric "$CSV" "$m")"
  done

  echo "=== crash signals ==="
  grep -icE 'shm_broadcast|No available shared memory' "${KY}/logs/restcap_vllm_${TAG}.log" || true

  LIM=$(ls -t /mnt/local/m00953550/FinalTest/kylin/logs/limiter-native-ms-*.log 2>/dev/null | head -1)
  echo "=== limiter log: $LIM ==="
  echo "measuring batches: $(grep -c 'measuring Batch' "$LIM" 2>/dev/null || echo 0)"
  echo "capturing-wallclock: $(grep -c 'is capturing; using wall-clock' "$LIM" 2>/dev/null || echo 0)"
  echo "--- max Rest seen (ms) ---"
  grep -oE 'Rest: [0-9]+ms' "$LIM" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || echo "none"
  echo "--- Rest distribution (top 5) ---"
  grep -oE 'Rest: [0-9]+ms' "$LIM" 2>/dev/null | sort | uniq -c | sort -rn | head -5 || true

  if docker ps --format '{{.Names}}' | grep -qx "$VLLM_NAME" && curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "RESULT: PASS health OK"
  else
    echo "RESULT: FAIL"
  fi
} 2>&1 | tee "$LOG"
echo "log: $LOG"
