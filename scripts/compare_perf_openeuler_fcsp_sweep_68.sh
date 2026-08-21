#!/usr/bin/env bash
# openEuler container A/B sweep: FCSP on/off, order swap, chunk tuning.
# Uses openEuler-built release vs release-main SO inside mindspeed openEuler image.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
MODEL_HOST="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18020}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
AISBENCH_CONCURRENCY="${AISBENCH_CONCURRENCY:-4}"
OPT_REL="${OPT_REL:-release}"
MAIN_REL="${MAIN_REL:-release-main}"
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${OE}/logs/openeuler_fcsp_sweep_${TAG}.csv"
SUMMARY="${OE}/logs/openeuler_fcsp_sweep_${TAG}.txt"

export NPU_MEM_QUOTA="${NPU_MEM_QUOTA:-16000}"
export NPU_PRIORITY="${NPU_PRIORITY:-25}"
export NPU_FIXED_SHARE_RATIO="${NPU_FIXED_SHARE_RATIO:-0}"
export NPU_FCSP_REFILL_INTERVAL_US="${NPU_FCSP_REFILL_INTERVAL_US:-100}"
export NPU_BURST_ALPHA="${NPU_BURST_ALPHA:-0.3}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"

# scenario|order|fcsp|burst_cont|chunk
# order: opt_first | main_first
DEFAULT_SCENARIOS=(
  "fcsp0_opt_first|opt_first|0|1|32"
  "fcsp0_main_first|main_first|0|1|32"
  "fcsp0_burst_off|opt_first|0|0|32"
  "fcsp0_chunk8|opt_first|0|1|8"
  "fcsp1_baseline|opt_first|1|1|32"
  "fcsp1_chunk8|opt_first|1|1|8"
)

if [[ -n "${SCENARIOS:-}" ]]; then
  SCENARIO_LIST=()
  for item in $SCENARIOS; do
    if [[ "$item" == *"|"* ]]; then
      SCENARIO_LIST+=("$item")
    else
      found=0
      for def in "${DEFAULT_SCENARIOS[@]}"; do
        if [[ "$def" == "${item}|"* ]]; then
          SCENARIO_LIST+=("$def")
          found=1
          break
        fi
      done
      [[ "$found" == 1 ]] || { echo "unknown scenario alias: $item" >&2; exit 1; }
    fi
  done
else
  SCENARIO_LIST=("${DEFAULT_SCENARIOS[@]}")
fi

stop_all() {
  docker ps -aq --filter 'name=vnpu-oe-sweep-' | xargs -r docker rm -f >/dev/null 2>&1 || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  sleep 3
}

wait_port_free() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: port ${PORT} still serving after stop_all" >&2
  return 1
}

run_vllm() {
  local so_rel="$1" name="$2" fcsp="$3" burst_cont="$4" chunk="$5"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -e NPU_MEM_QUOTA -e NPU_PRIORITY -e NPU_FIXED_SHARE_RATIO \
    -e NPU_FCSP_REFILL="$fcsp" -e NPU_FCSP_REFILL_INTERVAL_US \
    -e NPU_BURST_ALPHA -e NPU_BURST_CONTINUOUS="$burst_cont" -e NPU_TOKEN_CHUNK="$chunk" \
    -e VXPU_MEMINFO_USE_DCMI=0 -e VXPU_MEMINFO_TRACE=0 \
    -e VLLM_PLATFORM=ascend -e VLLM_USE_V1=1 -e TASK_QUEUE_ENABLE=1 \
    -e HCCL_OP_EXPANSION_MODE=AIV -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
    -e OMP_NUM_THREADS=1 -e VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 -e VLLM_ASCEND_ENABLE_NZ=2 \
    -e TORCH_COMPILE_DISABLE=1 \
    -v "${FT}:/opt/ft" \
    -v "${OE}/vllm-workspace:/vllm-workspace:ro" \
    -v "${OE}/py310-site:/opt/py310-site:ro" \
    -v "${MODEL_HOST}:/models:ro" \
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
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_oe_sweep_${TAG}_${name}
export NPU_LOCAL_SHM_NAME=vnpu_oe_sweep_${TAG}_${name}
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON_PKG\" && ! -d \"\${TRITON_PKG}.disabled\" ]] && mv \"\$TRITON_PKG\" \"\${TRITON_PKG}.disabled\"
rm -f /dev/shm/vnpu_oe_sweep_${TAG}_${name} 2>/dev/null || true
\${SO}/limiter > /opt/ft/openeuler/logs/limiter-oe-sweep-${TAG}-${name}.log 2>&1 & sleep 5
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
  '--max_model_len', '${MAX_MODEL_LEN}', '--max-num-batched-tokens', '${MAX_MODEL_LEN}',
  '--enable-auto-tool-choice', '--tool-call-parser', 'hermes',
  '--no-enable_expert_parallel', '--block-size', '128',
  '--async-scheduling', '--distributed_executor_backend', 'mp',
  '--enforce-eager', '--no-enable-prefix-caching',
]
runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
\""
  local deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "health_ok elapsed=$((SECONDS))s name=$name so=$so_rel fcsp=$fcsp chunk=$chunk"
      return 0
    fi
    docker ps --format '{{.Names}}' | grep -qx "$name" || { docker logs --tail 30 "$name"; return 1; }
    sleep 10
  done
  docker logs --tail 30 "$name"
  return 1
}

run_aisbench() {
  local out_tag="$1" container="$2"
  OUT_TAG="$out_tag" VLLM_CONTAINER="$container" VLLM_PORT="$PORT" \
    MODEL_HOST="$MODEL_HOST" NUM_PROMPTS="$NUM_PROMPTS" AISBENCH_CONCURRENCY="$AISBENCH_CONCURRENCY" \
    bash "${OE}/aisbench_perf_openeuler_container.sh" >>"$3" 2>&1
}

extract_metric() {
  awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"
}

run_side() {
  local side="$1" so_rel="$2" scen="$3" fcsp="$4" burst_cont="$5" chunk="$6"
  local name="vnpu-oe-sweep-${side}-${scen}"
  local vllm_log="${OE}/logs/oe_sweep_${scen}_${side}_vllm_${TAG}.log"
  local bench_log="${OE}/logs/aisbench_oe_${scen}_${side}_${TAG}.log"
  stop_all
  wait_port_free
  run_vllm "$so_rel" "$name" "$fcsp" "$burst_cont" "$chunk" >>"$vllm_log" 2>&1
  run_aisbench "oe_${scen}_${side}_${TAG}" "$name" "$bench_log"
  local csv
  csv=$(find /mnt/local/m00953550/benchmark/outputs -path "*oe_${scen}_${side}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
  [[ -n "$csv" && -f "$csv" ]] || { echo "missing csv for ${scen}/${side}" >&2; return 1; }
}

mkdir -p "${OE}/logs"
echo "scenario,order,fcsp,burst_cont,chunk,side,E2EL,TTFT,TPOT,OutputTokenThroughput,winner_vs_other" > "$REPORT"
{
  echo "=== openEuler FCSP sweep ${TAG} ==="
  echo "opt_so=${OPT_REL} main_so=${MAIN_REL} port=${PORT}"
  echo "report_csv=$REPORT"
  echo ""
} | tee "$SUMMARY"

for spec in "${SCENARIO_LIST[@]}"; do
  IFS='|' read -r scen order fcsp burst_cont chunk <<< "$spec"
  stop_all

  {
    echo ">>> scenario=$scen order=$order fcsp=$fcsp burst_cont=$burst_cont chunk=$chunk"
  } | tee -a "$SUMMARY"

  if [[ "$order" == "main_first" ]]; then
    sides=(main "$MAIN_REL" opt "$OPT_REL")
  else
    sides=(opt "$OPT_REL" main "$MAIN_REL")
  fi

  declare -A CSV_PATH
  for ((i=0; i<${#sides[@]}; i+=2)); do
    side="${sides[i]}"
    so_rel="${sides[i+1]}"
    cname="vnpu-oe-sweep-${side}-${scen}"
    run_side "$side" "$so_rel" "$scen" "$fcsp" "$burst_cont" "$chunk"
    CSV_PATH[$side]=$(find /mnt/local/m00953550/benchmark/outputs -path "*oe_${scen}_${side}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1)
    [[ -n "${CSV_PATH[$side]}" && -f "${CSV_PATH[$side]}" ]] || { echo "missing csv for ${scen}/${side}" >&2; exit 1; }
    docker rm -f "$cname" >/dev/null 2>&1 || true
    stop_all
  done

  e2el_opt=$(extract_metric "${CSV_PATH[opt]}" E2EL)
  e2el_main=$(extract_metric "${CSV_PATH[main]}" E2EL)
  ttft_opt=$(extract_metric "${CSV_PATH[opt]}" TTFT)
  ttft_main=$(extract_metric "${CSV_PATH[main]}" TTFT)
  tpot_opt=$(extract_metric "${CSV_PATH[opt]}" TPOT)
  tpot_main=$(extract_metric "${CSV_PATH[main]}" TPOT)
  tok_opt=$(extract_metric "${CSV_PATH[opt]}" OutputTokenThroughput)
  tok_main=$(extract_metric "${CSV_PATH[main]}" OutputTokenThroughput)

  winner="tie"
  opt_n=$(echo "$tok_opt" | awk '{print $1}')
  main_n=$(echo "$tok_main" | awk '{print $1}')
  if awk -v a="$opt_n" -v b="$main_n" 'BEGIN{exit !(a>b)}'; then
    winner="optimized"
  elif awk -v a="$opt_n" -v b="$main_n" 'BEGIN{exit !(a<b)}'; then
    winner="main"
  fi

  for side in opt main; do
    csv="${CSV_PATH[$side]}"
    echo "$scen,$order,$fcsp,$burst_cont,$chunk,$side,$(extract_metric "$csv" E2EL),$(extract_metric "$csv" TTFT),$(extract_metric "$csv" TPOT),$(extract_metric "$csv" OutputTokenThroughput),$winner" >> "$REPORT"
  done

  {
    echo "  E2EL: opt=$e2el_opt main=$e2el_main"
    echo "  TTFT: opt=$ttft_opt main=$ttft_main"
    echo "  TPOT: opt=$tpot_opt main=$tpot_main"
    echo "  Throughput: opt=$tok_opt main=$tok_main => winner=$winner"
    echo ""
  } | tee -a "$SUMMARY"
done

{
  echo "=== winners by scenario (throughput) ==="
  awk -F, 'NR>1 && $6=="opt" {print $1, $11}' "$REPORT" | sort -u
  echo ""
  echo "=== best optimized config (max opt throughput) ==="
  awk -F, 'NR>1 && $6=="opt" {gsub(/ token\/s/,"",$10); print $10,$1,$3,$5}' "$REPORT" | sort -rn | head -3
  echo ""
  echo "csv: $REPORT"
} | tee -a "$SUMMARY"

echo "done: $SUMMARY"
