#!/usr/bin/env bash
# Deploy real K8s repro pod by patching proven hamiNewVllm.yaml (vllm-ascend + HAMi soft).
set -euo pipefail

SRC=/mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
DST=/tmp/vnpu-k8s-kylin-repro.yaml
POD=vnpu-k8s-kylin-repro-p0
SO=/mnt/local/m00953550/FinalTest/kylin/release-optimized
TAG=$(date +%Y%m%d_%H%M%S)
LOG=/mnt/local/m00953550/FinalTest/kylin/logs/k8s_apply_${TAG}.log

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

python3 - "$DST" "$TAG" "$SO" <<'PY'
import sys, re
from pathlib import Path
p, tag, so = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = p.read_text()
gpath = f"/hami-shared-region/global_registry_k8s_repro_{tag}"
lname = f"k8s_repro_{tag}"
inject_sh = Path(so) / f"inject_sitecustomize_{tag}.sh"
inject_body = (
    "#!/bin/bash\n"
    "python3 - <<'PY'\n"
    "import site, pathlib\n"
    "c = '''import os\n"
    f"os.environ.setdefault(\"LD_PRELOAD\", \"{so}/libvnpu.so\")\n"
    f"os.environ.setdefault(\"NPU_GLOBAL_SHM_PATH\", \"{gpath}\")\n"
    "os.environ.setdefault(\"NPU_LOCAL_SHM_DIR\", \"/hami-shared-region/local_shmem\")\n"
    f"os.environ.setdefault(\"NPU_LOCAL_SHM_NAME\", \"{lname}\")\n"
    "os.environ.setdefault(\"NPU_MEM_QUOTA\", \"16000\")\n"
    "os.environ.setdefault(\"NPU_PRIORITY\", \"25\")\n"
    "os.environ.setdefault(\"NPU_KYLIN_LITE\", \"1\")\n"
    "os.environ.setdefault(\"NPU_KYLIN_PRESET\", \"1\")\n"
    "os.environ.setdefault(\"VXPU_SYNC_HOOK\", \"1\")\n"
    "'''\n"
    "for sp in site.getsitepackages():\n"
    "    pathlib.Path(sp, 'sitecustomize.py').write_text(c)\n"
    "print('sitecustomize_ok', site.getsitepackages())\n"
    "PY\n"
)
inject_sh.write_text(inject_body)
inject_sh.chmod(0o755)
text = text.replace(
    '        - name: VLLM_PLATFORM\n          value: ascend',
    '''        - name: VLLM_PLATFORM
          value: ascend
        - name: NPU_KYLIN_LITE
          value: "1"
        - name: NPU_KYLIN_PRESET
          value: "1"
        - name: NPU_LOCAL_SHM_DIR
          value: /hami-shared-region/local_shmem
        - name: NPU_LOCAL_SHM_NAME
          value: ''' + lname + '''
        - name: NPU_GLOBAL_SHM_PATH
          value: ''' + gpath + '''
        - name: NPU_MEM_QUOTA
          value: "16000"
        - name: NPU_PRIORITY
          value: "25"
        - name: NPU_FIXED_SHARE_RATIO
          value: "1"''',
    1,
)
inject_lines = [
    'export NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_KERNEL_BURST=1',
    'export NPU_KYLIN_LITE=1 NPU_KYLIN_PRESET=1 VXPU_SYNC_HOOK=1',
    'export NPU_TOKEN_CHUNK=32',
    'export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem',
    f'export NPU_LOCAL_SHM_NAME={lname}',
]
inject = '\n'.join('          ' + line for line in inject_lines) + '\n'
if "NPU_KYLIN_LITE" not in text:
    text = text.replace('          export NPU_MEM_QUOTA=16000', inject + '          export NPU_MEM_QUOTA=16000', 1)
text = text.replace(
    'limiter.log 2>&1 &\n',
    'limiter.log 2>&1 &\n          sleep 10\n',
    1,
)
site_block = f'\n          bash {so}/inject_sitecustomize_{tag}.sh\n'
text = text.replace(
    '          echo "=== 开始拉起服务 ==="',
    site_block + '\n          echo "=== 开始拉起服务 ==="',
    1,
)
text = text.replace(
    '  schedulerName: hami-scheduler',
    '  restartPolicy: Never\n  schedulerName: hami-scheduler',
    1,
)
p.write_text(text)
pod_only = text.split('---')[0].rstrip() + '\n'
pod_path = p.with_name(p.stem + '-pod-only.yaml')
pod_path.write_text(pod_only)
print('patched', p, 'pod_only', pod_path)
PY

kubectl delete pod "$POD" -n default --ignore-not-found --wait=true
kubectl apply -f "${DST%.yaml}-pod-only.yaml"

{
  echo "=== k8s kylin repro from hamiNewVllm ${TAG} ==="
  sha256sum "${SO}/libvnpu.so" "${SO}/limiter"
  echo "pod=${POD}"
  deadline=$((SECONDS + 1200))
  ip=""
  healthy=0
  while (( SECONDS < deadline )); do
    phase=$(kubectl get pod "$POD" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" == "Failed" ]] && break
    ip=$(kubectl get pod "$POD" -n default -o jsonpath='{.status.podIP}' 2>/dev/null || true)
    if [[ -n "$ip" ]] && curl -sf --max-time 5 "http://${ip}:8000/health" >/dev/null 2>&1; then
      echo "HEALTH_OK ip=${ip}"
      healthy=1
      break
    fi
    sleep 15
  done
  if [[ "$healthy" != "1" ]]; then
    echo "FAIL health pod phase=$(kubectl get pod $POD -n default -o jsonpath='{.status.phase}' 2>/dev/null)"
    kubectl describe pod "$POD" -n default | tail -25
    kubectl logs "$POD" -n default --tail=40 2>&1 || true
    exit 1
  fi
  curl -sf "http://${ip}:8000/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":64}' >/dev/null || true

  echo "--- stress 120s concurrency=8 ---"
  tmpdir=$(mktemp -d)
  start=$(date +%s); reqs=0
  while (( $(date +%s) - start < 120 )); do
    batch=0
    while (( batch < 8 )); do
      rid=$reqs
      (
        resp=$(curl -sf --max-time 120 "http://${ip}:8000/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"压测${rid}\"}],\"max_tokens\":512,\"temperature\":0.01}" 2>/dev/null || echo '')
        tok=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("usage",{}).get("completion_tokens",0))' 2>/dev/null || echo 0)
        echo "$tok" > "${tmpdir}/t${rid}"
      ) &
      reqs=$((reqs + 1)); batch=$((batch + 1))
    done
    wait
  done
  tokens=0
  for f in "${tmpdir}"/t*; do [[ -f "$f" ]] && tokens=$((tokens + $(cat "$f"))); done
  rm -rf "$tmpdir"
  elapsed=$(( $(date +%s) - start ))
  echo "stress reqs=${reqs} tokens=${tokens} tok_s=$(python3 -c "print(f'{$tokens/max($elapsed,1):.2f}')")"

  shm=$(kubectl logs "$POD" -n default 2>&1 | grep -c "No available shared memory" || true)
  fatal=$(kubectl logs "$POD" -n default 2>&1 | grep -cE "EngineCore.*fatal|sample_tokens timed out" || true)
  echo "shm_broadcast=${shm} fatal=${fatal}"
  kubectl get pod "$POD" -n default -o jsonpath='{.metadata.annotations.huawei\.com/Ascend910B3}'; echo
} 2>&1 | tee "$LOG"
echo "log: $LOG"
