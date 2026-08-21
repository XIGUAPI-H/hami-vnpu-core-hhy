#!/usr/bin/env bash
set -euo pipefail
export PATH="/root/.cargo/bin:$PATH"
export PYTHONPATH="/mnt/local/m00953550/benchmark:${PYTHONPATH:-}"
export FT=/mnt/local/m00953550/FinalTest
export ASCEND_RT_VISIBLE_DEVICES=4
export VLLM_PORT=18003
export NUM_PROMPTS=16
LOG=$FT/ubuntu/logs/perf_run_$(date +%Y%m%d_%H%M%S).log
nohup bash "$FT/ubuntu/compare_perf_optimized_ubuntu.sh" > "$LOG" 2>&1 &
echo "PID=$! LOG=$LOG"
