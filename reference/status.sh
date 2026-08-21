#!/bin/bash
echo '=== pods ==='
kubectl get pods -o wide | grep -E 'mhw|vllm|vnpu|NAME'
echo
POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-normal-job-ray-head-/ {print $1; exit}')
echo "POD=$POD"
[ -z "$POD" ] && exit 0
echo
echo "=== pod status ==="
kubectl get pod "$POD" -o jsonpath='{.status.phase} restarts={.status.containerStatuses[0].restartCount} ready={.status.containerStatuses[0].ready}'; echo
echo
echo "=== log tail (300) ==="
kubectl logs --tail=300 "$POD" 2>&1
