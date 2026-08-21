#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo "=== pod status ==="
kubectl get pods | grep mhw-hami-soft
echo
POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-hami-soft/ {print $1; exit}')
[ -z "$POD" ] && exit 0
echo "POD=$POD"
echo
echo "=== phase / restarts ==="
kubectl get pod "$POD" -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount} reason={.status.containerStatuses[0].lastState.terminated.reason}'; echo
echo
mkdir -p /tmp/68logs
LOG=/tmp/68logs/${POD}.log
kubectl logs --tail=2000 "$POD" > "$LOG" 2>&1
echo "saved $(wc -l < $LOG) lines to $LOG"

echo
echo "=== KEY MEMORY LOGS ==="
grep -nE 'Available memory|GPU KV cache|init engine|Application startup|OOM|ValueError|AssertionError|RuntimeError|peak|gpu_memory_utilization|kv_cache_memory|non_torch|FATAL|Traceback|Error' "$LOG" | tail -60

echo
echo "=== first 30 vnpu/meminfo lines ==="
grep -nE 'meminfo#|vnpu|libvnpu|vxpu_' "$LOG" | head -30

echo
echo "=== applied count summary ==="
grep -oE 'applied=[0-9]+' "$LOG" | sort | uniq -c
echo
echo "=== passthrough count ==="
grep -c 'passthrough' "$LOG"
echo
echo "=== last 30 lines ==="
tail -30 "$LOG"
EOF
