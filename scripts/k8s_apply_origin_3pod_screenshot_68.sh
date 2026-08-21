#!/usr/bin/env bash
# Real K8s: 3 pods on one card (HAMi soft 25%×3), screenshot podA config, origin lib.
set -uo pipefail

SRC=/mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
FT="${FT:-/mnt/local/m00953550/FinalTest}"
SO="${SO_OVERRIDE:-${FT}/kylin/release-origin}"
[[ -n "${SO_REL:-}" ]] && SO="${FT}/${SO_REL}"
IMAGE="${VLLM_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
TAG=$(date +%Y%m%d_%H%M%S)
NUM_PODS="${NUM_PODS:-3}"
PREFIX=vnpu-k8s-origin-3pod
OUT=/tmp/${PREFIX}-${TAG}.yaml
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/k8s_origin_3pod_${TAG}.log
STRESS_SEC="${STRESS_SEC:-300}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-512}"
GLOBAL_PATH="/hami-shared-region/global_registry"
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
REGISTRY_CLEANUP="${REGISTRY_CLEANUP:-1}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"

stress_pod() {
  local ip=$1 pid=$2
  local tmp start reqs=0 tok=0 el
  tmp=$(mktemp -d)
  start=$(date +%s)
  while (( $(date +%s) - start < STRESS_SEC )); do
    for ((b=0; b<CONCURRENCY; b++)); do
      local rid=$reqs
      ( curl -sf --max-time 180 "http://${ip}:8000/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"p${pid}t${rid}\"}],\"max_tokens\":${MAX_TOKENS},\"temperature\":0.01}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("usage",{}).get("completion_tokens",0))' \
          > "${tmp}/t${rid}" 2>/dev/null || echo 0 > "${tmp}/t${rid}" ) &
      reqs=$((reqs+1))
    done
    wait
  done
  tok=0
  for f in "${tmp}"/t*; do [[ -f "$f" ]] && tok=$((tok+$(cat "$f"))); done
  rm -rf "$tmp"
  el=$(( $(date +%s) - start ))
  echo "pod${pid} ip=${ip} reqs=${reqs} tokens=${tok} tok_s=$(python3 -c "print(f'{$tok/max($el,1):.2f}')")"
}

python3 - "$SRC" "$OUT" "$SO" "$PREFIX" "$TAG" "$NUM_PODS" "$GLOBAL_PATH" "$IMAGE" <<PY
import os, re, sys
from pathlib import Path

src, out, so, prefix, tag, num_pods_s, global_path, image = sys.argv[1:9]
num_pods = int(num_pods_s)
template = Path(src).read_text().split('---')[0]

def patch_one(idx: int) -> str:
    pod = f"{prefix}-p{idx}"
    local = f"origin_3pod_{tag}_p{idx}"
    text = template.replace('mhw-hami-soft-1split4-a', pod)
    text = text.replace('app: vllm-hami-1split4-a', f'app: {prefix}')
    text = text.replace('/mnt/local/m00953550/FinalTest/New/release', so)
    text = re.sub(r'image: quay\.io/ascend/vllm-ascend:[^\n]+', f'image: {image}', text, count=1)
    text = re.sub(
        r'    huawei\.com/vnpu-mode: hami-core\n(?:\s*#hami\.io/gpu-scheduler-policy:.*\n)?',
        '    huawei.com/vnpu-mode: hami-core\n    hami.io/gpu-scheduler-policy: binpack\n',
        text,
        count=1,
    )
    text = re.sub(r'\n\s*export ASCEND_RT_VISIBLE_DEVICES=\d+', '', text)
    text = re.sub(
        r'        # - name: ASCEND_RT_VISIBLE_DEVICES\n        #   value: "5"\n',
        '',
        text,
    )
    new_exports = f"""          export NPU_FIXED_SHARE_RATIO=1
          export NPU_FCSP_REFILL=1
          export NPU_TOKEN_CHUNK=8
          export NPU_KERNEL_BURST=1
          export NPU_BURST_CONTINUOUS=1
          export NPU_GLOBAL_SHM_PATH="{global_path}"
          export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
          export NPU_LOCAL_SHM_NAME={local}
          export NPU_MEM_QUOTA=16000
          export NPU_PRIORITY=25
          export VXPU_ORIGIN_COMPAT=1
          export VXPU_SYNC_HOOK=0
          rm -f /hami-shared-region/local_shmem/{local} 2>/dev/null || true
          {so}/limiter > {so}/limiter-{pod}.log 2>&1 &
          sleep 10
          echo "=== 开始拉起服务 ==="
"""
    text = re.sub(
        r'export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry"\s*\n'
        r'\s*export NPU_MEM_QUOTA=16000\s*\n'
        r'\s*export NPU_PRIORITY=25[^\n]*\n'
        r'\s*' + re.escape(so) + r'/limiter[^\n]*\n'
        r'(?:\s*# 32768[^\n]*\n)?'
        r'\s*export VXPU_CORE_LIMIT_PERCENT=25\n\s*\n\s*echo "=== 开始拉起服务 ==="',
        new_exports,
        text,
        count=1,
    )
    text = re.sub(r'--gpu-memory-utilization 0\.\d+', f'--gpu-memory-utilization {os.environ.get("GPU_MEM_UTIL", "0.5")}', text)
    text = re.sub(r'--max-num-seqs \d+', '--max-num-seqs 4', text)
    text = re.sub(r'--max_model_len \d+', '--max_model_len 4096', text)
    text = re.sub(r'--max-num-batched-tokens \d+', '--max-num-batched-tokens 4096', text)
    text = re.sub(r'\s*--enforce-eager \\\n', '\n', text)
    text = re.sub(r"\s*--compilation-config '\{[^']+\}' \\\n", '\n', text)
    text = re.sub(
        r'--no-enable-prefix-caching',
        ("--enforce-eager \\\n            --no-enable-prefix-caching" if os.environ.get("ENFORCE_EAGER") == "1" else
         "--compilation-config '{\"cudagraph_mode\": \"FULL_DECODE_ONLY\",\"cudagraph_capture_sizes\":[1,2,4,8,16]}' \\\n"
         '            --no-enable-prefix-caching'),
        text,
        count=1,
    )
    if 'restartPolicy:' not in text:
        text = text.replace('  schedulerName:', '  restartPolicy: Never\n  schedulerName:', 1)
    return text

docs = [patch_one(i) for i in range(num_pods)]
Path(out).write_text('---\n'.join(docs) + '\n')
for i, doc in enumerate(docs):
    Path(f'/tmp/{prefix}-p{i}.yaml').write_text(doc)
print('wrote', out, 'pods=', num_pods)
PY

if [[ "$REGISTRY_CLEANUP" == "1" ]]; then
  echo "cleanup: fresh ${GLOBAL_PATH} and local_shmem"
  pkill -f "${SO}/limiter" 2>/dev/null || true
  rm -f "${GLOBAL_PATH}" /usr/local/hami-shared-region/local_shmem/* 2>/dev/null || true
fi

# cleanup old test pods
for i in 0 1 2 3; do
  kubectl delete pod "${PREFIX}-p${i}" -n default --ignore-not-found --wait=false 2>/dev/null || true
done
sleep 3

# Apply pods one-by-one; wait for vLLM health before stacking next tenant on same card.
wait_k8s_health() {
  local pod=$1
  local deadline=$((SECONDS + 2400))
  while (( SECONDS < deadline )); do
    local ip phase
    ip=$(kubectl get pod "$pod" -n default -o jsonpath='{.status.podIP}' 2>/dev/null || true)
    phase=$(kubectl get pod "$pod" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Failed" || "$phase" == "Error" ]]; then
      echo "FAIL apply ${pod} phase=${phase}" >&2
      kubectl logs "$pod" -n default --tail=20 2>/dev/null || true
      return 1
    fi
    if [[ -n "$ip" ]] && curl -sf --max-time 5 "http://${ip}:8000/health" >/dev/null 2>&1; then
      echo "HEALTH_OK pod=${pod} ip=${ip}"
      return 0
    fi
    sleep 15
  done
  echo "FAIL health timeout ${pod}" >&2
  return 1
}

for ((i=0; i<NUM_PODS; i++)); do
  kubectl apply -f "/tmp/${PREFIX}-p${i}.yaml"
  wait_k8s_health "${PREFIX}-p${i}" || {
    echo "WARN: pod ${PREFIX}-p${i} not healthy, continue stacking" >&2
  }
  sleep 5
done

{
  echo "=== k8s origin 3pod screenshot ${TAG} ==="
  echo "SO=${SO} pods=${NUM_PODS} global=${GLOBAL_PATH}"
  sha256sum "${SO}/libvnpu.so" "${SO}/limiter"
  echo "config: fixed=1 FCSP=1 token_chunk=8 ACL graph max-num-seqs=4"
  echo ""

  declare -a IPS=()
  deadline=$((SECONDS + 2400))
  for ((i=0; i<NUM_PODS; i++)); do
    pod="${PREFIX}-p${i}"
    ip=""
    healthy=0
    while (( SECONDS < deadline )); do
      ip=$(kubectl get pod "$pod" -n default -o jsonpath='{.status.podIP}' 2>/dev/null || true)
      phase=$(kubectl get pod "$pod" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [[ "$phase" == "Failed" || "$phase" == "Error" ]]; then
        echo "FAIL startup ${pod} phase=${phase}"
        kubectl describe pod "$pod" -n default | tail -20
        kubectl logs "$pod" -n default --tail=30 2>/dev/null || true
        break
      fi
      if [[ -n "$ip" ]] && curl -sf --max-time 5 "http://${ip}:8000/health" >/dev/null 2>&1; then
        echo "HEALTH_OK pod=${pod} ip=${ip}"
        hami=$(kubectl get pod "$pod" -n default -o jsonpath='{.metadata.annotations.huawei\.com/Ascend910B3}' 2>/dev/null || echo "")
        [[ -n "$hami" ]] && echo "  hami_alloc=${hami}"
        IPS+=("$ip")
        healthy=1
        break
      fi
      sleep 15
    done
    (( healthy )) || continue
    curl -sf "http://${ip}:8000/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":32}' >/dev/null || true
  done

  echo ""
  echo "--- stress ${STRESS_SEC}s on ${NUM_PODS} pods concurrency=${CONCURRENCY}/pod ---"
  if ((${#IPS[@]} == 0)); then
    echo "SKIP stress: no healthy pods"
  else
    for ((i=0; i<${#IPS[@]}; i++)); do
      stress_pod "${IPS[$i]}" "$i" &
    done
    wait
  fi

  echo ""
  echo "--- shm_broadcast scan ---"
  total_shm=0 total_fatal=0
  for ((i=0; i<NUM_PODS; i++)); do
    pod="${PREFIX}-p${i}"
    shm=$(kubectl logs "$pod" -n default 2>&1 | grep -c "No available shared memory" || true)
    fatal=$(kubectl logs "$pod" -n default 2>&1 | grep -cE "EngineCore.*fatal|sample_tokens timed out" || true)
    total_shm=$((total_shm + shm))
    total_fatal=$((total_fatal + fatal))
    echo "pod${i} name=${pod} shm=${shm} fatal=${fatal}"
    kubectl logs "$pod" -n default 2>&1 | grep "No available shared memory" | tail -3 || true
  done
  echo "TOTAL shm_broadcast=${total_shm} fatal=${total_fatal}"
  [[ "$total_shm" -gt 0 ]] && echo "REPRODUCED shm_broadcast on K8s 3-pod"
  (( ${#IPS[@]} < NUM_PODS )) && echo "WARN: only ${#IPS[@]}/${NUM_PODS} pods healthy"
} 2>&1 | tee "$LOG"
echo "yaml: $OUT"
echo "log: $LOG"
