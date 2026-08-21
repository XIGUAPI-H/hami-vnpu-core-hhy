#!/usr/bin/env bash
set -euo pipefail
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/perf_run_rerun.log
exec >>"$LOG" 2>&1
echo "=== start $(date -Iseconds) pid=$$ ==="
exec bash /mnt/local/compare_perf_kylin_68.sh
