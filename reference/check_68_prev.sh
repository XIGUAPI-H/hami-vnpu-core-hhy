#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-hami-soft/ {print $1; exit}')
[ -z "$POD" ] && exit 0
echo "POD=$POD"
echo
echo '=== current phase ==='
kubectl get pod "$POD" -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount} reason={.status.containerStatuses[0].lastState.terminated.reason}'; echo
echo
echo '=== previous container key memory log ==='
kubectl logs --previous "$POD" 2>&1 | grep -nE 'Available memory|GPU KV cache|init engine|Application startup|OOM|ValueError|AssertionError|RuntimeError|peak memory|kv_cache_memory|non_torch|FATAL|already allocated|gpu_memory_utilization' | tail -30
echo
echo '=== current container progress (last 60 lines) ==='
kubectl logs --tail=60 "$POD" 2>&1 | tail -60
EOF
