#!/usr/bin/env bash
set -euo pipefail
pkill -f compare_perf_kylin_native_sweep_68 2>/dev/null || true
sleep 1
cd /mnt/local
export ASCEND_RT_VISIBLE_DEVICES=0 MAX_NUM_SEQS=32 MAX_BATCHED=4096 GPU_MEM_UTIL=0.7 \
  MAX_MODEL_LEN=1536 CONCURRENCY=32 BATCH_SIZE=32 MAX_OUT_LEN=256 NUM_PROMPTS=64 NPU_TOKEN_CHUNK=8
export SCENARIOS='kt32_optfirst|opt_first|0|1|8|0 kt32_originfirst|origin_first|0|1|8|0'
setsid bash /mnt/local/compare_perf_kylin_native_sweep_68.sh \
  > /mnt/local/m00953550/FinalTest/kylin/logs/tsv110_c32_launch.log 2>&1 < /dev/null &
echo "launched pid=$!"
