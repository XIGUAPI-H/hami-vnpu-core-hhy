#!/usr/bin/env bash
# Extended stress on running screenshot-repro K8s pod.
set -euo pipefail
POD="${POD:-vnpu-k8s-kylin-screenshot-p0}"
NS="${NS:-default}"
STRESS_SEC="${STRESS_SEC:-300}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-512}"
TAG=$(date +%Y%m%d_%H%M%S)
LOG="/mnt/local/m00953550/FinalTest/kylin/logs/k8s_screenshot_stress_${TAG}.log"

ip=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.podIP}')
[[ -z "$ip" ]] && { echo "no pod ip"; exit 1; }
curl -sf "http://${ip}:8000/health" >/dev/null || { echo "health fail"; exit 1; }

{
  echo "=== extended stress ${TAG} pod=${POD} ip=${ip} sec=${STRESS_SEC} conc=${CONCURRENCY} ==="
  tmp=$(mktemp -d); start=$(date +%s); reqs=0
  while (( $(date +%s) - start < STRESS_SEC )); do
    for ((b=0; b<CONCURRENCY; b++)); do
      rid=$reqs
      ( curl -sf --max-time 180 "http://${ip}:8000/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"长压测${rid}\"}],\"max_tokens\":${MAX_TOKENS},\"temperature\":0.01}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("usage",{}).get("completion_tokens",0))' \
          > "${tmp}/t${rid}" 2>/dev/null || echo 0 > "${tmp}/t${rid}" ) &
      reqs=$((reqs+1))
    done
    wait
  done
  tok=0; for f in "${tmp}"/t*; do [[ -f "$f" ]] && tok=$((tok+$(cat "$f"))); done
  rm -rf "$tmp"
  elapsed=$(( $(date +%s) - start ))
  echo "stress reqs=${reqs} tokens=${tok} tok_s=$(python3 -c "print(f'{$tok/max($elapsed,1):.2f}')")"
  shm=$(kubectl logs "$POD" -n "$NS" 2>&1 | grep -c "No available shared memory" || true)
  fatal=$(kubectl logs "$POD" -n "$NS" 2>&1 | grep -cE "EngineCore.*fatal|sample_tokens timed out" || true)
  echo "shm_broadcast=${shm} fatal=${fatal}"
  kubectl logs "$POD" -n "$NS" 2>&1 | grep -E "shm_broadcast|shared memory|timed out|fatal" | tail -30 || true
} 2>&1 | tee "$LOG"
echo "log: $LOG"
