#!/usr/bin/env bash
# Kylin OS runtime + openEuler mindspeed Python stack.
# Default NPU_KYLIN_LITE=1: wait_for_token hook + file-shmem/meminfo-cache (no industry stack).
# Parametrized (env, backward compatible defaults):
#   MAX_NUM_SEQS=4  MAX_BATCHED=4096  GPU_MEM_UTIL=0.5  MAX_MODEL_LEN=4096
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
MS_PY="${MS_PY:-${KY}/ms-conda/bin/python}"
VLLM_WS="${VLLM_WS:-${OE}/vllm-workspace}"
PY_SITE="${PY_SITE:-${OE}/py310-site}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
PORT="${VLLM_PORT:-18120}"
SO_REL="${SO_REL:-kylin/release-optimized}"
USE_LIMITER="${USE_LIMITER:-1}"
NAME="${VLLM_NAME:-vnpu-kylin-native-vllm}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
SHM_SIZE="${SHM_SIZE:-}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
MAX_BATCHED="${MAX_BATCHED:-4096}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.5}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
# ENFORCE_EAGER=1 (default) keeps ACL graph OFF; set 0 to enable ACL graph (repro path).
ENFORCE_EAGER="${ENFORCE_EAGER:-1}"
RUST_LOG_LEVEL="${RUST_LOG_LEVEL:-info}"
if [[ "$ENFORCE_EAGER" == "1" ]]; then
  EAGER_FLAG="'--enforce-eager',"
  COMPILE_DISABLE_VAL=1
else
  EAGER_FLAG=""
  COMPILE_DISABLE_VAL=0
fi
COMPILATION_CONFIG="${COMPILATION_CONFIG:-}"
if [[ -n "$COMPILATION_CONFIG" ]]; then
  COMPILATION_FLAG="'--compilation-config', '${COMPILATION_CONFIG}',"
else
  COMPILATION_FLAG=""
fi
# Only propagate NPU_LLM_MODE into the container when the caller set it explicitly.
llm_mode_export=""
if [[ -n "${NPU_LLM_MODE:-}" ]]; then
  llm_mode_export="export NPU_LLM_MODE=${NPU_LLM_MODE}"
fi
TAG="$(date +%H%M%S)"

[[ -x "$MS_PY" ]] || { echo "missing $MS_PY — extract mindspeed llm_test env first"; exit 1; }
[[ -d "$VLLM_WS/vllm" ]] || { echo "missing $VLLM_WS"; exit 1; }

docker rm -f "$NAME" 2>/dev/null || true
pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
sleep 2

shm_args=()
[[ -n "$SHM_SIZE" ]] && shm_args=(--shm-size="$SHM_SIZE")

lim=""
preload_export=""
if [[ -n "${SO_REL:-}" ]]; then
  preload_export="export LD_PRELOAD=/opt/ft/${SO_REL}/libvnpu.so"
  [[ "$USE_LIMITER" == "1" ]] && lim="/opt/ft/${SO_REL}/limiter > /opt/ft/kylin/logs/limiter-native-ms-${TAG}.log 2>&1 & sleep 3"
fi

docker run -d --name "$NAME" --privileged --network host "${shm_args[@]}" \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
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
${preload_export}
export NPU_MEM_QUOTA=${NPU_MEM_QUOTA:-16000} NPU_PRIORITY=${NPU_PRIORITY:-25} NPU_FIXED_SHARE_RATIO=${NPU_FIXED_SHARE_RATIO:-0}
export NPU_KYLIN_PRESET=${NPU_KYLIN_PRESET:-1}
export NPU_KYLIN_LITE=${NPU_KYLIN_LITE:-1}
export VXPU_ORIGIN_COMPAT=${VXPU_ORIGIN_COMPAT:-0}
export VXPU_COMPUTE_LIMIT=${VXPU_COMPUTE_LIMIT:-1}
export VXPU_ACL_MEMINFO_HOOK=${VXPU_ACL_MEMINFO_HOOK:-1}
export VXPU_SYNC_HOOK=${VXPU_SYNC_HOOK:-1}
export VXPU_MEMINFO_USE_DCMI=${VXPU_MEMINFO_USE_DCMI:-0} VXPU_ENABLE_MALLOC_QUOTA=${VXPU_ENABLE_MALLOC_QUOTA:-0}
export VXPU_MEMINFO_TRACE=${VXPU_MEMINFO_TRACE:-0}
export NPU_FCSP_REFILL=${NPU_FCSP_REFILL:-0}
export NPU_BURST_CONTINUOUS=${NPU_BURST_CONTINUOUS:-1}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
export NPU_BURST_ALPHA=${NPU_BURST_ALPHA:-0.3} NPU_TOKEN_CHUNK=${NPU_TOKEN_CHUNK:-32}
export NPU_KERNEL_BURST=${NPU_KERNEL_BURST:-1}
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2 TORCH_COMPILE_DISABLE=${COMPILE_DISABLE_VAL}
export RUST_LOG=${RUST_LOG_LEVEL}
${llm_mode_export}
export NPU_GLOBAL_SHM_PATH=${NPU_GLOBAL_SHM_PATH:-/hami-shared-region/global_registry_kylin_native_ms_${TAG}}
export NPU_LOCAL_SHM_NAME=${NPU_LOCAL_SHM_NAME:-vnpu_kylin_native_ms_${TAG}}
echo runtime=\$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)
echo python_stack=mindspeed-openeuler-py3.10 SO=${SO_REL:-none}
TRITON=/tmp/ms-run/lib/python3.10/site-packages/triton
[[ -d \"\$TRITON\" ]] && mv \"\$TRITON\" \"\${TRITON}.disabled\" || true
rm -f /dev/shm/vnpu_kylin_native_ms_${TAG} 2>/dev/null || true
rm -f /hami-shared-region/local_shmem/vnpu_kylin_native_ms_${TAG} 2>/dev/null || true
mkdir -p /hami-shared-region/local_shmem 2>/dev/null || true
${lim}
/tmp/ms-run/bin/python -c 'import torch,torch_npu; import acl; print(\"stack_ok\")' || exit 1
exec /tmp/ms-run/bin/python -c \"
import sys, runpy
sys.path.insert(0, '/opt/py310-site')
sys.argv = [
  'api_server', '--model=/models', '--trust-remote-code',
  '--distributed-executor-backend', 'mp', '--tensor-parallel-size', '1',
  '--pipeline-parallel-size', '1', '--disable-frontend-multiprocessing',
  '--port', '${PORT}', '--host', '0.0.0.0',
  '--gpu-memory-utilization', '${GPU_MEM_UTIL}', '--max-num-seqs', '${MAX_NUM_SEQS}',
  '--served-model-name', 'qwen3', '--dtype', 'bfloat16',
  '--max_model_len', '${MAX_MODEL_LEN}', '--max-num-batched-tokens', '${MAX_BATCHED}',
  '--enable-auto-tool-choice', '--tool-call-parser', 'hermes',
  '--no-enable_expert_parallel', '--block-size', '128',
  '--async-scheduling', '--distributed_executor_backend', 'mp',
  ${EAGER_FLAG} ${COMPILATION_FLAG} '--no-enable-prefix-caching',
]
runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
\"
"

echo "waiting health :${PORT} ..."
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "health_ok elapsed=$((SECONDS))s"
    docker logs "$NAME" 2>&1 | grep -E 'runtime=|python_stack|Application startup' | tail -6
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "container exited"; docker logs "$NAME" 2>&1 | tail -60; exit 1
  fi
  sleep 10
done
docker logs "$NAME" 2>&1 | tail -60
exit 1
