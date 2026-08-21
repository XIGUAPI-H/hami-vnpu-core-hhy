#!/usr/bin/env bash
set -euo pipefail
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/perf_kylin_native_run.log
exec >>"$LOG" 2>&1
echo "=== start $(date -Iseconds) ==="
exec bash /mnt/local/compare_perf_kylin_native_68.sh
