#!/usr/bin/env bash
# A/B perf: openEuler release (optimized) vs release-main (hami-vnpu-core-main).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18003}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${OE}/logs/perf_compare_${TAG}.txt"

run_vllm() {
  local so_rel="$1" name="$2" gshm="$3" lshm="$4" limlog="$5"
  docker rm -f "$name" 2>/dev/null || true
  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
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
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
export VXPU_MEMINFO_USE_DCMI=0
# Fair A/B: same env on optimized and main — only LD_PRELOAD (so_rel) differs.
# See reference/vllm_openeuler_ab_shared_env.yaml and scripts/compare_perf_param_sweep.sh
export NPU_FCSP_REFILL="${NPU_FCSP_REFILL:-1}" NPU_BURST_CONTINUOUS="${NPU_BURST_CONTINUOUS:-1}"
export NPU_BURST_ALPHA="${NPU_BURST_ALPHA:-0.3}" NPU_TOKEN_CHUNK="${NPU_TOKEN_CHUNK:-32}"
export VLLM_PLATFORM=ascend VLLM_USE_V1=1 TASK_QUEUE_ENABLE=1
export HCCL_OP_EXPANSION_MODE=AIV PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=1 VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2
export TORCH_COMPILE_DISABLE=1
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON_PKG\" && ! -d \"\${TRITON_PKG}.disabled\" ]] && mv \"\$TRITON_PKG\" \"\${TRITON_PKG}.disabled\"
echo SO=\${so_rel} sha=\$(sha256sum \${SO}/libvnpu.so | cut -c1-16)
rm -f /dev/shm/${lshm} 2>/dev/null || true
\${SO}/limiter > /opt/ft/logs/${limlog} 2>&1 & sleep 5
pgrep -f \"\${SO}/limiter\"
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
  local deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && return 0
    docker ps --format '{{.Names}}' | grep -qx "$name" || { docker logs --tail 30 "$name"; return 1; }
    sleep 10
  done
  return 1
}

run_aisbench() {
  local label="$1" out_tag="$2" container="$3"
  OUT_TAG="$out_tag" VLLM_CONTAINER="$container" VLLM_PORT="$PORT" NUM_PROMPTS="$NUM_PROMPTS" \
    bash "${OE}/aisbench_perf_openeuler_container.sh"
}

extract_metric() {
  local csv="$1" key="$2"
  awk -F, -v k="$key" '$1==k && $2=="total" {print $3; exit}' "$csv"
}

mkdir -p "${OE}/logs"
{
  echo "=== perf compare ${TAG} ==="
  echo "NPU=$NPU PORT=$PORT NUM_PROMPTS=$NUM_PROMPTS concurrency=4"
  echo ""

  echo ">>> [A] release (optimized) libvnpu"
  run_vllm release vnpu-perf-release global_registry_perf_release vnpu_perf_release limiter-perf-release.log
  run_aisbench release "release_${TAG}" vnpu-perf-release | tee "${OE}/logs/aisbench_release_${TAG}.log"
  CSV_A=$(find /mnt/local/m00953550/benchmark/outputs -path "*release_${TAG}*" -name gsm8kdataset.csv | head -1)
  docker rm -f vnpu-perf-release 2>/dev/null || true
  sleep 10

  echo ""
  echo ">>> [B] release-main (hami-vnpu-core-main)"
  run_vllm release-main vnpu-perf-main global_registry_perf_main vnpu_perf_main limiter-perf-main.log
  run_aisbench main "main_${TAG}" vnpu-perf-main | tee "${OE}/logs/aisbench_main_${TAG}.log"
  CSV_B=$(find /mnt/local/m00953550/benchmark/outputs -path "*main_${TAG}*" -name gsm8kdataset.csv | head -1)
  docker rm -f vnpu-perf-main 2>/dev/null || true

  echo ""
  echo "=== comparison (demo_gsm8k perf) ==="
  printf "%-28s %-22s %-22s\n" "Metric" "release (optimized)" "release-main"
  for m in E2EL TTFT TPOT OutputTokenThroughput; do
    a=$(extract_metric "$CSV_A" "$m")
    b=$(extract_metric "$CSV_B" "$m")
    printf "%-28s %-22s %-22s\n" "$m" "$a" "$b"
  done
  echo ""
  echo "CSV release: $CSV_A"
  echo "CSV main:    $CSV_B"
} | tee "$REPORT"

echo "report: $REPORT"
