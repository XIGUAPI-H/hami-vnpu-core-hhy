#!/bin/bash
LOG=/tmp/monitor_mhw_pod.log
POD=mhw-hami-soft-1split4-a
NS=default
while true; do
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"
  kubectl get pod "$POD" -n "$NS" \
    -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount}{"\n"}' \
    >> "$LOG" 2>&1
  kubectl logs "$POD" -n "$NS" --tail=10 >> "$LOG" 2>&1
  echo "---PORT---" >> "$LOG"
  kubectl exec "$POD" -n "$NS" -- bash -c \
    'netstat -tlnp 2>/dev/null | grep 8000 || echo down' >> "$LOG" 2>&1
  echo "---ERR---" >> "$LOG"
  kubectl logs "$POD" -n "$NS" 2>&1 \
    | grep -iE 'error|failed|oom|traceback|killed|segfault' | tail -5 >> "$LOG" \
    || echo none >> "$LOG"
  echo >> "$LOG"
  sleep 60
done
