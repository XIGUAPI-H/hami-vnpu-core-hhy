#!/usr/bin/env bash
# Reproduce the production hang on 68 with ACL graph ENABLED (no --enforce-eager),
# SYNC_HOOK=0, default params, debug limiter logging to pinpoint where a worker stalls.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18123}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
SO_REL="${SO_REL:-kylin/release-optimized}"
# LLM_MODE: pass "1" to test the light-measure (no device-sync) hypothesis.
LLM_MODE="${LLM_MODE:-}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/aclgraph_repro_${TAG}.txt"
LOG="${KY}/logs/aclgraph_repro_run_${TAG}.log"
VLLM_NAME="vnpu-aclgraph-${TAG}"

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

stop_all() {
  docker ps -aq --filter 'name=vnpu-aclgraph-' | xargs -r docker rm -f 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

mkdir -p "${KY}/logs"
stop_all

# Match the confirmed crashing config: ACL graph ON, sync hook OFF, compute ON.
export ASCEND_RT_VISIBLE_DEVICES="$NPU"
export ENFORCE_EAGER=0
export RUST_LOG_LEVEL=debug
export VXPU_ORIGIN_COMPAT=0
export VXPU_COMPUTE_LIMIT=1
export VXPU_ACL_MEMINFO_HOOK=1
export VXPU_SYNC_HOOK=0
export NPU_PRIORITY=25
export NPU_FIXED_SHARE_RATIO=0
export NPU_KYLIN_PRESET=0
export NPU_KYLIN_LITE=0
export NPU_MEM_QUOTA=16000
export VXPU_MEMINFO_USE_DCMI=0
export VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_aclgraph_${TAG}"
export NPU_LOCAL_SHM_NAME="local_aclgraph_${TAG}"
[[ -n "$LLM_MODE" ]] && export NPU_LLM_MODE="$LLM_MODE"

{
  echo "=== ACL graph repro ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT SO=$SO_REL NAME=$VLLM_NAME"
  echo "ENFORCE_EAGER=0 (ACL graph ON), RUST_LOG=debug"
  echo "VXPU_COMPUTE_LIMIT=1 VXPU_SYNC_HOOK=0 NPU_PRIORITY=25 NPU_LLM_MODE=${LLM_MODE:-<unset>}"
  echo "aisbench: prompts=$NUM_PROMPTS concurrency=$CONCURRENCY max_out=$MAX_OUT_LEN"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo ""

  echo ">>> [1] start vLLM + limiter (ACL graph ON)"
  SO_REL="$SO_REL" VLLM_PORT="$PORT" VLLM_NAME="$VLLM_NAME" USE_LIMITER=1 \
    ENFORCE_EAGER=0 RUST_LOG_LEVEL=debug \
    bash "$RUN_VLLM" 2>&1 | tee "${KY}/logs/aclgraph_vllm_${TAG}.log"

  echo ""
  echo ">>> [2] aisbench pressure"
  set +e
  OUT_TAG="aclgraph_repro_${TAG}" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    CONCURRENCY="$CONCURRENCY" MAX_OUT_LEN="$MAX_OUT_LEN" \
    bash "${UB}/aisbench_perf_ubuntu.sh" 2>&1 | tee "${KY}/logs/aclgraph_bench_${TAG}.log"
  set -e

  CSV=$(find /mnt/local/m00953550/benchmark/outputs -path "*aclgraph_repro_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  echo ""
  echo "=== metrics ==="
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    printf "%-24s %s\n" "$m" "$(extract_metric "$CSV" "$m")"
  done

  echo ""
  echo "=== crash signals in vllm log ==="
  if grep -iE 'shm_broadcast|EngineDead|EngineCore encountered a fatal error|TimeoutError|hanging' \
    "${KY}/logs/aclgraph_vllm_${TAG}.log"; then
    CRASH=1
  else
    echo "(none)"
    CRASH=0
  fi

  echo ""
  echo "=== limiter DEBUG tail (where workers are when stalled) ==="
  docker logs "$VLLM_NAME" 2>&1 | grep -iE 'limiter|Manager|measuring|capturing|device sync|Token empty|first Token|Batch' | tail -60 || true

  echo ""
  echo "=== container status ==="
  if docker ps --format '{{.Names}}' | grep -qx "$VLLM_NAME"; then
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "RESULT: PASS — health OK after bench, crash_signals=$CRASH"
    else
      echo "RESULT: FAIL — container up but health FAILED, crash_signals=$CRASH"
    fi
  else
    echo "RESULT: FAIL — container EXITED (crashed), crash_signals=$CRASH"
    docker logs "$VLLM_NAME" 2>&1 | tail -60 || true
  fi
} 2>&1 | tee "$LOG"

cp -f "$LOG" "$REPORT"
echo "report: $REPORT"
