#!/bin/bash
# Compact status of the Qwen-TTS compute-only A/B: per-cell numbers as they land,
# plus the origin-vs-optimized gap and the 1cut20/1cut4 share ratio.
TAG="${TAG:-burstfix}"
OUT=/mnt/local/m00953550/FinalTest/kylin/smallmodel_ab/qwen_cut4_20
python3 - "$OUT" "$TAG" <<'PY'
import json,sys
from pathlib import Path
out,tag=Path(sys.argv[1]),sys.argv[2]
cells={}
for v in ("origin","optimized"):
    for s in ("1cut4","1cut20"):
        p=out/"json"/f"qwen_{v}_{s}_{tag}.json"
        if p.exists():
            d=json.load(open(p))
            cells[(v,s)]=d
            print(f"{v:<10} {s:<7} latency_avg={float(d['latency_avg_sec']):8.2f}s  "
                  f"rtf_avg={float(d['rtf_avg']):7.3f}  ok={d.get('success_count')}/{d.get('measured_count')}")
        else:
            print(f"{v:<10} {s:<7} (pending)")
print()
for s in ("1cut4","1cut20"):
    if ("origin",s) in cells and ("optimized",s) in cells:
        o=float(cells[("origin",s)]["latency_avg_sec"]); p_=float(cells[("optimized",s)]["latency_avg_sec"])
        print(f"{s}: optimized vs origin latency {(o-p_)/o*100:+.1f}% (origin {o:.2f}s -> opt {p_:.2f}s)")
for v in ("origin","optimized"):
    if (v,"1cut4") in cells and (v,"1cut20") in cells:
        a=float(cells[(v,"1cut4")]["latency_avg_sec"]); b=float(cells[(v,"1cut20")]["latency_avg_sec"])
        print(f"{v}: 1cut20/1cut4 latency ratio = {b/a:.3f} (share is binding if clearly >1)")
PY
echo
echo "=== ACL / engine errors per cell"
for v in origin optimized; do
  for s in 1cut4 1cut20; do
    f="$OUT/workdir/${v}_${s}_${TAG}/vllm_serve.log"
    if [[ -f "$f" ]]; then
      n=$(strings "$f" | grep -cE '507018|EngineDead|aclnnLeTensor' )
      echo "$v/$s: $n error hits"
    fi
  done
done
echo
echo "=== progress"
tail -2 /root/qwen_ab_burstfix.log
