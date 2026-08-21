#!/bin/bash
# Probe the prerequisites for the T5 1cut4/1cut20 origin-vs-optimized A/B on 68,
# plus any past limiter scheduling logs that show the actual rest-window sizes.
FT=/mnt/local/m00953550/FinalTest
KY="$FT/kylin"
echo "=== release dirs"
ls -la "$KY/release-origin" "$KY/release-optimized" 2>&1 | head -20
echo "=== bench scripts"
ls -la "$KY/smallmodel_ab/robust/t5_bench_robust.py" "$KY/smallmodel_ab/robust/t5_competitor.py" \
       "$KY/smallmodel_ab/t5_bench_robust.py" "$KY/smallmodel_ab/t5_competitor.py" 2>&1 | head
echo "=== model"
ls -d /mnt/local/m00953550/smallModel/t5/models/flan-t5-base 2>&1
echo "=== image"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -i -E 'sovits|t5' | head
echo "=== npus free"
npu-smi info -l 2>/dev/null | head -20
echo "=== past cut4_20 reports"
ls -t "$KY/smallmodel_ab/robust_cut4_20/report_"*.txt 2>/dev/null | head -5
echo "=== Sched rest windows seen in past limiter logs"
grep -rhoE '\[Sched\].*Rest: [0-9]+ms' "$KY" 2>/dev/null | tail -20
echo "=== any limiter logs at all"
ls -t "$KY/smallmodel_ab/robust_cut4_20/logs/limiter_"*.log 2>/dev/null | head -3
