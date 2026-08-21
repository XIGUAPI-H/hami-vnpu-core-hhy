#!/usr/bin/env bash
# Detached compute-bound dual-order A/B (opt vs origin) on device 0.
# Drives higher concurrency so the scheduler path actually binds (vs the
# bandwidth-bound low-concurrency default where soft already == origin).
set -euo pipefail
export ASCEND_RT_VISIBLE_DEVICES=0
export VLLM_PORT=18120
# Compute-bound knobs (inherited by run_vllm + aisbench through the sweep).
export MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
export MAX_BATCHED="${MAX_BATCHED:-8192}"
export GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.8}"
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
export CONCURRENCY="${CONCURRENCY:-16}"
export BATCH_SIZE="${BATCH_SIZE:-16}"
export NUM_PROMPTS="${NUM_PROMPTS:-48}"
export SCENARIOS="fcsp0_opt_first fcsp0_origin_first"
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/compute_ab_dev0_$(date +%Y%m%d_%H%M%S).log
mkdir -p "$(dirname "$LOG")"
echo "log=$LOG"
setsid bash /mnt/local/m00953550/hami-vnpu-core/scripts/compare_perf_kylin_native_sweep_68.sh \
  >"$LOG" 2>&1 < /dev/null &
echo "pid=$!"
echo "$LOG" > /tmp/compute_ab_dev0.logpath
