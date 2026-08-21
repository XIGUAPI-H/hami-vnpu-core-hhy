#!/usr/bin/env bash
set -euo pipefail
OUT=/mnt/local/fcsp0_5run_summary.log
: > "$OUT"
for i in 1 2 3 4 5 6 7 8; do
  echo "=== run $i $(date) ===" | tee -a "$OUT"
  OPT_REL=kylin/release-jun24-snapshot SKIP_BUILD=1 \
    bash /mnt/local/m00953550/hami-vnpu-core/scripts/repro_fcsp0_chunk8_68.sh 2>&1 \
    | tee "/mnt/local/fcsp0_run${i}.log" | grep -E '^E2EL|e2el_lead' | tee -a "$OUT"
  sleep 45
done
echo DONE >> "$OUT"
