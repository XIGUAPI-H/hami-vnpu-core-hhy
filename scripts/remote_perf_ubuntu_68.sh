#!/usr/bin/env bash
set -euo pipefail
export PATH="/root/.cargo/bin:$PATH"
export PYTHONPATH="/mnt/local/m00953550/benchmark:${PYTHONPATH:-}"
export FT=/mnt/local/m00953550/FinalTest
export ASCEND_RT_VISIBLE_DEVICES=4
export VLLM_PORT=18003
export NUM_PROMPTS=16
# 1切10: 10 tenants × 10% core, 6400MiB mem each; fixed share off (default)
export NPU_FIXED_SHARE_RATIO=0
export NPU_PRIORITY=10
export NPU_MEM_QUOTA=6400
export SPLIT_TENANTS=10

docker rm -f vnpu-perf-release vnpu-perf-main vnpu-ubuntu-perf-opt vnpu-ubuntu-perf-main 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
pkill -f 'FinalTest/ubuntu/release-main/limiter' 2>/dev/null || true
sleep 2

LOG=$FT/ubuntu/logs/perf_run_$(date +%Y%m%d_%H%M%S).log
nohup bash "$FT/ubuntu/compare_perf_ubuntu_68.sh" > "$LOG" 2>&1 &
echo "PID=$! LOG=$LOG"
