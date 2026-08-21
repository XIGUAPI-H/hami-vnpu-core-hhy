#!/bin/bash
# Is anything other than our A/B container using NPU 6, and how did the previous
# (faster) origin 1cut20 run differ?
echo "=== npu-smi: NPU 6 utilisation + processes"
npu-smi info | grep -E '^\| 6 ' -A2
npu-smi info | grep -E '^\| 6 +[0-9]+ +\|'
echo
echo "=== our container's NPU процesses"
docker ps --format '{{.Names}}' | grep qwen-c420 | while read -r c; do
  echo "--- $c"
  docker top "$c" 2>/dev/null | head -5
done
echo
echo "=== previous (faster) origin 1cut20 run: bench params + timing"
OUT=/mnt/local/m00953550/FinalTest/kylin/smallmodel_ab/qwen_cut4_20
for t in 20260727_qwen_c420fix2 20260727_qwen_c420; do
  f="$OUT/json/qwen_origin_1cut20_${t}.json"
  [[ -f "$f" ]] && python3 -c "
import json,sys
d=json.load(open('$f'))
print('$t', {k:d[k] for k in d if any(s in k for s in ('count','latency_avg','rtf_avg','wall','warmup'))})"
done
echo
echo "=== current run per-request latencies so far"
tail -30 "$OUT/logs/bench_origin_1cut20_burstfix.log" 2>/dev/null | tail -12
