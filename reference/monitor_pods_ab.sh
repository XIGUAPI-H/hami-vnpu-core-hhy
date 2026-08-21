#!/bin/bash
LOG=/tmp/monitor_pods_ab.log
PODS="mhw-hami-soft-1split4-a mhw-hami-soft-1split4-b"
NS=default
while true; do
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"
  for POD in $PODS; do
    echo "--- $POD ---" >> "$LOG"
    kubectl get pod "$POD" -n "$NS" \
      -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount} age={.status.startTime}{"\n"}' \
      >> "$LOG" 2>&1
    kubectl exec "$POD" -n "$NS" -- bash -c \
      'netstat -tlnp 2>/dev/null | grep 8000 || echo port8000:DOWN' >> "$LOG" 2>&1
    kubectl logs "$POD" -n "$NS" --tail=4 >> "$LOG" 2>&1
    kubectl logs "$POD" -n "$NS" 2>&1 \
      | grep -iE 'Uvicorn|startup complete|Capturing ACL|KV cache|ERROR|Failed|OOM' \
      | tail -2 >> "$LOG" || true
  done
  echo >> "$LOG"
  sleep 60
done
