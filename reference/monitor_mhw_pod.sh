#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
LOG=/tmp/monitor_${POD}.log
n=0
echo "monitor start $(date -u -Iseconds)" | tee "$LOG"
while true; do
  n=$((n+1))
  ts=$(date -u '+%H:%M:%S')
  phase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo GONE)
  restarts=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')
  port=$(kubectl exec "$POD" -n "$NS" -- bash -c 'netstat -tlnp 2>/dev/null | grep :8000 || echo DOWN' 2>/dev/null | tail -1)
  wcpu=$(kubectl exec "$POD" -n "$NS" -- ps -p 88 -o pcpu= 2>/dev/null | tr -d ' ')
  {
    echo "===== [$ts] check #$n phase=$phase restarts=$restarts port8000=$port worker_cpu=${wcpu:-NA}% ====="
    kubectl logs "$POD" -n "$NS" --tail=6 2>&1 | grep -v meminfo | tail -5
    err=$(kubectl logs "$POD" -n "$NS" --tail=300 2>&1 | grep -iE 'ERROR|Error|Failed|Traceback|Exception|OOM|killed|SIGSEGV|CRITICAL' | grep -v meminfo | tail -5)
    if [ -n "$err" ]; then
      echo "--- ERRORS (recent) ---"
      echo "$err"
    fi
    prog=$(kubectl logs "$POD" -n "$NS" 2>&1 | grep -E 'Capturing ACL|Uvicorn|startup complete|Application startup|Started server' | tail -3)
    if [ -n "$prog" ]; then
      echo "--- PROGRESS ---"
      echo "$prog"
    fi
  } | tee -a "$LOG"

  if echo "$port" | grep -q 8000; then
    echo "*** SERVICE UP on 8000 ***" | tee -a "$LOG"
    exit 0
  fi
  if [ "$phase" != Running ]; then
    echo "*** POD NOT RUNNING: $phase ***" | tee -a "$LOG"
    kubectl describe pod "$POD" -n "$NS" 2>&1 | tail -20 | tee -a "$LOG"
    exit 1
  fi
  sleep 60
done
