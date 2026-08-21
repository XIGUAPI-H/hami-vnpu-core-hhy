#!/usr/bin/env bash
# K8s repro matching production screenshot (podA): fixed+FCSP=1, token_chunk=8,
# ACL graph FULL_DECODE_ONLY, no enforce-eager. Uses latest kylin/release-optimized SO.
set -euo pipefail

SRC=/mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
DST=/tmp/vnpu-k8s-kylin-screenshot.yaml
POD=vnpu-k8s-kylin-screenshot-p0
SO=/mnt/local/m00953550/FinalTest/kylin/release-optimized
TAG=$(date +%Y%m%d_%H%M%S)
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/k8s_screenshot_${TAG}.log
STRESS_SEC="${STRESS_SEC:-120}"
CONCURRENCY="${CONCURRENCY:-8}"

python3 - "$SRC" "$DST" "$POD" "$SO" <<'PY'
import re, sys
from pathlib import Path

src, dst, pod, so = sys.argv[1:5]
text = Path(src).read_text().split('---')[0]

text = text.replace('mhw-hami-soft-1split4-a', pod)
text = text.replace('/mnt/local/m00953550/FinalTest/New/release', so)

# Drop manual device pin; HAMi scheduler assigns the vNPU.
text = re.sub(r'\n\s*export ASCEND_RT_VISIBLE_DEVICES=\d+', '', text)
text = re.sub(
    r'        # - name: ASCEND_RT_VISIBLE_DEVICES\n        #   value: "5"\n',
    '',
    text,
)

# Screenshot limiter env block (no kylin_lite/preset).
old_exports = """          export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry"
          export NPU_MEM_QUOTA=16000 
          export NPU_PRIORITY=25 # use half of computing power than another one with priority 40
          /mnt/local/m00953550/FinalTest/New/release/limiter > /mnt/local/m00953550/FinalTest/New/release/limiter.log 2>&1 &
          # 32768   40960
          export VXPU_CORE_LIMIT_PERCENT=25"""

new_exports = f"""          export NPU_FIXED_SHARE_RATIO=1
          export NPU_FCSP_REFILL=1
          export NPU_TOKEN_CHUNK=8
          export NPU_KERNEL_BURST=1
          export NPU_BURST_CONTINUOUS=1
          export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry"
          export NPU_MEM_QUOTA=16000
          export NPU_PRIORITY=25
          {so}/limiter > {so}/limiter.log 2>&1 &
          sleep 10"""

text = text.replace(old_exports.replace('/mnt/local/m00953550/FinalTest/New/release', so), new_exports)
# Fallback if prior sed already swapped paths.
text = re.sub(
    r'export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry"\s*\n'
    r'\s*export NPU_MEM_QUOTA=16000\s*\n'
    r'\s*export NPU_PRIORITY=25[^\n]*\n'
    r'\s*' + re.escape(so) + r'/limiter[^\n]*\n'
    r'(?:\s*# 32768[^\n]*\n)?'
    r'\s*export VXPU_CORE_LIMIT_PERCENT=25',
    new_exports,
    text,
    count=1,
)

# vLLM args: screenshot values + ACL graph (no enforce-eager).
text = re.sub(r'--gpu-memory-utilization 0\.\d+', '--gpu-memory-utilization 0.5', text)
text = re.sub(r'--max-num-seqs \d+', '--max-num-seqs 4', text)
text = re.sub(r'--max_model_len \d+', '--max_model_len 4096', text)
text = re.sub(r'--max-num-batched-tokens \d+', '--max-num-batched-tokens 4096', text)
text = re.sub(r'\s*--enforce-eager \\\n', '\n', text)
text = re.sub(
    r"\s*--compilation-config '\{[^']+\}' \\\n",
    '\n',
    text,
)
text = re.sub(
    r'--no-enable-prefix-caching',
    "--compilation-config '{\"cudagraph_mode\": \"FULL_DECODE_ONLY\",\"cudagraph_capture_sizes\":[1,2,4,8,16]}' \\\n"
    '            --no-enable-prefix-caching',
    text,
    count=1,
)

text = text.replace('  schedulerName:', '  restartPolicy: Never\n  schedulerName:', 1)
Path(dst).write_text(text + '\n')
print('wrote', dst)
PY

kubectl delete pod "$POD" -n default --ignore-not-found --wait=true
kubectl apply -f "$DST"

{
  echo "=== k8s screenshot repro ${TAG} ==="
  echo "pod=${POD} SO=${SO}"
  sha256sum "${SO}/libvnpu.so" "${SO}/limiter"
  echo "env: NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_TOKEN_CHUNK=8"
  echo "     NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1 NPU_MEM_QUOTA=16000 NPU_PRIORITY=25"
  echo "vllm: ACL graph FULL_DECODE_ONLY [1,2,4,8,16], max-num-seqs=4, no enforce-eager"
  echo ""

  deadline=$((SECONDS + 1500))
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

  if [[ -z "$ip" ]]; then
    echo "FAIL: pod not healthy"
    kubectl describe pod "$POD" -n default | tail -40
    kubectl logs "$POD" -n default --tail=80
    exit 1
  fi

  # Warmup
  curl -sf "http://${ip}:8000/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":64}' >/dev/null || true

  echo "--- stress ${STRESS_SEC}s concurrency=${CONCURRENCY} ---"
  tmp=$(mktemp -d); start=$(date +%s); reqs=0
  while (( $(date +%s) - start < STRESS_SEC )); do
    for ((b=0; b<CONCURRENCY; b++)); do
      rid=$reqs
      ( curl -sf --max-time 120 "http://${ip}:8000/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"压测${rid}\"}],\"max_tokens\":512,\"temperature\":0.01}" \
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

  shm=$(kubectl logs "$POD" -n default 2>&1 | grep -c "No available shared memory" || true)
  fatal=$(kubectl logs "$POD" -n default 2>&1 | grep -cE "EngineCore.*fatal|sample_tokens timed out|Engine core initialization failed" || true)
  echo "shm_broadcast=${shm} fatal=${fatal}"
  [[ "$shm" -gt 0 ]] && echo ">>> REPRODUCED shm_broadcast in K8s Pod"

  echo ""
  echo "--- crash signals (last 20) ---"
  kubectl logs "$POD" -n default 2>&1 | grep -E "shm_broadcast|shared memory|timed out|fatal|panic" | tail -20 || true
} 2>&1 | tee "$LOG"
echo "log: $LOG"
