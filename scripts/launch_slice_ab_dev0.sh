#!/usr/bin/env bash
# Detached dual-order A/B (opt vs origin) on device 0 to validate the
# slice-smoothing build (no regression + boot health).
set -euo pipefail
export ASCEND_RT_VISIBLE_DEVICES=0
export VLLM_PORT=18120
export NUM_PROMPTS="${NUM_PROMPTS:-16}"
export SCENARIOS="fcsp0_opt_first fcsp0_origin_first"
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/slice_ab_dev0_$(date +%Y%m%d_%H%M%S).log
mkdir -p "$(dirname "$LOG")"
echo "log=$LOG"
setsid bash /mnt/local/m00953550/hami-vnpu-core/scripts/compare_perf_kylin_native_sweep_68.sh \
  >"$LOG" 2>&1 < /dev/null &
echo "pid=$!"
echo "$LOG" > /tmp/slice_ab_dev0.logpath
