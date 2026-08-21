#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo "=== pod status ==="
kubectl get pods | grep mhw-hami-soft
echo
POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-hami-soft/ {print $1; exit}')
[ -z "$POD" ] && exit 0
echo "POD=$POD"
echo "=== phase / restarts ==="
kubectl get pod "$POD" -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount} reason={.status.containerStatuses[0].lastState.terminated.reason}'; echo
echo
echo "=== pod env (VXPU/NPU) ==="
kubectl describe pod "$POD" | grep -E 'VXPU|NPU_|VLLM|LD_PRELOAD' | head -20
echo
echo "=== previous container log (last terminated) ==="
kubectl logs --previous --tail=200 "$POD" 2>&1 | tail -100
EOF
