#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-hami-soft/ {print $1; exit}')
echo "POD=$POD"
kubectl get pod "$POD" -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount}'; echo
echo
echo '=== hal hooks ==='
kubectl logs "$POD" 2>&1 | grep -E 'vnpu-hal|Available memory|GPU KV cache|Application startup|RuntimeError|OOM' | tail -40
echo
echo '=== previous container (if restarted) ==='
kubectl logs --previous "$POD" 2>&1 | grep -E 'vnpu-hal|Available memory|GPU KV cache|Application startup|RuntimeError|OOM' | tail -20
echo
echo '=== meminfo passthrough sample ==='
kubectl logs "$POD" 2>&1 | grep 'meminfo#' | head -10
echo
echo '=== tail ==='
kubectl logs --tail=15 "$POD" 2>&1
EOF
