#!/usr/bin/env bash
set -euo pipefail
pkill -f compare_perf_kylin_native_sweep_68 2>/dev/null || true
sleep 1
cd /mnt/local
export ASCEND_RT_VISIBLE_DEVICES=0 MAX_NUM_SEQS=16 MAX_BATCHED=4096 GPU_MEM_UTIL=0.6 \
  MAX_MODEL_LEN=2048 CONCURRENCY=16 BATCH_SIZE=16 MAX_OUT_LEN=256 NUM_PROMPTS=32 NPU_TOKEN_CHUNK=8
export SCENARIOS='kt16_optfirst|opt_first|0|1|8|0 kt16_originfirst|origin_first|0|1|8|0'
setsid bash /mnt/local/compare_perf_kylin_native_sweep_68.sh \
  > /mnt/local/m00953550/FinalTest/kylin/logs/tsv110_c16_launch.log 2>&1 < /dev/null &
echo "launched pid=$!"
