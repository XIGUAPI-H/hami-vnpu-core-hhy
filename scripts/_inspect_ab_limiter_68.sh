#!/bin/bash
# Was the limiter actually enforcing during the A/B, and did the measured pod ever
# have to wait? Without this the latency numbers only describe hook overhead.
TAG="${TAG:-burstfix5}"
OUT=/mnt/local/m00953550/FinalTest/kylin/smallmodel_ab/robust_cut4_20
echo "=== limiter logs (measured pod, round 1)"
for v in origin optimized; do
  for s in 1cut4 1cut20; do
    f="$OUT/logs/limiter_vnpu_t5c_m_${v}_${s}_r1_${TAG}.log"
    echo "--- $v/$s"
    cat "$f" 2>/dev/null || echo "(missing)"
  done
done
echo
echo "=== limiter logs (competitor pod, round 1)"
for v in origin optimized; do
  f="$OUT/logs/limiter_vnpu_t5c_c_${v}_1cut20_r1_${TAG}.log"
  echo "--- $v/1cut20 competitor"
  cat "$f" 2>/dev/null || echo "(missing)"
done
echo
echo "=== bench log: kernels/requests actually run, plus any wait evidence"
b="$OUT/logs/bench_optimized_1cut20_r1_${TAG}.log"
grep -E 'Model loaded|latency_avg|ok latency|tokens' "$b" 2>/dev/null | head -12
echo
echo "=== how many output tokens per request (summary json)"
python3 - "$OUT" "$TAG" <<'PY'
import json,sys
from pathlib import Path
out,tag=sys.argv[1],sys.argv[2]
for v in ("origin","optimized"):
    p=Path(out)/"json"/f"t5_{v}_1cut20_r1_{tag}.json"
    if p.exists():
        d=json.load(open(p))
        keys=[k for k in d if 'token' in k.lower() or 'tps' in k.lower() or 'wall' in k.lower() or 'count' in k.lower()]
        print(v, {k:d[k] for k in keys})
PY
