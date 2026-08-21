#!/usr/bin/env bash
# Card 1: 4 vLLM containers (shared global registry) + concurrent aisbench stress.
# Checks for shm_broadcast / EngineCore fatal during pressure.
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
UB="${FT}/ubuntu"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-1}"
SO_REL="${SO_REL:-kylin/release-optimized}"
NUM_PODS="${NUM_PODS:-4}"
MEM_QUOTA="${NPU_MEM_QUOTA:-16000}"
PRIORITY="${NPU_PRIORITY:-25}"
FIXED_SHARE="${NPU_FIXED_SHARE_RATIO:-1}"
FCSP_REFILL="${NPU_FCSP_REFILL:-1}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
NUM_PROMPTS="${NUM_PROMPTS:-32}"
CONCURRENCY="${CONCURRENCY:-8}"
BATCH_SIZE="${BATCH_SIZE:-8}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-0}"
TAG="$(date +%Y%m%d_%H%M%S)"
GLOBAL_PATH="/hami-shared-region/global_registry_4pod_card${NPU}_${TAG}"
REPORT="${KY}/logs/4pod_aisbench_card${NPU}_${TAG}.txt"
BASE_PORT=18151

mkdir -p "${KY}/logs"

cleanup() {
  [[ "${KEEP_CONTAINERS}" == "1" ]] && return 0
  docker ps -aq --filter "name=vnpu-4pod-.*${TAG}" | xargs -r docker rm -f >/dev/null 2>&1 || true
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
      docker logs "${name}" 2>&1 | tail -80 >&2 || true
      return 1
    fi
    sleep 10
  done
  echo "FAIL health timeout: ${name}" >&2
  docker logs "${name}" 2>&1 | tail -80 >&2 || true
  return 1
}

launch_pod() {
  local idx=$1
  local port=$((BASE_PORT + idx))
  local name="vnpu-4pod-${idx}-${TAG}"
  local local_name="vnpu_4pod_c${NPU}_${idx}_${TAG}"
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
export NPU_FCSP_REFILL=${FCSP_REFILL} NPU_FCSP_REFILL_INTERVAL_US=50
export NPU_TOKEN_CHUNK=8 NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
export NPU_KYLIN_PRESET=0 NPU_KYLIN_LITE=0
export VXPU_ORIGIN_COMPAT=0 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0 NPU_MEMINFO_STARTUP_CACHE=0
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

warmup_pod() {
  local port=$1
  curl -sf "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":64,"temperature":0.01}' >/dev/null || true
}

run_bench_pod() {
  local idx=$1
  local port=$((BASE_PORT + idx))
  local name="vnpu-4pod-${idx}-${TAG}"
  local out_tag="4pod_c${NPU}_p${idx}_${TAG}"
  local log="${KY}/logs/aisbench_4pod_p${idx}_${TAG}.log"
  set +e
  # Host aisbench often segfaults (rc=139); use HTTP-only container sidecar.
  OUT_TAG="${out_tag}" VLLM_CONTAINER="${name}" VLLM_PORT="${port}" \
    NUM_PROMPTS="${NUM_PROMPTS}" AISBENCH_CONCURRENCY="${CONCURRENCY}" \
    MAX_OUT_LEN="${MAX_OUT_LEN}" \
    bash "${OE}/aisbench_perf_openeuler_container.sh" >"${log}" 2>&1
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    OUT_TAG="${out_tag}" VLLM_PORT="${port}" NUM_PROMPTS="${NUM_PROMPTS}" \
      CONCURRENCY="${CONCURRENCY}" BATCH_SIZE="${BATCH_SIZE}" MAX_OUT_LEN="${MAX_OUT_LEN}" \
      bash "${UB}/aisbench_perf_ubuntu.sh" >>"${log}" 2>&1
    rc=$?
  fi
  set -e
  echo "aisbench_pod${idx} rc=${rc} log=${log}"
  return "${rc}"
}

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

scan_crash_signals() {
  local label=$1
  echo "=== crash scan: ${label} ==="
  local total_shm=0 total_fatal=0 total_assert=0
  for ((i=0; i<NUM_PODS; i++)); do
    local name="vnpu-4pod-${i}-${TAG}"
    local shm fatal assert
    shm=$(docker logs "${name}" 2>&1 | grep -c "No available shared memory" || true)
    fatal=$(docker logs "${name}" 2>&1 | grep -c "EngineCore.*fatal\|EngineCore proc.*died" || true)
    assert=$(docker logs "${name}" 2>&1 | grep -c "AssertionError.*memory profiling" || true)
    total_shm=$((total_shm + shm))
    total_fatal=$((total_fatal + fatal))
    total_assert=$((total_assert + assert))
    echo "pod${i} ${name}: shm_broadcast=${shm} engine_fatal=${fatal} mem_profile_assert=${assert}"
  done
  echo "TOTAL: shm_broadcast=${total_shm} engine_fatal=${total_fatal} mem_profile_assert=${total_assert}"
  if [[ "${total_shm}" -eq 0 && "${total_fatal}" -eq 0 && "${total_assert}" -eq 0 ]]; then
    echo "PASS: no shm_broadcast / fatal / profiling assert detected"
  else
    echo "WARN: crash signals detected — see container logs"
  fi
}

trap cleanup EXIT

{
  echo "=== 4-pod aisbench card${NPU} ${TAG} ==="
  echo "SO=${SO_REL} global=${GLOBAL_PATH}"
  echo "mem_quota=${MEM_QUOTA} gpu_mem_util=${GPU_MEM_UTIL} priority=${PRIORITY} fixed=${FIXED_SHARE} fcsp=${FCSP_REFILL}"
  echo "aisbench: prompts=${NUM_PROMPTS} concurrency=${CONCURRENCY} max_out=${MAX_OUT_LEN}"
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo ""

  docker ps -aq --filter "name=vnpu-4pod-.*${TAG}" | xargs -r docker rm -f >/dev/null 2>&1 || true

  for ((i=0; i<NUM_PODS; i++)); do
    echo ">>> [1] launch pod ${i} (serial health)"
    launch_pod "${i}"
    wait_health "$((BASE_PORT + i))" "vnpu-4pod-${i}-${TAG}"
    warmup_pod "$((BASE_PORT + i))"
    echo ""
  done

  scan_crash_signals "after_startup"

  echo ">>> [2] concurrent aisbench on ${NUM_PODS} pods"
  declare -a bench_pids
  for ((i=0; i<NUM_PODS; i++)); do
    run_bench_pod "${i}" &
    bench_pids+=($!)
  done
  bench_ok=0
  for ((i=0; i<NUM_PODS; i++)); do
    if wait "${bench_pids[$i]}"; then
      bench_ok=$((bench_ok + 1))
    fi
  done
  echo "aisbench finished: ${bench_ok}/${NUM_PODS} succeeded"
  echo ""

  scan_crash_signals "after_aisbench"

  echo "=== per-pod throughput ==="
  agg=0
  for ((i=0; i<NUM_PODS; i++)); do
    csv=$(find "${BENCH}/outputs" -path "*4pod_c${NPU}_p${i}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
    [[ -n "${csv}" && -f "${csv}" ]] || \
      csv=$(find "${BENCH}/outputs" -path "*openeuler_oe_vllm_4pod_c${NPU}_p${i}_${TAG}*" -name '*.csv' 2>/dev/null | head -1)
    if [[ -n "${csv}" && -f "${csv}" ]]; then
      th=$(extract_metric "${csv}" "OutputTokenThroughput")
      echo "pod${i} port=$((BASE_PORT + i)) throughput=${th} csv=${csv}"
      val=$(echo "${th}" | grep -oE '[0-9.]+' | head -1)
      if [[ -n "${val}" ]]; then
        agg=$(python3 -c "print(float('${agg}')+float('${val}'))")
      fi
    else
      echo "pod${i} port=$((BASE_PORT + i)) throughput=MISSING"
    fi
  done
  echo "aggregate_tok_s=${agg}"
  echo ""
  echo "RESULT: pods=${NUM_PODS} bench_ok=${bench_ok}/${NUM_PODS} card=${NPU}"
} 2>&1 | tee "${REPORT}"

echo "report: ${REPORT}"
