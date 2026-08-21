#!/bin/bash
POD=mhw-hami-soft-1split4-a
INTERVAL=${1:-30}
ROUNDS=${2:-12}
for i in $(seq 1 "$ROUNDS"); do
  echo "========== $(date -Iseconds) check #$i =========="
  kubectl get pod "$POD" --no-headers 2>/dev/null || exit 1
  kubectl exec "$POD" -- bash -c '
    pgrep -a limiter | head -1 || echo "limiter=NOT_RUNNING"
    ls -la /dev/shm/vnpu_local_session 2>&1
    curl -s -m 3 -w " health=%{http_code}\n" -o /dev/null http://127.0.0.1:8000/health 2>/dev/null || echo "health=unreachable"
    curl -s -m 3 -w " models=%{http_code}\n" -o /dev/null http://127.0.0.1:8000/v1/models 2>/dev/null || echo "models=unreachable"
  ' 2>/dev/null
  echo "--- last logs ---"
  kubectl logs "$POD" --tail=10 2>/dev/null
  echo ""
  sleep "$INTERVAL"
done
