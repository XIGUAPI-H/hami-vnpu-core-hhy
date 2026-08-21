#!/usr/bin/env bash
# Reproduce online Kylin shm_broadcast + ~0 tok/s: sweep prod-like env combos.
# Usage: SCENARIOS="online_default online_aclgraph poda_2pod" bash run_kylin_online_shm_repro_68.sh
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
UB="${FT}/ubuntu"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
SO_REL="${SO_REL:-kylin/release-optimized}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-1}"
STRESS_SEC="${STRESS_SEC:-180}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-512}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/online_shm_repro_${TAG}.txt"

# scenario|pods|kylin_lite|kylin_preset|eager|chunk|sync_hook|token_chunk|extra
DEFAULT_SCENARIOS=(
  "online_default|1|1|1|1|1|1|32|"
  "online_aclgraph|1|1|1|0|1|1|32|"
  "poda_exact|1|0|0|1|0|0|32|"
  "poda_aclgraph|1|0|0|0|0|0|32|"
  "online_2pod|2|1|1|1|1|1|32|"
  "poda_2pod|2|0|0|1|0|0|32|"
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
  local tag=$1
  docker ps -aq --filter "name=vnpu-shmrepro-.*-${tag}" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

wait_health() {
  local port=$1 name=$2
  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
    docker ps --format '{{.Names}}' | grep -qx "$name" || return 1
    sleep 10
  done
  return 1
}

launch_pod() {
  local scen=$1 idx=$2 tag=$3 port=$4 global=$5
  local kylin_lite=$6 kylin_preset=$7 eager=$8 sync_hook=$9 chunk=$10
  local name="vnpu-shmrepro-${scen}-p${idx}-${tag}"
  local local_name="shmrepro_${scen}_p${idx}_${tag}"
  local lim="/opt/ft/${SO_REL}/limiter > /opt/ft/kylin/logs/limiter-shmrepro-${scen}-p${idx}-${tag}.log 2>&1 & sleep 3"
  local eager_flag="" compile_disable=1
  if [[ "$eager" == "1" ]]; then
    eager_flag="'--enforce-eager',"
    compile_disable=1
  else
    eager_flag=""
    compile_disable=0
  fi

  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -f "${HAMi_SHM}/local_shmem/${local_name}" 2>/dev/null || true

  docker run -d --name "$name" --privileged --network host --shm-size=8g \
    -e ASCEND_RT_VISIBLE_DEVICES="${NPU}" \
    -e VLLM_PLATFORM=ascend \
    -v "${FT}:/opt/ft" \
    -v "${MODEL}:/models:ro" \
    -v "${KY}/ms-conda:/opt/ms-conda:ro" \
    -v "${VLLM_WS}:/vllm-workspace:ro" \
    -v "${PY_SITE}:/opt/py310-site:ro" \
    -v /usr/local/Ascend:/usr/local/Ascend:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v "${HAMi_SHM}:/hami-shared-region" \
    -v /dev/davinci_manager:/dev/davinci_manager \
    -v /dev/devmm_svm:/dev/devmm_svm \
    -v /dev/hisi_hdc:/dev/hisi_hdc \
    "$IMAGE" \
    bash -c "set -eo pipefail
rm -rf /tmp/ms-run && cp -a /opt/ms-conda /tmp/ms-run
export LD_LIBRARY_PATH=/tmp/ms-run/lib:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/lib64
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site:/usr/local/Ascend/ascend-toolkit/latest/python/site-packages
export ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest
export LD_PRELOAD=/opt/ft/${SO_REL}/libvnpu.so
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=1
export NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50
export NPU_TOKEN_CHUNK=${chunk} NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
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
TRITON=/tmp/ms-run/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON\" ]] && mv \"\$TRITON\" \"\${TRITON}.disabled\" || true
${lim}
/tmp/ms-run/bin/python -c 'import torch,torch_npu; import acl; print(\"stack_ok\")' || exit 1
exec /tmp/ms-run/bin/python -c \"
import sys, runpy
sys.path.insert(0, '/opt/py310-site')
sys.argv = [
  'api_server', '--model=/models', '--trust-remote-code',
  '--distributed-executor-backend', 'mp', '--tensor-parallel-size', '1',
  '--pipeline-parallel-size', '1', '--disable-frontend-multiprocessing',
  '--port', '${port}', '--host', '0.0.0.0',
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
\"
"
}

stress_port() {
  local port=$1 duration=$2
  local tmpdir start end tokens=0 reqs=0
  tmpdir=$(mktemp -d)
  start=$(date +%s)
  while (( $(date +%s) - start < duration )); do
    local batch=0
    while (( batch < CONCURRENCY )); do
      local rid=$reqs
      (
        resp=$(curl -sf --max-time 120 "http://127.0.0.1:${port}/v1/chat/completions" \
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
  echo "port=${port} duration=${elapsed}s reqs=${reqs} tokens=${tokens} tok_s=${tps}"
}

scan_logs() {
  local scen=$1 pods=$2 tag=$3
  local shm=0 fatal=0 slow=0
  for ((i=0; i<pods; i++)); do
    local name="vnpu-shmrepro-${scen}-p${i}-${tag}"
    local s f
    s=$(docker logs "$name" 2>&1 | grep -c "No available shared memory" || true)
    f=$(docker logs "$name" 2>&1 | grep -cE "EngineCore.*fatal|EngineCore proc.*died|sample_tokens timed out" || true)
    shm=$((shm + s))
    fatal=$((fatal + f))
    echo "  pod${i} shm_broadcast=${s} fatal=${f}"
  done
  echo "  TOTAL shm=${shm} fatal=${fatal}"
  [[ "$shm" -gt 0 ]] && echo "  >>> REPRODUCED shm_broadcast"
}

mkdir -p "${KY}/logs"
{
  echo "=== online shm repro ${TAG} ==="
  echo "NPU=${NPU} SO=${SO_REL} STRESS_SEC=${STRESS_SEC} CONCURRENCY=${CONCURRENCY}"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo ""

  for spec in "${SCENARIO_LIST[@]}"; do
    IFS='|' read -r scen pods kylin_lite kylin_preset eager sync_hook chunk _ <<< "$spec"
    scen_tag="${TAG}_${scen}"
    global="/hami-shared-region/global_registry_shmrepro_${scen_tag}"
    base_port=18201
    cleanup_scenario "$scen_tag"
    echo ">>> scenario=${scen} pods=${pods} kylin_lite=${kylin_lite} preset=${kylin_preset} eager=${eager} sync_hook=${sync_hook} chunk=${chunk}"

    for ((i=0; i<pods; i++)); do
      launch_pod "$scen" "$i" "$scen_tag" "$((base_port+i))" "$global" \
        "$kylin_lite" "$kylin_preset" "$eager" "$sync_hook" "$chunk"
      wait_health "$((base_port+i))" "vnpu-shmrepro-${scen}-p${i}-${scen_tag}" || {
        echo "FAIL startup pod${i}"
        scan_logs "$scen" "$pods" "$scen_tag"
        continue 2
      }
      curl -sf "http://127.0.0.1:$((base_port+i))/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":64}' >/dev/null || true
    done

    echo "--- stress ${STRESS_SEC}s concurrent on ${pods} pod(s) ---"
    for ((i=0; i<pods; i++)); do
      stress_port "$((base_port+i))" "$STRESS_SEC" &
    done
    wait
    scan_logs "$scen" "$pods" "$scen_tag"
    cleanup_scenario "$scen_tag"
    echo ""
  done
} 2>&1 | tee "$REPORT"
echo "report: $REPORT"
