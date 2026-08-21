#!/usr/bin/env bash
# A/B: openEuler LLM-turbo optimized vs origin (Mutex-based) hijack library.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18020}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${OE}/logs/perf_oe_turbo_${TAG}.txt"
OPT_REL="${OPT_REL:-release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-release-origin}"

stop_vllm() {
  docker rm -f vnpu-oe-turbo-opt vnpu-oe-turbo-origin 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  sleep 5
}

wait_port_free() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 || return 0
    sleep 2
  done
  echo "WARN: port ${PORT} still serving" >&2
}

run_vllm() {
  local so_rel="$1" name="$2" gshm="$3" lshm="$4" limlog="$5" extra_env="${6:-}"
  docker rm -f "$name" 2>/dev/null || true
  sleep 2

  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -e VXPU_MEMINFO_USE_DCMI=0 -e VXPU_MEMINFO_TRACE=0 \
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
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
${extra_env}
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON_PKG\" && ! -d \"\${TRITON_PKG}.disabled\" ]] && mv \"\$TRITON_PKG\" \"\${TRITON_PKG}.disabled\"
echo SO=${so_rel} sha=\$(sha256sum \${SO}/libvnpu.so | cut -c1-16)
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
  '--gpu-memory-utilization', '0.5', '--max-num-seqs', '4',
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
      echo "health_ok elapsed=$((SECONDS))s name=$name"
      return 0
    }
    docker ps --format '{{.Names}}' | grep -qx "$name" || {
      docker logs --tail 50 "$name" 2>&1
      return 1
    }
    sleep 10
  done
  docker logs --tail 50 "$name" 2>&1
  return 1
}

run_aisbench() {
  local out_tag="$1" container="$2"
  OUT_TAG="$out_tag" VLLM_CONTAINER="$container" VLLM_PORT="$PORT" \
    NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${OE}/aisbench_perf_openeuler_container.sh"
}

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

mkdir -p "${OE}/logs"
TURBO_ENV="${TURBO_ENV:-export NPU_LLM_MODE=1 NPU_SCHED_POLICY=elastic NPU_ITERATION_SCHED=1 NPU_FIKIT_MODE=1 NPU_LLM_BURST=1 NPU_TOKEN_CHUNK=1 NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50}"

stop_vllm
wait_port_free

{
  echo "=== openEuler LLM-turbo A/B ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS"
  echo "opt=${OPT_REL} origin=${ORIGIN_REL}"
  echo "turbo_env: ${TURBO_ENV}"
  echo ""

  echo ">>> [A] turbo optimized (${OPT_REL})"
  run_vllm "$OPT_REL" vnpu-oe-turbo-opt "global_registry_oe_turbo_opt_${TAG}" \
    "vnpu_oe_turbo_opt_${TAG}" "limiter-oe-turbo-opt-${TAG}.log" "$TURBO_ENV"
  run_aisbench "oe_turbo_opt_${TAG}" vnpu-oe-turbo-opt | tee "${OE}/logs/aisbench_oe_turbo_opt_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*oe_turbo_opt_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_vllm
  wait_port_free

  echo ""
  echo ">>> [B] origin (${ORIGIN_REL})"
  run_vllm "$ORIGIN_REL" vnpu-oe-turbo-origin "global_registry_oe_turbo_origin_${TAG}" \
    "vnpu_oe_turbo_origin_${TAG}" "limiter-oe-turbo-origin-${TAG}.log" ""
  run_aisbench "oe_turbo_origin_${TAG}" vnpu-oe-turbo-origin | tee "${OE}/logs/aisbench_oe_turbo_origin_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*oe_turbo_origin_${TAG}*" -name gsm8kdataset.csv | head -1)
  stop_vllm

  echo ""
  echo "=== comparison ==="
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
PY
  fi
  echo "CSV opt: $CSV_A"
  echo "CSV origin: $CSV_B"
} | tee "$REPORT"
echo "report: $REPORT"
