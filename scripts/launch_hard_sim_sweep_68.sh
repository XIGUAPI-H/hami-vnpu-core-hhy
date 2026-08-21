#!/usr/bin/env bash
# Detached launcher for hard-sim sweep on 68 (survives SSH disconnect).
set -euo pipefail

SCRIPT="${SCRIPT:-/mnt/local/compare_hard_sim_kylin_68.sh}"
LOCK="${LOCK:-/tmp/hard_sim_sweep.lock}"
LOG="${LOG:-/mnt/local/m00953550/FinalTest/kylin/logs/hard_sim_launch.log}"
PIDFILE="${PIDFILE:-/tmp/hard_sim_sweep.pid}"

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another hard_sim sweep is running (lock $LOCK)"
  exit 1
fi

: >>"$LOG"
{
  echo "===== launcher $(date -Iseconds) pid=$$ ====="
  bash "$SCRIPT"
  ec=$?
  echo "===== finished $(date -Iseconds) exit=$ec ====="
  exit $ec
} >>"$LOG" 2>&1
