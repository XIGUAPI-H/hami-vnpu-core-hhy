#!/usr/bin/env bash
# Docker fallback: 3 pods same NPU card, screenshot podA + origin lib (K8s scheduler blocked).
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
IMAGE="${KYLIN_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
SO_REL="${SO_REL:-kylin/release-origin}"
SHM_SIZE="${SHM_SIZE:-32g}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-1}"
NUM_PODS="${NUM_PODS:-3}"
STRESS_SEC="${STRESS_SEC:-300}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-512}"
TAG="$(date +%Y%m%d_%H%M%S)"
GLOBAL="/hami-shared-region/global_registry"
REPORT="${KY}/logs/docker_origin_3pod_${TAG}.txt"
BASE_PORT=18301

cleanup() {
  docker ps -aq --filter "name=vnpu-origin-3pod-" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

launch_pod() {
  local idx=$1 port=$2
  local name="vnpu-origin-3pod-p${idx}-${TAG}"
  local local="origin_docker_3pod_${TAG}_p${idx}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -f "${HAMi_SHM}/local_shmem/${local}" 2>/dev/null || true
  docker run -d --name "$name" --privileged --network host --shm-size="${SHM_SIZE}" \
    -e ASCEND_RT_VISIBLE_DEVICES="${NPU}" -e VLLM_PLATFORM=ascend \
    -e LD_PRELOAD="/opt/ft/${SO_REL}/libvnpu.so" \
    -v "${FT}:/opt/ft" -v "${MODEL}:/models:ro" \
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
    -v /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v "${HAMi_SHM}:/hami-shared-region" \
    -v /dev/davinci_manager:/dev/davinci_manager \
    -v /dev/devmm_svm:/dev/devmm_svm -v /dev/hisi_hdc:/dev/hisi_hdc \
    "$IMAGE" bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/nnae/latest/lib64:\$LD_LIBRARY_PATH
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/nnal/atb/set_env.sh
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2
export NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_TOKEN_CHUNK=8
export NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
export NPU_GLOBAL_SHM_PATH=${GLOBAL}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
export NPU_LOCAL_SHM_NAME=${local}
export VXPU_ORIGIN_COMPAT=1 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
rm -f /hami-shared-region/local_shmem/${local} 2>/dev/null || true
df -h /dev/shm
/opt/ft/${SO_REL}/limiter > /opt/ft/kylin/logs/limiter-${name}.log 2>&1 &
sleep 10
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port ${port} --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 --max-num-seqs 4 --served-model-name qwen3 --dtype bfloat16 \
  --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --compilation-config '{\"cudagraph_mode\": \"FULL_DECODE_ONLY\",\"cudagraph_capture_sizes\":[1,2,4,8,16]}' \
  --no-enable-prefix-caching
"
}

wait_health() {
  local port=$1 name=$2
  local deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
    docker ps --format '{{.Names}}' | grep -qx "$name" || return 1
    sleep 10
  done
  return 1
}

stress_port() {
  local port=$1 pid=$2
  local tmp start reqs=0 tok=0 el
  tmp=$(mktemp -d); start=$(date +%s)
  while (( $(date +%s) - start < STRESS_SEC )); do
    for ((b=0; b<CONCURRENCY; b++)); do
      local rid=$reqs
      ( curl -sf --max-time 180 "http://127.0.0.1:${port}/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"p${pid}t${rid}\"}],\"max_tokens\":${MAX_TOKENS}}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("usage",{}).get("completion_tokens",0))' \
          > "${tmp}/t${rid}" 2>/dev/null || echo 0 > "${tmp}/t${rid}" ) &
      reqs=$((reqs+1))
    done
    wait
  done
  for f in "${tmp}"/t*; do [[ -f "$f" ]] && tok=$((tok+$(cat "$f"))); done
  rm -rf "$tmp"
  el=$(( $(date +%s) - start ))
  echo "pod${pid} port=${port} reqs=${reqs} tokens=${tok} tok_s=$(python3 -c "print(f'{$tok/max($el,1):.2f}')")"
}

cleanup
mkdir -p "${KY}/logs"
{
  echo "=== docker origin 3pod screenshot ${TAG} ==="
  echo "NPU=${NPU} SO=${SO_REL} shm=${SHM_SIZE} global=${GLOBAL}"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  for ((i=0; i<NUM_PODS; i++)); do
    launch_pod "$i" "$((BASE_PORT+i))"
    wait_health "$((BASE_PORT+i))" "vnpu-origin-3pod-p${i}-${TAG}" || {
      echo "FAIL startup p${i}"; docker logs "vnpu-origin-3pod-p${i}-${TAG}" 2>&1 | tail -40; exit 1
    }
    echo "HEALTH_OK p${i} port=$((BASE_PORT+i))"
  done
  echo "--- stress ${STRESS_SEC}s on ${NUM_PODS} pods ---"
  for ((i=0; i<NUM_PODS; i++)); do stress_port "$((BASE_PORT+i))" "$i" & done
  wait
  total_shm=0
  for ((i=0; i<NUM_PODS; i++)); do
    n="vnpu-origin-3pod-p${i}-${TAG}"
    s=$(docker logs "$n" 2>&1 | grep -c "No available shared memory" || true)
    total_shm=$((total_shm+s))
    echo "p${i} shm_broadcast=${s}"
    docker logs "$n" 2>&1 | grep "No available shared memory" | tail -2 || true
  done
  echo "TOTAL shm_broadcast=${total_shm}"
  [[ "$total_shm" -gt 0 ]] && echo "REPRODUCED shm_broadcast"
} 2>&1 | tee "$REPORT"
echo "report: $REPORT"
