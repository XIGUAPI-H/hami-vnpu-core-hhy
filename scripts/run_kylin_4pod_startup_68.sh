#!/usr/bin/env bash
# Verify 4 vLLM pods can start on one physical NPU (serial health, shared global registry).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
SO_REL="${SO_REL:-kylin/release-optimized}"
NUM_PODS="${NUM_PODS:-4}"
MEM_QUOTA="${NPU_MEM_QUOTA:-12000}"
PRIORITY="${NPU_PRIORITY:-25}"
FIXED_SHARE="${NPU_FIXED_SHARE_RATIO:-1}"
FCSP_REFILL="${NPU_FCSP_REFILL:-1}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.35}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
TAG="$(date +%Y%m%d_%H%M%S)"
GLOBAL_PATH="/hami-shared-region/global_registry_4pod_${TAG}"
REPORT="${KY}/logs/4pod_startup_${TAG}.txt"
BASE_PORT=18141

mkdir -p "${KY}/logs"

cleanup() {
  docker ps -aq --filter 'name=vnpu-4pod-' | xargs -r docker rm -f >/dev/null 2>&1 || true
}

wait_health() {
  local port=$1 name=$2
  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "health_ok ${name} :${port} elapsed=$((SECONDS))s"
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      echo "FAIL container exited: ${name}" >&2
      docker logs "${name}" 2>&1 | tail -60 >&2 || true
      return 1
    fi
    sleep 10
  done
  echo "FAIL health timeout: ${name}" >&2
  docker logs "${name}" 2>&1 | tail -60 >&2 || true
  return 1
}

launch_pod() {
  local idx=$1
  local port=$((BASE_PORT + idx))
  local name="vnpu-4pod-${idx}-${TAG}"
  local local_name="vnpu_4pod_${idx}_${TAG}"
  local lim="/opt/ft/${SO_REL}/limiter > /opt/ft/kylin/logs/limiter-4pod-${idx}-${TAG}.log 2>&1 & sleep 3"

  docker rm -f "${name}" >/dev/null 2>&1 || true
  rm -f "${HAMi_SHM}/local_shmem/${local_name}" 2>/dev/null || true

  docker run -d --name "${name}" --privileged --network host \
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
    "${IMAGE}" \
    bash -c "set -eo pipefail
rm -rf /tmp/ms-run && cp -a /opt/ms-conda /tmp/ms-run
export LD_LIBRARY_PATH=/tmp/ms-run/lib:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/lib64
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site:/usr/local/Ascend/ascend-toolkit/latest/python/site-packages
export ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest
export LD_PRELOAD=/opt/ft/${SO_REL}/libvnpu.so
export NPU_MEM_QUOTA=${MEM_QUOTA} NPU_PRIORITY=${PRIORITY} NPU_FIXED_SHARE_RATIO=${FIXED_SHARE}
export NPU_FCSP_REFILL=${FCSP_REFILL} NPU_TOKEN_CHUNK=8 NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1
export NPU_KYLIN_PRESET=0 NPU_KYLIN_LITE=0
export VXPU_ORIGIN_COMPAT=0 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_GLOBAL_SHM_PATH=${GLOBAL_PATH}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
export NPU_LOCAL_SHM_NAME=${local_name}
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
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
  '--gpu-memory-utilization', '${GPU_MEM_UTIL}', '--max-num-seqs', '${MAX_NUM_SEQS}',
  '--served-model-name', 'qwen3', '--dtype', 'bfloat16',
  '--max_model_len', '4096', '--max-num-batched-tokens', '4096',
  '--enable-auto-tool-choice', '--tool-call-parser', 'hermes',
  '--no-enable_expert_parallel', '--block-size', '128',
  '--async-scheduling', '--distributed_executor_backend', 'mp',
  '--enforce-eager', '--no-enable-prefix-caching',
]
runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
\"
"
  echo "launched ${name} port=${port} local=${local_name}"
}

trap cleanup EXIT
cleanup

{
  echo "=== 4-pod same-card startup ${TAG} ==="
  echo "NPU=${NPU} pods=${NUM_PODS} SO=${SO_REL}"
  echo "global=${GLOBAL_PATH}"
  echo "mem_quota=${MEM_QUOTA} priority=${PRIORITY} fixed=${FIXED_SHARE} fcsp=${FCSP_REFILL}"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo ""

  ok=0
  for ((i=0; i<NUM_PODS; i++)); do
    echo ">>> launch pod ${i}"
    launch_pod "${i}"
    if wait_health "$((BASE_PORT + i))" "vnpu-4pod-${i}-${TAG}"; then
      ok=$((ok + 1))
      echo "pod ${i}: PASS"
    else
      echo "pod ${i}: FAIL"
      echo "RESULT: ${ok}/${NUM_PODS} healthy before failure"
      exit 1
    fi
    echo ""
  done

  echo "=== final health check ==="
  for ((i=0; i<NUM_PODS; i++)); do
    port=$((BASE_PORT + i))
    if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "pod ${i} :${port} OK"
    else
      echo "pod ${i} :${port} FAIL"
      exit 1
    fi
  done

  echo ""
  echo "RESULT: ALL ${NUM_PODS} pods healthy on NPU ${NPU}"
  docker ps --filter "name=vnpu-4pod-.*${TAG}" --format '{{.Names}} {{.Status}}'
} 2>&1 | tee "${REPORT}"

echo "report: ${REPORT}"
