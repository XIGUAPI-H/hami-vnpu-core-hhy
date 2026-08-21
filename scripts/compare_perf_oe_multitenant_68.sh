#!/usr/bin/env bash
# Multi-tenant openEuler A/B: turbo-opt vs origin under shared NPU contention.
# 1 vLLM (measured) + (SPLIT_TENANTS-1) matmul burner containers on same global registry.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18025}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
AISBENCH_CONCURRENCY="${AISBENCH_CONCURRENCY:-8}"
SPLIT_TENANTS="${SPLIT_TENANTS:-4}"
NPU_PRIORITY="${NPU_PRIORITY:-25}"
NPU_MEM_QUOTA="${NPU_MEM_QUOTA:-6400}"
NPU_FIXED_SHARE_RATIO="${NPU_FIXED_SHARE_RATIO:-0}"
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${OE}/logs/perf_oe_multitenant_${TAG}.txt"
OPT_REL="${OPT_REL:-release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-release-origin}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.9}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"

if [[ "$NPU_MEM_QUOTA" -le 8000 ]]; then
  GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.9}"
fi

TURBO_ENV="${TURBO_ENV:-export NPU_LLM_MODE=1 NPU_SCHED_POLICY=elastic NPU_ITERATION_SCHED=1 NPU_FIKIT_MODE=1 NPU_LLM_BURST=1 NPU_TOKEN_CHUNK=1 NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50 NPU_BURST_CONTINUOUS=1}"

stop_all() {
  docker ps -aq --filter "name=vnpu-oe-mt-" | xargs -r docker rm -f >/dev/null 2>&1 || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  sleep 5
}

wait_port_free() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 || return 0
    sleep 2
  done
}

contender_count() {
  [[ "$SPLIT_TENANTS" -le 1 ]] && echo 0 || echo $((SPLIT_TENANTS - 1))
}

start_contenders() {
  local so_rel="$1" gshm="$2"
  local n
  n=$(contender_count)
  [[ "$n" -eq 0 ]] && return 0
  echo ">>> starting ${n} matmul contenders (so=${so_rel}, prio=${NPU_PRIORITY}, mem=${NPU_MEM_QUOTA})"
  local i
  for ((i = 1; i <= n; i++)); do
    docker rm -f "vnpu-oe-mt-c${i}-${TAG}" 2>/dev/null || true
    docker run -d --name "vnpu-oe-mt-c${i}-${TAG}" --privileged --network host \
      -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
      -v "${FT}:/opt/ft" \
      -v /usr/local/Ascend:/usr/local/Ascend:ro \
      -v /usr/local/dcmi:/usr/local/dcmi:ro \
      -v /usr/local/hami-shared-region:/hami-shared-region \
      -v /dev/davinci_manager:/dev/davinci_manager \
      -v /dev/devmm_svm:/dev/devmm_svm \
      -v /dev/hisi_hdc:/dev/hisi_hdc \
      "$IMAGE" \
      bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
PY=/root/miniconda3/envs/llm_test/bin/python
SO=/opt/ft/openeuler/${so_rel}
export LD_PRELOAD=\${SO}/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/${gshm}
export NPU_LOCAL_SHM_NAME=vnpu_oe_mt_c${i}_${TAG}
export NPU_MEM_QUOTA=${NPU_MEM_QUOTA} NPU_PRIORITY=${NPU_PRIORITY} NPU_FIXED_SHARE_RATIO=${NPU_FIXED_SHARE_RATIO}
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3 NPU_TOKEN_CHUNK=128
rm -f /dev/shm/vnpu_oe_mt_c${i}_${TAG} 2>/dev/null || true
\${SO}/limiter > /opt/ft/openeuler/logs/limiter-oe-mt-c${i}-${TAG}.log 2>&1 & sleep 3
exec \$PY - <<'PY'
import time, torch, torch_npu
torch.npu.set_device(0)
N = 4096
x = torch.randn(N, N, dtype=torch.float16, device='npu:0')
y = torch.randn(N, N, dtype=torch.float16, device='npu:0')
for _ in range(20):
    torch.matmul(x, y)
torch.npu.synchronize()
i = 0
while True:
    torch.matmul(x, y)
    i += 1
    if i % 200 == 0:
        torch.npu.synchronize()
PY
"
  done
  sleep 5
  echo "contenders_running=$(docker ps --filter name=vnpu-oe-mt-c --format '{{.Names}}' | wc -l)"
}

run_vllm_primary() {
  local so_rel="$1" name="$2" gshm="$3" lshm="$4" limlog="$5" extra_env="${6:-}"
  docker rm -f "$name" 2>/dev/null || true
  sleep 2
  start_contenders "$so_rel" "$gshm"
  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -e VXPU_MEMINFO_USE_DCMI=0 \
    -e VLLM_PLATFORM=ascend -e VLLM_USE_V1=1 -e TASK_QUEUE_ENABLE=1 \
    -e HCCL_OP_EXPANSION_MODE=AIV -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
    -e OMP_NUM_THREADS=1 -e VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 -e VLLM_ASCEND_ENABLE_NZ=2 \
    -e TORCH_COMPILE_DISABLE=1 \
    -v "${FT}:/opt/ft" \
    -v "${OE}/vllm-workspace:/vllm-workspace:ro" \
    -v "${OE}/py310-site:/opt/py310-site:ro" \
    -v "${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}:/models:ro" \
    -v /usr/local/Ascend:/usr/local/Ascend:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v /usr/local/hami-shared-region:/hami-shared-region \
    -v /dev/davinci_manager:/dev/davinci_manager \
    -v /dev/devmm_svm:/dev/devmm_svm \
    -v /dev/hisi_hdc:/dev/hisi_hdc \
    "$IMAGE" \
    bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site\${PYTHONPATH:+:\$PYTHONPATH}
PY=/root/miniconda3/envs/llm_test/bin/python
SO=/opt/ft/openeuler/${so_rel}
export LD_PRELOAD=\${SO}/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/${gshm}
export NPU_LOCAL_SHM_NAME=${lshm}
export NPU_MEM_QUOTA=${NPU_MEM_QUOTA} NPU_PRIORITY=${NPU_PRIORITY} NPU_FIXED_SHARE_RATIO=${NPU_FIXED_SHARE_RATIO}
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
${extra_env}
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON_PKG\" && ! -d \"\${TRITON_PKG}.disabled\" ]] && mv \"\$TRITON_PKG\" \"\${TRITON_PKG}.disabled\"
echo SO=${so_rel} tenants=${SPLIT_TENANTS}
rm -f /dev/shm/${lshm} 2>/dev/null || true
\${SO}/limiter > /opt/ft/openeuler/logs/${limlog} 2>&1 & sleep 5
pgrep -x limiter || { cat /opt/ft/openeuler/logs/${limlog}; exit 1; }
exec \$PY -c \"
import sys, runpy
sys.path.insert(0, '/opt/py310-site')
sys.argv = [
  'api_server', '--model=/models', '--trust-remote-code',
  '--distributed-executor-backend', 'mp', '--tensor-parallel-size', '1',
  '--pipeline-parallel-size', '1', '--disable-frontend-multiprocessing',
  '--port', '${PORT}', '--host', '0.0.0.0',
  '--gpu-memory-utilization', '${GPU_MEM_UTIL}', '--max-num-seqs', '${MAX_NUM_SEQS}',
  '--served-model-name', 'qwen3', '--dtype', 'bfloat16',
  '--max_model_len', '4096', '--max-num-batched-tokens', '4096',
  '--enable-auto-tool-choice', '--tool-call-parser', 'hermes',
  '--no-enable_expert_parallel', '--block-size', '128',
  '--async-scheduling', '--distributed_executor_backend', 'mp',
  '--enforce-eager', '--no-enable-prefix-caching',
]
runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
\""
  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && {
      echo "health_ok elapsed=$((SECONDS))s"
      return 0
    }
    docker ps --format '{{.Names}}' | grep -qx "$name" || {
      docker logs --tail 40 "$name" 2>&1
      return 1
    }
    sleep 10
  done
  docker logs --tail 40 "$name" 2>&1
  return 1
}

run_aisbench() {
  local out_tag="$1" container="$2"
  OUT_TAG="$out_tag" VLLM_CONTAINER="$container" VLLM_PORT="$PORT" \
    NUM_PROMPTS="$NUM_PROMPTS" AISBENCH_CONCURRENCY="$AISBENCH_CONCURRENCY" \
    bash "${OE}/aisbench_perf_openeuler_container.sh"
}

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

mkdir -p "${OE}/logs"
stop_all
wait_port_free

GSHM="global_registry_oe_mt_${TAG}"

{
  echo "=== openEuler multi-tenant A/B ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT tenants=${SPLIT_TENANTS} (1 vLLM + $(contender_count) matmul)"
  echo "prio=${NPU_PRIORITY} mem=${NPU_MEM_QUOTA} fixed=${NPU_FIXED_SHARE_RATIO} max_seqs=${MAX_NUM_SEQS} aisbench_cc=${AISBENCH_CONCURRENCY}"
  echo "turbo_env: ${TURBO_ENV}"
  echo ""

  echo ">>> [A] turbo (${OPT_REL}) under ${SPLIT_TENANTS}-way contention"
  run_vllm_primary "$OPT_REL" vnpu-oe-mt-opt "$GSHM" "vnpu_oe_mt_opt_${TAG}" \
    "limiter-oe-mt-opt-${TAG}.log" "$TURBO_ENV"
  run_aisbench "oe_mt_opt_${TAG}" vnpu-oe-mt-opt | tee "${OE}/logs/aisbench_oe_mt_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*oe_mt_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all
  wait_port_free

  echo ""
  echo ">>> [B] origin (${ORIGIN_REL}) under same contention"
  run_vllm_primary "$ORIGIN_REL" vnpu-oe-mt-origin "$GSHM" "vnpu_oe_mt_origin_${TAG}" \
    "limiter-oe-mt-origin-${TAG}.log" ""
  run_aisbench "oe_mt_origin_${TAG}" vnpu-oe-mt-origin | tee "${OE}/logs/aisbench_oe_mt_origin_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*oe_mt_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_all

  echo ""
  echo "=== comparison (vLLM tenant under ${SPLIT_TENANTS}-way share) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "turbo-opt" "origin"
  for m in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    printf "%-28s %-22s %-22s\n" "$m" "$a" "$b"
  done
  thr_a=$(extract_metric "$CSV_A" "OutputTokenThroughput" | awk '{print $1}')
  thr_b=$(extract_metric "$CSV_B" "OutputTokenThroughput" | awk '{print $1}')
  if [[ -n "$thr_a" && -n "$thr_b" && "$thr_b" != "0" ]]; then
    python3 - <<PY
a=float("${thr_a}"); b=float("${thr_b}")
print(f"speedup_vs_origin: {a/b:.2f}x")
print(f"tenant_share: ~{100/${SPLIT_TENANTS}}% each of ${SPLIT_TENANTS} tenants")
PY
  fi
  echo "CSV opt: $CSV_A"
  echo "CSV origin: $CSV_B"
} | tee "$REPORT"
echo "report: $REPORT"
