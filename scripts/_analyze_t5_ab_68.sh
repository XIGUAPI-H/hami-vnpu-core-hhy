#!/bin/bash
# Per-round breakdown + significance for the T5 1cut4/1cut20 A/B, so a 1-2ms gap
# is not mistaken for a real effect when round-to-round spread is larger.
TAG="${TAG:-burstfix5}"
OUT=/mnt/local/m00953550/FinalTest/kylin/smallmodel_ab/robust_cut4_20
python3 - "$OUT" "$TAG" <<'PY'
import json, sys, statistics, math
from pathlib import Path
out, tag = sys.argv[1], sys.argv[2]
def series(variant, split, key):
    vals=[]
    for r in range(1, 21):
        p=Path(out)/"json"/f"t5_{variant}_{split}_r{r}_{tag}.json"
        if p.exists():
            d=json.load(open(p))
            vals.append(float(d.get(key+"_sec",0))*1000)
    return vals
for split in ("1cut4","1cut20"):
    o=series("origin",split,"latency_avg")
    p=series("optimized",split,"latency_avg")
    if not o or not p:
        print(f"{split}: missing data"); continue
    print(f"\n=== {split}")
    print(f"  origin    rounds: {', '.join(f'{v:.2f}' for v in o)}")
    print(f"  optimized rounds: {', '.join(f'{v:.2f}' for v in p)}")
    om, pm = statistics.mean(o), statistics.mean(p)
    os_, ps = (statistics.stdev(o) if len(o)>1 else 0), (statistics.stdev(p) if len(p)>1 else 0)
    print(f"  origin    {om:.2f} +/- {os_:.2f} ms (n={len(o)})")
    print(f"  optimized {pm:.2f} +/- {ps:.2f} ms (n={len(p)})")
    diff = om - pm
    se = math.sqrt(os_**2/len(o) + ps**2/len(p)) if len(o)>1 and len(p)>1 else 0
    print(f"  diff      {diff:+.2f} ms ({diff/om*100:+.1f}% for optimized)  se={se:.2f}")
    if se:
        t = diff/se
        print(f"  t={t:+.2f} -> {'significant' if abs(t)>2.3 else 'NOT significant (within noise)'}")
    # throughput per request, from the same runs
    ot=series("origin",split,"latency_p90"); pt=series("optimized",split,"latency_p90")
    if ot and pt:
        print(f"  p90       origin {statistics.mean(ot):.2f} ms   optimized {statistics.mean(pt):.2f} ms")
PY
echo
echo "=== did the measured pod ever actually wait for tokens? (limiter MEASURING churn)"
for v in origin optimized; do
  for s in 1cut4 1cut20; do
    f=$(ls -t "$OUT/logs/limiter_vnpu_t5c_m_${v}_${s}_r1_${TAG}.log" 2>/dev/null | head -1)
    [[ -n "$f" ]] && echo "$v/$s: $(grep -c 'MEASURING\|Token empty' "$f" 2>/dev/null) sched events, $(wc -l < "$f") lines"
  done
done
