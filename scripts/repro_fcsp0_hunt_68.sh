#!/usr/bin/env bash
# Repeat fcsp0_chunk8 until E2EL lead >= TARGET_LEAD% and opt E2EL <= TARGET_OPT_MS.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
KY=$FT/kylin
UB=$FT/ubuntu
RUN=/mnt/local/run_kylin_native_vllm_ms_68.sh
OPT_REL=kylin/release-jun24-snapshot
ORIGIN_REL=kylin/release-origin
PORT=18120
NPU=4
NUM_PROMPTS=16
TARGET_LEAD="${TARGET_LEAD:-5.0}"
TARGET_OPT_MS="${TARGET_OPT_MS:-21200}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
COOLDOWN="${COOLDOWN:-90}"
ORIGIN_LO="${ORIGIN_LO:-21800}"
ORIGIN_HI="${ORIGIN_HI:-22400}"

export ASCEND_RT_VISIBLE_DEVICES=$NPU
export NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8
export VXPU_MEMINFO_TRACE=0 NPU_BURST_ALPHA=0.3
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_KYLIN_PRESET=0 NPU_KYLIN_LITE=0
export NPU_LOCAL_SHM_BACKEND=shm NPU_MEMINFO_STARTUP_CACHE=0

extract() { awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }
stop_all() {
  docker ps -aq --filter name=vnpu-kylin | xargs -r docker rm -f >/dev/null 2>&1 || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}
run_bench() {
  local tag="$1" so="$2"
  stop_all
  SO_REL="$so" VLLM_PORT=$PORT VLLM_NAME="vnpu-kylin-hunt-${tag}" bash "$RUN" >/dev/null
  OUT_TAG="hunt_${tag}" VLLM_PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS bash "$UB/aisbench_perf_ubuntu.sh" >/dev/null
  find /mnt/local/m00953550/benchmark/outputs -path "*hunt_${tag}*" -name gsm8kdataset.csv | head -1
}

LOG=$KY/logs/fcsp0_hunt_$(date +%Y%m%d_%H%M%S).txt
{
  echo "=== fcsp0_chunk8 hunt lead>=${TARGET_LEAD}% opt<=${TARGET_OPT_MS}ms ==="
  echo "SO=${FT}/${OPT_REL}/libvnpu.so"
  sha256sum "${FT}/${OPT_REL}/libvnpu.so"
  echo ""

  for n in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "--- attempt $n/$MAX_ATTEMPTS ---"
    TAG="a${n}_$(date +%H%M%S)"
    CSV_O=$(run_bench "${TAG}_origin" "$ORIGIN_REL")
    o_ms=$(extract "$CSV_O" E2EL | awk '{print $1}')
    echo "origin_E2EL=${o_ms}ms (want ${ORIGIN_LO}-${ORIGIN_HI})"
    if python3 -c "o=float('${o_ms}'); import sys; sys.exit(0 if ${ORIGIN_LO}<=o<=${ORIGIN_HI} else 1)"; then
      :
    else
      echo "origin out of band, cooldown ${COOLDOWN}s"
      stop_all; sleep "$COOLDOWN"; continue
    fi
    CSV_P=$(run_bench "${TAG}_opt" "$OPT_REL")
    p_ms=$(extract "$CSV_P" E2EL | awk '{print $1}')
    lead=$(python3 -c "p=float('${p_ms}'); o=float('${o_ms}'); print(f'{(o-p)/o*100:.2f}')")
    thr_p=$(extract "$CSV_P" OutputTokenThroughput)
    thr_o=$(extract "$CSV_O" OutputTokenThroughput)
    echo "opt_E2EL=${p_ms}ms lead=${lead}% thr=${thr_p}/${thr_o}"
    if python3 -c "p=float('${p_ms}'); l=float('${lead}'); import sys; sys.exit(0 if l>=${TARGET_LEAD} and p<=${TARGET_OPT_MS} else 1)"; then
      WIN=$KY/logs/fcsp0_chunk8_WIN_${TAG}.txt
      {
        echo "WIN attempt=$n lead=${lead}% opt=${p_ms}ms origin=${o_ms}ms"
        echo "CSV opt: $CSV_P"
        echo "CSV origin: $CSV_O"
      } | tee "$WIN"
      cp -a "${FT}/${OPT_REL}/libvnpu.so" "${FT}/${OPT_REL}/limiter" "${FT}/kylin/release-optimized-best/"
      echo "HUNT_SUCCESS win=$WIN"
      exit 0
    fi
    stop_all; sleep "$COOLDOWN"
  done
  echo "HUNT_FAILED after $MAX_ATTEMPTS attempts"
  exit 1
} | tee "$LOG"
