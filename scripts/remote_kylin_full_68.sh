#!/usr/bin/env bash
# Build Kylin SO + run A/B perf on 68.
set -euo pipefail
FT=/mnt/local/m00953550/FinalTest
mkdir -p $FT/kylin/logs
cp -f /mnt/local/build_kylin_native_68.sh $FT/kylin/ 2>/dev/null || true
cp -f /mnt/local/compare_perf_kylin_68.sh $FT/kylin/ 2>/dev/null || true
chmod +x $FT/kylin/*.sh /mnt/local/*.sh 2>/dev/null || true
bash /mnt/local/build_kylin_native_68.sh
LOG=$FT/kylin/logs/perf_run_$(date +%Y%m%d_%H%M%S).log
nohup bash /mnt/local/compare_perf_kylin_68.sh > "$LOG" 2>&1 &
echo "PID=$! LOG=$LOG"
