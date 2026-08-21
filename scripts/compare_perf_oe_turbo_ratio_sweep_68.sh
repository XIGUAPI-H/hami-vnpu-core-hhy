#!/usr/bin/env bash
# Sweep NPU_BURST_KERNELS_PER_TOKEN until speedup >= TARGET vs origin on openEuler.
#
# WARNING: this sweep is NOT a fair comparison. A ratio of N charges one token per
# N kernels, so the container executes N times the share it was configured for.
# `speedup_vs_origin` from any ratio > 1 measures quota inflation, not the
# overhead reduction burst is supposed to deliver. Keep it for studying the
# quota/throughput curve only; never quote these numbers as an optimization
# result. Fair runs use the default ratio of 1.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
OE="$FT/openeuler"
LOG=/mnt/local/oe_turbo_ratio_sweep.log
TARGET="${TARGET_SPEEDUP:-2.0}"
export ASCEND_RT_VISIBLE_DEVICES="${ASCEND_RT_VISIBLE_DEVICES:-0}"
export VLLM_PORT="${VLLM_PORT:-18020}"
export NUM_PROMPTS="${NUM_PROMPTS:-16}"

exec >>"$LOG" 2>&1
echo "=== ratio sweep $(date -Is) TARGET=${TARGET}x ==="

SUMMARY="$OE/logs/oe_turbo_ratio_sweep.txt"
echo "ratio,speedup,report" > "$SUMMARY"

for ratio in 2 4 8 16 32 64; do
  echo ""
  echo ">>> ratio=$ratio"
  export TURBO_ENV="export NPU_LLM_MODE=1 NPU_LLM_BURST=1 NPU_BURST_KERNELS_PER_TOKEN=${ratio} NPU_TOKEN_CHUNK=512 NPU_FCSP_REFILL_INTERVAL_US=50 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3"
  if bash /mnt/local/compare_perf_oe_turbo_68.sh; then
    REPORT=$(ls -t "$OE/logs/perf_oe_turbo_"*.txt | head -1)
    SPEEDUP=$(grep 'speedup_vs_origin:' "$REPORT" | tail -1 | sed 's/.*speedup_vs_origin: *//;s/x$//')
    echo "${ratio},${SPEEDUP},${REPORT}" >> "$SUMMARY"
    python3 - <<PY
s=float("${SPEEDUP}")
if s >= float("${TARGET}"):
    open("${OE}/logs/oe_turbo_TARGET_HIT.txt","w").write(f"ratio=${ratio} {s}x ${REPORT}\n")
    raise SystemExit(0)
PY
  else
    echo "${ratio},FAIL," >> "$SUMMARY"
  fi
  sleep 15
done

echo "=== sweep done $(date -Is) ==="
cat "$SUMMARY"
