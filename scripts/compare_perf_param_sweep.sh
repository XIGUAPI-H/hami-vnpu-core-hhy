#!/usr/bin/env bash
# Fair param sweep: optimized vs main with IDENTICAL env/vLLM/benchmark per scenario.
# Only LD_PRELOAD (libvnpu.so path) differs between A and B.
#
# Usage on 68:
#   bash compare_perf_param_sweep.sh
#   SWEEP_ROUND=2 bash compare_perf_param_sweep.sh   # mem/prio/gpu_util/fixed/burst sweep
#
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT_BASE="${VLLM_PORT:-18010}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${OE}/logs/param_sweep_${TAG}.csv"
SUMMARY="${OE}/logs/param_sweep_${TAG}.txt"

# --- shared baseline (reference/vllm_openeuler_ab_shared_env.yaml) ---
export NPU_MEM_QUOTA="${NPU_MEM_QUOTA:-16000}"
export NPU_PRIORITY="${NPU_PRIORITY:-25}"
export NPU_FIXED_SHARE_RATIO="${NPU_FIXED_SHARE_RATIO:-0}"
export TASK_QUEUE_ENABLE="${TASK_QUEUE_ENABLE:-1}"
export NPU_FCSP_REFILL="${NPU_FCSP_REFILL:-1}"
export NPU_FCSP_REFILL_INTERVAL_US="${NPU_FCSP_REFILL_INTERVAL_US:-100}"
export NPU_BURST_ALPHA="${NPU_BURST_ALPHA:-0.3}"
export NPU_BURST_CONTINUOUS="${NPU_BURST_CONTINUOUS:-1}"
export NPU_TOKEN_CHUNK="${NPU_TOKEN_CHUNK:-32}"

MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
AISBENCH_CONCURRENCY="${AISBENCH_CONCURRENCY:-4}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"

# Round 1: scenario|prio|max_seqs|prompts|conc|tq|chunk
DEFAULT_SCENARIOS=(
  "baseline|25|4|16|4|1|32"
  "prio20|20|4|16|4|1|32"
  "prio40|40|4|16|4|1|32"
  "seq1|25|1|16|4|1|32"
  "seq8|25|8|16|4|1|32"
  "conc8|25|4|16|8|1|32"
  "tq0|25|4|16|4|0|32"
  "chunk8|25|4|16|4|1|8"
  "chunk64|25|4|16|4|1|64"
)

# Round 2: ...|mem_quota|gpu_util|fixed_share|burst_alpha|max_model_len
ROUND2_SCENARIOS=(
  "mem8k|25|4|16|4|1|32|8000|0.5|0|0.3|2048"
  "mem16k|25|4|16|4|1|32|16000|0.5|0|0.3"
  "mem24k|25|4|16|4|1|32|24000|0.5|0|0.3"
  "prio15|15|4|16|4|1|32|16000|0.5|0|0.3"
  "prio35|35|4|16|4|1|32|16000|0.5|0|0.3"
  "prio50|50|4|16|4|1|32|16000|0.5|0|0.3"
  "fixed1|25|4|16|4|1|32|16000|0.5|1|0.3"
  "gpu03|25|4|16|4|1|32|16000|0.3|0|0.3"
  "gpu07|25|4|16|4|1|32|16000|0.7|0|0.3"
  "burst02|25|4|16|4|1|32|16000|0.5|0|0.2"
  "burst05|25|4|16|4|1|32|16000|0.5|0|0.5"
  "conc8_r2|25|4|16|8|1|32|16000|0.5|0|0.3"
)

if [[ -n "${SWEEP_SCENARIOS:-}" ]]; then
  # shellcheck disable=SC2206
  SCENARIOS=($SWEEP_SCENARIOS)
elif [[ "${SWEEP_ROUND:-1}" == "2" ]]; then
  SCENARIOS=("${ROUND2_SCENARIOS[@]}")
else
  SCENARIOS=("${DEFAULT_SCENARIOS[@]}")
fi

run_vllm() {
  local so_rel="$1" name="$2" gshm="$3" lshm="$4" limlog="$5" port="$6"
  docker rm -f "$name" 2>/dev/null || true
  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -e NPU_MEM_QUOTA -e NPU_PRIORITY -e NPU_FIXED_SHARE_RATIO \
    -e NPU_FCSP_REFILL -e NPU_FCSP_REFILL_INTERVAL_US \
    -e NPU_BURST_ALPHA -e NPU_BURST_CONTINUOUS -e NPU_TOKEN_CHUNK \
    -e TASK_QUEUE_ENABLE \
    -e VXPU_MEMINFO_USE_DCMI=0 \
    -e VLLM_PLATFORM=ascend -e VLLM_USE_V1=1 \
    -e HCCL_OP_EXPANSION_MODE=AIV -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
    -e OMP_NUM_THREADS=1 -e VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 -e VLLM_ASCEND_ENABLE_NZ=2 \
    -e TORCH_COMPILE_DISABLE=1 \
    -v "${FT}:/opt/ft" \
    -v "${OE}/vllm-workspace:/vllm-workspace:ro" \
    -v "${OE}/py310-site:/opt/py310-site:ro" \
    -v "${FT}/models/Qwen3-1.7B:/models:ro" \
    -v /usr/local/Ascend:/usr/local/Ascend:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v /usr/local/hami-shared-region:/hami-shared-region \
    -v /dev/davinci_manager:/dev/davinci_manager \
    -v /dev/devmm_svm:/dev/devmm_svm \
    -v /dev/hisi_hdc:/dev/hisi_hdc \
    swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm \
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
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON_PKG\" && ! -d \"\${TRITON_PKG}.disabled\" ]] && mv \"\$TRITON_PKG\" \"\${TRITON_PKG}.disabled\"
rm -f /dev/shm/${lshm} 2>/dev/null || true
\${SO}/limiter > /opt/ft/logs/${limlog} 2>&1 & sleep 5
exec \$PY -c \"
import sys, runpy
sys.path.insert(0, '/opt/py310-site')
sys.argv = [
  'api_server', '--model=/models', '--trust-remote-code',
  '--distributed-executor-backend', 'mp', '--tensor-parallel-size', '1',
  '--pipeline-parallel-size', '1', '--disable-frontend-multiprocessing',
  '--port', '${port}', '--host', '0.0.0.0',
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
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
    docker ps --format '{{.Names}}' | grep -qx "$name" || { docker logs --tail 30 "$name"; return 1; }
    sleep 10
  done
  return 1
}

run_aisbench() {
  local out_tag="$1" container="$2" port="$3"
  OUT_TAG="$out_tag" VLLM_CONTAINER="$container" VLLM_PORT="$port" \
    NUM_PROMPTS="$NUM_PROMPTS" AISBENCH_CONCURRENCY="$AISBENCH_CONCURRENCY" \
    bash "${OE}/aisbench_perf_openeuler_container.sh"
}

extract_metric() {
  local csv="$1" key="$2"
  awk -F, -v k="$key" '$1==k && $2=="total" {print $3; exit}' "$csv"
}

pct_delta() {
  local a="$1" b="$2"
  awk -v a="$a" -v b="$b" 'BEGIN {
    if (b == "" || b == 0 || a == "") { print "n/a"; exit }
    printf "%.2f", (a - b) / b * 100
  }'
}

mkdir -p "${OE}/logs"
echo "scenario,prio,max_seqs,prompts,conc,tq,chunk,mem_quota,gpu_util,fixed_share,burst_alpha,max_model_len,metric,optimized,main,delta_pct" > "$REPORT"

{
  echo "=== param sweep round=${SWEEP_ROUND:-1} ${TAG} (identical env per scenario) ==="
  echo "report_csv=$REPORT"
  echo ""
} | tee "$SUMMARY"

port_idx=0
for spec in "${SCENARIOS[@]}"; do
  IFS='|' read -ra F <<< "$spec"
  scen="${F[0]}"
  prio="${F[1]}"
  seqs="${F[2]}"
  prompts="${F[3]}"
  conc="${F[4]}"
  tq="${F[5]}"
  chunk="${F[6]}"
  local_mem="${F[7]:-${NPU_MEM_QUOTA:-16000}}"
  local_gpu="${F[8]:-${GPU_MEM_UTIL:-0.5}}"
  local_fixed="${F[9]:-${NPU_FIXED_SHARE_RATIO:-0}}"
  local_burst="${F[10]:-${NPU_BURST_ALPHA:-0.3}}"
  local_mlen="${F[11]:-${MAX_MODEL_LEN:-4096}}"

  export NPU_PRIORITY="$prio"
  export NPU_MEM_QUOTA="$local_mem"
  export NPU_FIXED_SHARE_RATIO="$local_fixed"
  export NPU_BURST_ALPHA="$local_burst"
  MAX_NUM_SEQS="$seqs"
  NUM_PROMPTS="$prompts"
  AISBENCH_CONCURRENCY="$conc"
  GPU_MEM_UTIL="$local_gpu"
  MAX_MODEL_LEN="$local_mlen"
  export TASK_QUEUE_ENABLE="$tq"
  export NPU_TOKEN_CHUNK="$chunk"

  port=$((PORT_BASE + port_idx))
  port_idx=$((port_idx + 1))
  scen_tag="${scen}_${TAG}"

  {
    echo ">>> scenario=$scen prio=$prio mem=$local_mem gpu_util=$local_gpu fixed=$local_fixed burst_alpha=$local_burst max_model_len=$local_mlen"
    echo "    max_seqs=$seqs prompts=$prompts conc=$conc tq=$tq chunk=$chunk port=$port"
    echo "    shared env: FCSP=$NPU_FCSP_REFILL TOKEN_CHUNK=$NPU_TOKEN_CHUNK"
  } | tee -a "$SUMMARY"

  run_vllm release "vnpu-sweep-opt-${scen}" global_registry_sweep_opt "vnpu_sweep_opt_${scen}" \
    "limiter-sweep-opt-${scen}.log" "$port"
  run_aisbench "opt_${scen_tag}" "vnpu-sweep-opt-${scen}" "$port" | tee -a "${OE}/logs/aisbench_opt_${scen_tag}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*opt_${scen_tag}*" -name gsm8kdataset.csv | head -1)
  docker rm -f "vnpu-sweep-opt-${scen}" 2>/dev/null || true
  sleep 10

  run_vllm release-main "vnpu-sweep-main-${scen}" global_registry_sweep_main "vnpu_sweep_main_${scen}" \
    "limiter-sweep-main-${scen}.log" "$port"
  run_aisbench "main_${scen_tag}" "vnpu-sweep-main-${scen}" "$port" | tee -a "${OE}/logs/aisbench_main_${scen_tag}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*main_${scen_tag}*" -name gsm8kdataset.csv | head -1)
  docker rm -f "vnpu-sweep-main-${scen}" 2>/dev/null || true
  sleep 10

  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    d=$(pct_delta "$a" "$b")
    echo "${scen},${prio},${seqs},${prompts},${conc},${tq},${chunk},${local_mem},${local_gpu},${local_fixed},${local_burst},${local_mlen},${m},${a},${b},${d}" >> "$REPORT"
    printf "  %-22s opt=%-12s main=%-12s delta%%=%s\n" "$m" "$a" "$b" "$d" | tee -a "$SUMMARY"
  done
  echo "" | tee -a "$SUMMARY"
done

echo "csv: $REPORT"
echo "summary: $SUMMARY"
