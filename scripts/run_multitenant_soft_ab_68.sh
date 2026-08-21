#!/usr/bin/env bash
# Multi-tenant soft-split A/B on node 68:
#   - two vLLM containers share one physical NPU
#   - each has its own limiter/local shmem, both share one global registry
#   - compare optimized vs origin by aggregate throughput
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
UB="${FT}/ubuntu"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
MS_PY="${MS_PY:-${KY}/ms-conda/bin/python}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_BATCHED="${MAX_BATCHED:-4096}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
CONCURRENCY="${CONCURRENCY:-8}"
BATCH_SIZE="${BATCH_SIZE:-8}"
MAX_OUT_LEN="${MAX_OUT_LEN:-1024}"
NUM_PROMPTS="${NUM_PROMPTS:-32}"
MEM_QUOTA="${NPU_MEM_QUOTA:-24000}"
PRIORITY="${NPU_PRIORITY:-50}"
FIXED_SHARE="${NPU_FIXED_SHARE_RATIO:-0}"
FCSP_REFILL="${NPU_FCSP_REFILL:-0}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/multitenant_soft_ab_${TAG}.csv"
SUMMARY="${KY}/logs/multitenant_soft_ab_${TAG}.txt"

mkdir -p "${KY}/logs"
echo "mode,port,side,E2EL,TTFT,TPOT,OutputTokenThroughput,csv" > "${REPORT}"

cleanup() {
  docker rm -f mt-soft-opt-a mt-soft-opt-b mt-soft-origin-a mt-soft-origin-b 2>/dev/null || true
  rm -f "${HAMi_SHM}/local_shmem/mt_soft_${TAG}_"* 2>/dev/null || true
}

wait_health() {
  local port="$1" name="$2"
  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "health_ok ${name} :${port}"
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      echo "container exited: ${name}" >&2
      docker logs "${name}" 2>&1 | tail -80 >&2 || true
      return 1
    fi
    sleep 10
  done
  echo "health timeout: ${name}" >&2
  docker logs "${name}" 2>&1 | tail -80 >&2 || true
  return 1
}

launch_one() {
  local mode="$1" suffix="$2" port="$3" so_rel="$4" global="$5"
  local name="mt-soft-${mode}-${suffix}"
  local local_name="mt_soft_${TAG}_${mode}_${suffix}"
  local lim="/opt/ft/${so_rel}/limiter > /opt/ft/kylin/logs/limiter-${name}-${TAG}.log 2>&1 & sleep 3"

  docker rm -f "${name}" 2>/dev/null || true
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
export LD_PRELOAD=/opt/ft/${so_rel}/libvnpu.so
export NPU_MEM_QUOTA=${MEM_QUOTA} NPU_PRIORITY=${PRIORITY} NPU_FIXED_SHARE_RATIO=${FIXED_SHARE}
export NPU_KYLIN_PRESET=1 NPU_KYLIN_LITE=1
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0 VXPU_MEMINFO_TRACE=0
export NPU_FCSP_REFILL=${FCSP_REFILL} NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3 NPU_TOKEN_CHUNK=32 NPU_KERNEL_BURST=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/${global}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
export NPU_LOCAL_SHM_NAME=${local_name}
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=1
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
  '--max_model_len', '${MAX_MODEL_LEN}', '--max-num-batched-tokens', '${MAX_BATCHED}',
  '--enable-auto-tool-choice', '--tool-call-parser', 'hermes',
  '--no-enable_expert_parallel', '--block-size', '128',
  '--async-scheduling', '--distributed_executor_backend', 'mp',
  '--enforce-eager', '--no-enable-prefix-caching',
]
runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
\"
"
}

run_bench_one() {
  local mode="$1" suffix="$2" port="$3"
  local tag="mt_${mode}_${suffix}_${TAG}"
  OUT_TAG="${tag}" VLLM_PORT="${port}" CONCURRENCY="${CONCURRENCY}" BATCH_SIZE="${BATCH_SIZE}" \
    MAX_OUT_LEN="${MAX_OUT_LEN}" NUM_PROMPTS="${NUM_PROMPTS}" bash "${UB}/aisbench_perf_ubuntu.sh" \
    >"${KY}/logs/aisbench_${tag}.log" 2>&1
}

extract_metric() {
  local csv="$1" key="$2"
  awk -F, -v k="$key" '$1==k && $2=="total" {print $3; exit}' "$csv"
}

record_one() {
  local mode="$1" suffix="$2" port="$3"
  local csv
  csv=$(find "${BENCH}/outputs" -path "*mt_${mode}_${suffix}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  [[ -n "$csv" && -f "$csv" ]] || { echo "missing csv ${mode}/${suffix}" >&2; return 1; }
  local e2el ttft tpot th
  e2el=$(extract_metric "$csv" "E2EL")
  ttft=$(extract_metric "$csv" "TTFT")
  tpot=$(extract_metric "$csv" "TPOT")
  th=$(extract_metric "$csv" "OutputTokenThroughput")
  echo "${mode},${port},${suffix},${e2el},${ttft},${tpot},${th},${csv}" >> "${REPORT}"
}

run_mode() {
  local mode="$1" so_rel="$2"
  local global="global_registry_mt_soft_${mode}_${TAG}"
  cleanup
  echo ">>> mode=${mode} so=${so_rel}" | tee -a "${SUMMARY}"
  launch_one "${mode}" a 18131 "${so_rel}" "${global}"
  wait_health 18131 "mt-soft-${mode}-a"
  # vLLM/Ascend profile initialization is much more stable if two containers
  # are not compiling/profiling the same physical NPU at exactly the same time.
  launch_one "${mode}" b 18132 "${so_rel}" "${global}"
  wait_health 18132 "mt-soft-${mode}-b"
  run_bench_one "${mode}" a 18131 &
  local p1=$!
  run_bench_one "${mode}" b 18132 &
  local p2=$!
  wait "$p1"
  wait "$p2"
  record_one "${mode}" a 18131
  record_one "${mode}" b 18132
  local sum
  sum=$(awk -F, -v m="$mode" '$1==m {gsub(" token/s","",$7); s+=$7} END{printf "%.4f", s}' "${REPORT}")
  echo "mode=${mode} aggregate_tok_s=${sum}" | tee -a "${SUMMARY}"
  docker rm -f "mt-soft-${mode}-a" "mt-soft-${mode}-b" >/dev/null 2>&1 || true
}

trap cleanup EXIT
{
  echo "=== multitenant soft A/B ${TAG} ==="
  echo "report=${REPORT}"
  echo "NPU=${NPU} priority=${PRIORITY} mem_quota=${MEM_QUOTA} fixed_share=${FIXED_SHARE} fcsp=${FCSP_REFILL}"
  echo "vllm: max_num_seqs=${MAX_NUM_SEQS} max_batched=${MAX_BATCHED} gpu_mem=${GPU_MEM_UTIL} max_model_len=${MAX_MODEL_LEN}"
  echo "aisbench: concurrency=${CONCURRENCY} batch=${BATCH_SIZE} max_out=${MAX_OUT_LEN} prompts=${NUM_PROMPTS}"
} | tee "${SUMMARY}"

run_mode opt kylin/release-optimized
run_mode origin kylin/release-origin

echo "=== final ===" | tee -a "${SUMMARY}"
cat "${REPORT}" | tee -a "${SUMMARY}"
awk -F, 'NR>1 {gsub(" token/s","",$7); sum[$1]+=$7} END{for (m in sum) printf "%s aggregate_tok_s=%.4f\n", m, sum[m]}' "${REPORT}" | tee -a "${SUMMARY}"
echo "done summary=${SUMMARY}"
