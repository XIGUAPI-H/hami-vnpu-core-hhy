#!/usr/bin/env bash
# Minimal real K8s pod: hamiNewVllm.yaml + kylin/release-optimized SO only.
set -euo pipefail
SRC=/mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
DST=/tmp/vnpu-k8s-kylin-minimal.yaml
POD=vnpu-k8s-kylin-minimal-p0
SO=/mnt/local/m00953550/FinalTest/kylin/release-optimized
TAG=$(date +%Y%m%d_%H%M%S)
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/k8s_minimal_${TAG}.log

cp "$SRC" "$DST"
sed -i \
  -e "s/mhw-hami-soft-1split4-a/${POD}/" \
  -e "s|/mnt/local/m00953550/FinalTest/New/release|${SO}|g" \
  -e '/ASCEND_RT_VISIBLE_DEVICES/d' \
  -e 's/--gpu-memory-utilization 0.9/--gpu-memory-utilization 0.5/' \
  -e 's/--max_model_len 32768/--max_model_len 4096/' \
  -e 's/--max-num-batched-tokens 40960/--max-num-batched-tokens 4096/' \
  -e 's/--max-num-seqs 16/--max-num-seqs 8/' \
  -e 's/--no-enable-prefix-caching/--enforce-eager \\\n            --no-enable-prefix-caching/' \
  "$DST"

python3 - "$DST" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
text = p.read_text().split('---')[0].rstrip() + '\n'
text = text.replace('  schedulerName:', '  restartPolicy: Never\n  schedulerName:', 1)
Path(p.with_name(p.stem + '-pod-only.yaml')).write_text(text)
print('ok', p.with_name(p.stem + '-pod-only.yaml'))
PY

kubectl delete pod "$POD" -n default --ignore-not-found --wait=true
kubectl apply -f "${DST%.yaml}-pod-only.yaml"

{
  echo "=== k8s minimal kylin ${TAG} ==="
  sha256sum "${SO}/libvnpu.so" "${SO}/limiter"
  deadline=$((SECONDS + 1200))
  ip=""
  while (( SECONDS < deadline )); do
    ip=$(kubectl get pod "$POD" -n default -o jsonpath='{.status.podIP}' 2>/dev/null || true)
    if [[ -n "$ip" ]] && curl -sf --max-time 5 "http://${ip}:8000/health" >/dev/null 2>&1; then
      echo "HEALTH_OK ip=${ip}"; break
    fi
    phase=$(kubectl get pod "$POD" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" == "Failed" ]] && break
    sleep 15
  done
  [[ -z "$ip" ]] && { kubectl logs "$POD" -n default --tail=30; exit 1; }

  echo "--- stress 90s ---"
  tmp=$(mktemp -d); start=$(date +%s); reqs=0
  while (( $(date +%s) - start < 90 )); do
    for ((b=0;b<8;b++)); do
      rid=$reqs
      ( curl -sf --max-time 120 "http://${ip}:8000/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"t${rid}\"}],\"max_tokens\":256}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("usage",{}).get("completion_tokens",0))' \
          > "${tmp}/t${rid}" 2>/dev/null || echo 0 > "${tmp}/t${rid}" ) &
      reqs=$((reqs+1))
    done; wait
  done
  tok=0; for f in "${tmp}"/t*; do [[ -f "$f" ]] && tok=$((tok+$(cat "$f"))); done
  rm -rf "$tmp"
  elapsed=$(( $(date +%s) - start ))
  echo "stress reqs=${reqs} tokens=${tok} tok_s=$(python3 -c "print(f'{$tok/max($elapsed,1):.2f}')")"
  shm=$(kubectl logs "$POD" -n default 2>&1 | grep -c "No available shared memory" || true)
  echo "shm_broadcast=${shm}"
} 2>&1 | tee "$LOG"
echo "log: $LOG"
