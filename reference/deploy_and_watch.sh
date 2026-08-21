#!/bin/bash
set -u
cd /mnt/local/m00953550/FinalTest
kubectl delete job mhw-normal-job-ray-head --ignore-not-found=true
kubectl delete svc mhw-qwen-service --ignore-not-found=true
sleep 4
kubectl apply -f hamiJobVllm.yaml

echo "=== waiting for pod ==="
for i in $(seq 1 30); do
  POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-normal-job-ray-head-/ {print $1; exit}')
  if [ -n "$POD" ]; then break; fi
  sleep 2
done
echo "POD=$POD"
[ -z "$POD" ] && { echo "no pod"; kubectl get pods | head; exit 1; }

mkdir -p /tmp/61logs
LOG=/tmp/61logs/${POD}.log
echo "Streaming to $LOG"
kubectl logs -f "$POD" > "$LOG" 2>&1 &
LPID=$!

for i in $(seq 1 90); do
  STATUS=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  REASON=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)
  RESTARTS=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  echo "[t=${i}x4s] phase=$STATUS reason=$REASON restarts=$RESTARTS"
  if [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Succeeded" ]; then break; fi
  if [ -n "$REASON" ] && [ "$REASON" != "Completed" ]; then break; fi
  sleep 4
done

kill $LPID 2>/dev/null
wait $LPID 2>/dev/null

echo
echo "=== final status ==="
kubectl get pod "$POD" -o wide
echo
echo "=== container status ==="
kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[*].state}'; echo
echo "=== log tail (200) ==="
tail -200 "$LOG"
