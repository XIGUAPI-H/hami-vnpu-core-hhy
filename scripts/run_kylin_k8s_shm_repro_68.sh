#!/usr/bin/env bash
# Real K8s Pod repro for Kylin shm_broadcast / ~0 tok/s (HAMi soft-split, not Docker).
# Usage on 68:
#   SCENARIOS="k8s_online_default k8s_online_aclgraph k8s_2pod" bash run_kylin_k8s_shm_repro_68.sh
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
NS="${K8S_NS:-default}"
NODE="${K8S_NODE:-b04-07-23u-at800t-node-16}"
IMAGE="${KYLIN_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
SO_HOST="${SO_HOST:-/mnt/local/m00953550/FinalTest/kylin/release-optimized}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
SO_REL="${SO_REL:-kylin/release-optimized}"
STRESS_SEC="${STRESS_SEC:-120}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-512}"
VLLM_PORT="${VLLM_PORT:-8000}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/k8s_shm_repro_${TAG}.txt"
PREFIX="vnpu-k8s-shmrepro"

# scenario|pods|kylin_lite|kylin_preset|eager|chunk|sync_hook|token_chunk
DEFAULT_SCENARIOS=(
  "k8s_online_default|1|1|1|1|32|1|32"
  "k8s_online_aclgraph|1|1|1|0|32|1|32"
  "k8s_poda_exact|1|0|0|1|32|0|32"
  "k8s_2pod|2|1|1|1|32|1|32"
  "k8s_4pod|4|1|1|1|32|1|32"
)

if [[ -n "${SCENARIOS:-}" ]]; then
  SCENARIO_LIST=()
  for s in $SCENARIOS; do
    for def in "${DEFAULT_SCENARIOS[@]}"; do
      [[ "$def" == "${s}|"* ]] && SCENARIO_LIST+=("$def") && break
    done
  done
else
  SCENARIO_LIST=("${DEFAULT_SCENARIOS[@]}")
fi

cleanup_scenario() {
  local scen_tag=$1
  kubectl delete pod -n "$NS" -l "shmrepro-tag=${scen_tag}" --wait=false 2>/dev/null || true
  sleep 3
  kubectl delete pod -n "$NS" -l "shmrepro-tag=${scen_tag}" --ignore-not-found --wait=true 2>/dev/null || true
}

pod_ip() {
  local name=$1
  kubectl get pod -n "$NS" "$name" -o jsonpath='{.status.podIP}' 2>/dev/null
}

wait_health() {
  local name=$1 ip phase
  local deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    phase=$(kubectl get pod -n "$NS" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" == "Failed" ]] && return 1
    ip=$(pod_ip "$name")
    if [[ -n "$ip" ]]; then
      curl -sf --max-time 5 "http://${ip}:${VLLM_PORT}/health" >/dev/null 2>&1 && return 0
    fi
    [[ "$phase" == "Unknown" ]] && return 1
    sleep 15
  done
  return 1
}

scen_slug() {
  echo "${1//_/-}"
}

render_pod() {
  local scen=$1 idx=$2 scen_tag=$3
  local kylin_lite=$4 kylin_preset=$5 eager=$6 sync_hook=$7 token_chunk=$8
  local global=$9
  local slug
  slug=$(scen_slug "$scen")
  local name="${PREFIX}-${slug}-p${idx}"
  local local_name="k8s_shmrepro_${slug}_p${idx}_${scen_tag}"
  local eager_flag="" compile_disable=1
  if [[ "$eager" == "1" ]]; then
    eager_flag="'--enforce-eager',"
    compile_disable=1
  else
    compile_disable=0
  fi

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app: ${PREFIX}
    shmrepro-scenario: ${slug}
    shmrepro-tag: ${scen_tag}
    shmrepro-index: "${idx}"
  annotations:
    huawei.com/vnpu-mode: hami-core
    hami.io/gpu-scheduler-policy: binpack
spec:
  schedulerName: hami-scheduler
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  tolerations:
    - operator: Exists
  volumes:
    - name: vnpu-so
      hostPath: { path: ${SO_HOST} }
    - name: ft-root
      hostPath: { path: ${FT} }
    - name: model-storage
      hostPath: { path: ${MODEL}, type: Directory }
    - name: ms-conda
      hostPath: { path: ${KY}/ms-conda }
    - name: vllm-ws
      hostPath: { path: ${VLLM_WS} }
    - name: py-site
      hostPath: { path: ${PY_SITE} }
    - name: ascend-driver
      hostPath: { path: /usr/local/Ascend/driver }
    - name: ascend-firmware
      hostPath: { path: /usr/local/Ascend/firmware }
    - name: ascend-toolkit
      hostPath: { path: /usr/local/Ascend/ascend-toolkit }
    - name: ascend-nnal
      hostPath: { path: /usr/local/Ascend/nnal }
    - name: hccn-conf
      hostPath: { path: /etc/hccn.conf }
    - name: dcmi
      hostPath: { path: /usr/local/dcmi }
    - name: ascend-toolbox
      hostPath: { path: /usr/local/Ascend/toolbox }
    - name: var-log-npu
      hostPath: { path: /var/log/npu/ }
    - name: xpu-bin
      hostPath: { path: /opt/xpu/bin }
    - name: xpu-lib
      hostPath: { path: /opt/xpu/lib }
    - name: xpu-log
      hostPath: { path: /var/log/xpu }
    - name: xpu-sock
      hostPath: { path: /var/lib/xpu, type: DirectoryOrCreate }
    - name: ascend-manager
      hostPath: { path: /dev/davinci_manager }
    - name: devmm-svm
      hostPath: { path: /dev/devmm_svm }
    - name: hisi-hdc
      hostPath: { path: /dev/hisi_hdc }
    - name: dshm
      emptyDir: { medium: Memory, sizeLimit: 8Gi }
  containers:
    - name: vllm
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
      env:
        - name: LD_PRELOAD
          value: ${SO_HOST}/libvnpu.so
        - name: LD_LIBRARY_PATH
          value: /usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64/plugin/opskernel:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:/opt/xpu/lib
        - name: VLLM_PLATFORM
          value: ascend
        - name: ASCEND_RT_VISIBLE_DEVICES
          value: "0"
        - name: ASCEND_VISIBLE_DEVICES
          value: "0"
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -eo pipefail
          rm -rf /tmp/ms-run && cp -a /opt/ms-conda /tmp/ms-run
          export LD_LIBRARY_PATH=/tmp/ms-run/lib:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/nnae/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/lib64
          export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
          source /usr/local/Ascend/nnal/atb/set_env.sh
          export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site
          export ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest
          export LD_PRELOAD=${SO_HOST}/libvnpu.so
          export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=1
          export NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50
          export NPU_TOKEN_CHUNK=${token_chunk} NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
          export NPU_KYLIN_PRESET=${kylin_preset} NPU_KYLIN_LITE=${kylin_lite}
          export VXPU_ORIGIN_COMPAT=0 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=${sync_hook}
          export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0 NPU_MEMINFO_STARTUP_CACHE=0
          export NPU_GLOBAL_SHM_PATH=${global}
          export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
          export NPU_LOCAL_SHM_NAME=${local_name}
          export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
          export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
          export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=${compile_disable}
          export RUST_LOG=info
          mkdir -p /hami-shared-region/local_shmem /opt/ft/kylin/logs
          rm -f /hami-shared-region/local_shmem/${local_name} 2>/dev/null || true
          TRITON=/tmp/ms-run/lib/python3.10/site-packages/triton
          [[ -d "\$TRITON" ]] && mv "\$TRITON" "\${TRITON}.disabled" || true
          ${SO_HOST}/limiter > /opt/ft/kylin/logs/limiter-k8s-${scen}-p${idx}-${scen_tag}.log 2>&1 &
          sleep 3
          /tmp/ms-run/bin/python -c 'import torch,torch_npu; import acl; print("stack_ok")' || exit 1
          exec /tmp/ms-run/bin/python -c "
          import sys, runpy
          sys.path.insert(0, '/opt/py310-site')
          sys.argv = [
            'api_server', '--model=/models', '--trust-remote-code',
            '--distributed-executor-backend', 'mp', '--tensor-parallel-size', '1',
            '--pipeline-parallel-size', '1', '--disable-frontend-multiprocessing',
            '--port', '${VLLM_PORT}', '--host', '0.0.0.0',
            '--gpu-memory-utilization', '0.5', '--max-num-seqs', '8',
            '--served-model-name', 'qwen3', '--dtype', 'bfloat16',
            '--max_model_len', '4096', '--max-num-batched-tokens', '4096',
            '--enable-auto-tool-choice', '--tool-call-parser', 'hermes',
            '--no-enable_expert_parallel', '--block-size', '128',
            '--async-scheduling', '--distributed_executor_backend', 'mp',
            ${eager_flag}
            '--no-enable-prefix-caching',
          ]
          runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
          "
      resources:
        limits:
          huawei.com/Ascend910B3: "1"
          huawei.com/Ascend910B3-core: "25"
          huawei.com/Ascend910B3-memory: "16000"
        requests:
          huawei.com/Ascend910B3: "1"
          huawei.com/Ascend910B3-core: "25"
          huawei.com/Ascend910B3-memory: "16000"
      volumeMounts:
        - { name: vnpu-so, mountPath: ${SO_HOST} }
        - { name: ft-root, mountPath: /opt/ft }
        - { name: model-storage, mountPath: /models, readOnly: true }
        - { name: ms-conda, mountPath: /opt/ms-conda, readOnly: true }
        - { name: vllm-ws, mountPath: /vllm-workspace, readOnly: true }
        - { name: py-site, mountPath: /opt/py310-site, readOnly: true }
        - { name: ascend-driver, mountPath: /usr/local/Ascend/driver, readOnly: true }
        - { name: ascend-firmware, mountPath: /usr/local/Ascend/firmware, readOnly: true }
        - { name: ascend-toolkit, mountPath: /usr/local/Ascend/ascend-toolkit, readOnly: true }
        - { name: ascend-nnal, mountPath: /usr/local/Ascend/nnal, readOnly: true }
        - { name: hccn-conf, mountPath: /etc/hccn.conf, readOnly: true }
        - { name: dcmi, mountPath: /usr/local/dcmi, readOnly: true }
        - { name: ascend-toolbox, mountPath: /usr/local/Ascend/toolbox, readOnly: true }
        - { name: var-log-npu, mountPath: /var/log/npu, readOnly: true }
        - { name: xpu-bin, mountPath: /opt/xpu/bin }
        - { name: xpu-sock, mountPath: /var/lib/xpu }
        - { name: xpu-lib, mountPath: /opt/xpu/lib }
        - { name: xpu-log, mountPath: /var/log/xpu }
        - { name: ascend-manager, mountPath: /dev/davinci_manager }
        - { name: devmm-svm, mountPath: /dev/devmm_svm }
        - { name: hisi-hdc, mountPath: /dev/hisi_hdc }
        - { name: dshm, mountPath: /dev/shm }
EOF
}

stress_pod() {
  local ip=$1 duration=$2 label=$3
  local tmpdir start end tokens=0 reqs=0
  tmpdir=$(mktemp -d)
  start=$(date +%s)
  while (( $(date +%s) - start < duration )); do
    local batch=0
    while (( batch < CONCURRENCY )); do
      local rid=$reqs
      (
        resp=$(curl -sf --max-time 120 "http://${ip}:${VLLM_PORT}/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"压测${rid}\"}],\"max_tokens\":${MAX_TOKENS},\"temperature\":0.01}" 2>/dev/null || echo '')
        tok=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("usage",{}).get("completion_tokens",0))' 2>/dev/null || echo 0)
        echo "$tok" > "${tmpdir}/t${rid}"
      ) &
      reqs=$((reqs + 1))
      batch=$((batch + 1))
    done
    wait
  done
  end=$(date +%s)
  for f in "${tmpdir}"/t*; do
    [[ -f "$f" ]] || continue
    tokens=$((tokens + $(cat "$f")))
  done
  rm -rf "$tmpdir"
  local elapsed=$((end - start))
  local tps
  tps=$(python3 -c "print(f'{$tokens/max($elapsed,1):.2f}')")
  echo "pod=${label} ip=${ip} duration=${elapsed}s reqs=${reqs} tokens=${tokens} tok_s=${tps}"
}

scan_logs() {
  local scen=$1 pods=$2 scen_tag=$3
  local shm=0 fatal=0
  local slug
  slug=$(scen_slug "$scen")
  for ((i=0; i<pods; i++)); do
    local name="${PREFIX}-${slug}-p${i}"
    local s f
    s=$(kubectl logs -n "$NS" "$name" 2>&1 | grep -c "No available shared memory" || true)
    f=$(kubectl logs -n "$NS" "$name" 2>&1 | grep -cE "EngineCore.*fatal|EngineCore proc.*died|sample_tokens timed out" || true)
    shm=$((shm + s))
    fatal=$((fatal + f))
    echo "  pod${i} (${name}) shm_broadcast=${s} fatal=${f}"
    local hami
    hami=$(kubectl get pod -n "$NS" "$name" -o jsonpath='{.metadata.annotations.huawei\.com/Ascend910B3}' 2>/dev/null || echo "")
    [[ -n "$hami" ]] && echo "  pod${i} hami_alloc=${hami}"
  done
  echo "  TOTAL shm=${shm} fatal=${fatal}"
  [[ "$shm" -gt 0 ]] && echo "  >>> REPRODUCED shm_broadcast in K8s Pod"
}

mkdir -p "${KY}/logs"
{
  echo "=== K8s Pod shm repro ${TAG} ==="
  echo "NS=${NS} NODE=${NODE} SO=${SO_REL} STRESS_SEC=${STRESS_SEC} CONCURRENCY=${CONCURRENCY}"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo ""

  # Stop leftover Docker repro containers that bypass HAMi on the same node.
  docker ps -aq --filter "name=vnpu-shmrepro-" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker ps -aq --filter "name=vnpu-4pod-" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true

  for spec in "${SCENARIO_LIST[@]}"; do
    IFS='|' read -r scen pods kylin_lite kylin_preset eager chunk sync_hook token_chunk <<< "$spec"
    scen_tag="${TAG}_$(scen_slug "$scen")"
    slug=$(scen_slug "$scen")
    global="/hami-shared-region/global_registry_k8s_shmrepro_${scen_tag}"
    cleanup_scenario "$scen_tag"
    echo ">>> scenario=${scen} pods=${pods} kylin_lite=${kylin_lite} preset=${kylin_preset} eager=${eager} sync_hook=${sync_hook} token_chunk=${token_chunk}"

    for ((i=0; i<pods; i++)); do
      render_pod "$scen" "$i" "$scen_tag" \
        "$kylin_lite" "$kylin_preset" "$eager" "$sync_hook" "$token_chunk" "$global" \
        | kubectl apply -f -
    done

    declare -a POD_IPS=()
    for ((i=0; i<pods; i++)); do
      local_name="${PREFIX}-${slug}-p${i}"
      if ! wait_health "$local_name"; then
        echo "FAIL startup ${local_name}"
        kubectl describe pod -n "$NS" "$local_name" 2>&1 | tail -30
        kubectl logs -n "$NS" "$local_name" 2>&1 | tail -40
        scan_logs "$scen" "$pods" "$scen_tag"
        [[ "${KEEP_POD_ON_FAIL:-0}" == "1" ]] || cleanup_scenario "$scen_tag"
        continue 2
      fi
      ip=$(pod_ip "$local_name")
      POD_IPS+=("$ip")
      curl -sf "http://${ip}:${VLLM_PORT}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":64}' >/dev/null || true
      echo "  pod${i} ready ip=${ip}"
    done

    echo "--- stress ${STRESS_SEC}s concurrent on ${pods} K8s pod(s) ---"
    for ((i=0; i<pods; i++)); do
      stress_pod "${POD_IPS[$i]}" "$STRESS_SEC" "p${i}" &
    done
    wait
    scan_logs "$scen" "$pods" "$scen_tag"
    cleanup_scenario "$scen_tag"
    echo ""
  done
} 2>&1 | tee "$REPORT"
echo "report: $REPORT"
