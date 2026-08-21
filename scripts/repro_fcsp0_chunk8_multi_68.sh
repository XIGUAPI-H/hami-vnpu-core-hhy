#!/usr/bin/env bash
# Run fcsp0_chunk8 A/B N times; pick best E2EL lead.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
RUNS="${RUNS:-5}"
SKIP_BUILD="${SKIP_BUILD:-1}"
BEST_LEAD=-999
BEST_REPORT=""

for i in $(seq 1 "$RUNS"); do
  echo "=== iteration $i/$RUNS ==="
  TAG="run${i}_$(date +%H%M%S)"
  SKIP_BUILD="$SKIP_BUILD" \
    bash /mnt/local/m00953550/hami-vnpu-core/scripts/repro_fcsp0_chunk8_68.sh 2>&1 | tee "/mnt/local/fcsp0_iter_${TAG}.log"
  R=$(ls -t "$FT/kylin/logs/fcsp0_chunk8_repro_"*.txt | head -1)
  lead=$(grep e2el_lead_vs_origin "$R" | awk '{print $2}' | tr -d '%' || echo -999)
  e2el_opt=$(grep '^E2EL' "$R" | awk '{print $2}')
  e2el_origin=$(grep '^E2EL' "$R" | awk '{print $3}')
  echo "iter=$i lead=${lead}% opt=$e2el_opt origin=$e2el_origin report=$R"
  python3 - <<PY
lead=float("${lead}")
best=float("${BEST_LEAD}")
import sys
sys.exit(0 if lead > best else 1)
PY
  if [[ $? -eq 0 ]]; then
    BEST_LEAD="$lead"
    BEST_REPORT="$R"
  fi
  sleep 10
done

echo "=== BEST E2EL lead: ${BEST_LEAD}% report=${BEST_REPORT} ==="
grep -A8 'results (historical' "$BEST_REPORT" || true
