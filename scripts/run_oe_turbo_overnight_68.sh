#!/usr/bin/env bash
# Overnight: rebuild turbo SO, run origin baseline, sweep turbo params until >=2x throughput.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
OE="$FT/openeuler"
LOG=/mnt/local/oe_turbo_overnight.log
SRC=/mnt/local/m00953550/hami-vnpu-core
TARGET_SPEEDUP="${TARGET_SPEEDUP:-2.0}"

exec > >(tee -a "$LOG") 2>&1
echo "=== overnight turbo run $(date -Is) TARGET=${TARGET_SPEEDUP}x ==="

bash /mnt/local/build_oe_turbo_68.sh "$SRC"

# Ensure origin SO present (openEuler-tested build from kylin path if available).
mkdir -p "$OE/release-origin"
if [[ ! -f "$OE/release-origin/libvnpu.so" ]]; then
  cp -a "$FT/kylin/release-origin/"* "$OE/release-origin/" 2>/dev/null \
    || cp -a "$FT/ubuntu/release-origin/"* "$OE/release-origin/"
fi

export ASCEND_RT_VISIBLE_DEVICES="${ASCEND_RT_VISIBLE_DEVICES:-0}"
export VLLM_PORT="${VLLM_PORT:-18020}"
export NUM_PROMPTS="${NUM_PROMPTS:-16}"

BEST_SPEEDUP=0
BEST_CFG=""
SUMMARY="$OE/logs/oe_turbo_overnight_summary.txt"
echo "scenario,speedup,chunk,fcsp_us,alpha,report" > "$SUMMARY"

declare -a SCENARIOS=(
  "256|50|0.3"
  "512|50|0.3"
  "256|100|0.3"
  "512|100|0.5"
  "384|50|0.4"
)

for spec in "${SCENARIOS[@]}"; do
  IFS='|' read -r chunk fcsp alpha <<< "$spec"
  name="chunk${chunk}_fcsp${fcsp}_a${alpha}"
  echo ""
  echo ">>> turbo scenario $name"
  export TURBO_ENV="export NPU_LLM_MODE=1 NPU_TOKEN_CHUNK=${chunk} NPU_FCSP_REFILL_INTERVAL_US=${fcsp} NPU_BURST_ALPHA=${alpha}"
  if bash /mnt/local/compare_perf_oe_turbo_68.sh; then
    REPORT=$(ls -t "$OE/logs/perf_oe_turbo_"*.txt 2>/dev/null | head -1)
    SPEEDUP=$(grep speedup_vs_origin "$REPORT" 2>/dev/null | awk '{print $1}' | sed 's/speedup_vs_origin://' || echo "0")
    echo "$name,$SPEEDUP,$chunk,$fcsp,$alpha,$REPORT" >> "$SUMMARY"
    python3 - <<PY
s=float("${SPEEDUP}" or "0")
if s >= float("${TARGET_SPEEDUP}"):
    open("${OE}/logs/oe_turbo_TARGET_HIT.txt","w").write("${name} ${SPEEDUP}x ${REPORT}\n")
PY
    if python3 - <<PY
s=float("${SPEEDUP}" or "0")
import sys
sys.exit(0 if s >= float("${TARGET_SPEEDUP}") else 1)
PY
    then
      echo "TARGET HIT: ${SPEEDUP}x with $name"
      exit 0
    fi
    if python3 - <<PY
s=float("${SPEEDUP}" or "0")
b=float("${BEST_SPEEDUP}" or "0")
import sys
sys.exit(0 if s > b else 1)
PY
    then
      BEST_SPEEDUP="$SPEEDUP"
      BEST_CFG="$name"
    fi
  else
    echo "$name,FAIL,$chunk,$fcsp,$alpha," >> "$SUMMARY"
  fi
  sleep 10
done

echo ""
echo "=== overnight done $(date -Is) best=${BEST_SPEEDUP}x cfg=${BEST_CFG} ==="
cat "$SUMMARY"
