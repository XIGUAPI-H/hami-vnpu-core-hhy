#!/usr/bin/env bash
# Run on labest-m1 (openEuler 22.03 SP4): vLLM + Ubuntu-built libvnpu.so/limiter
# Usage:
#   export VNPU_DIR=/path/to/FinalTest   # dir with libvnpu.so + limiter (61/Ubuntu build)
#   export MODEL_PATH=/path/to/Qwen3-1.7B
#   bash run_vllm_ubuntu_so_labest.sh
set -euo pipefail

VNPU_DIR="${VNPU_DIR:-$(pwd)}"
MODEL_PATH="${MODEL_PATH:-/models}"
PORT="${VLLM_PORT:-8000}"
NPU_DEVICE="${ASCEND_RT_VISIBLE_DEVICES:-0}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
LOG_DIR="${VNPU_DIR}/logs"
WAIT_SECS="${WAIT_SECS:-900}"

mkdir -p "$LOG_DIR"

echo "=== labest-m1 / openEuler: Ubuntu so + vLLM ==="
echo "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
echo "arch: $(uname -m)  python: $(python3 --version 2>/dev/null || true)"
echo "vnpu: ${VNPU_DIR}/libvnpu.so"
echo "model: ${MODEL_PATH}"
echo "npu:   ${NPU_DEVICE}  port: ${PORT}"

for f in "${VNPU_DIR}/libvnpu.so" "${VNPU_DIR}/limiter"; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done

echo "--- GLIBC (Ubuntu so) ---"
objdump -T "${VNPU_DIR}/libvnpu.so" | grep GLIBC | sed 's/.*GLIBC/Glibc/' | sort -Vu | tail -3

echo "--- link check ---"
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"
if [[ -f /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash ]]; then
  # shellcheck disable=SC1091
  source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
fi
if [[ -f /usr/local/Ascend/nnal/atb/set_env.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/Ascend/nnal/atb/set_env.sh
fi
ldd "${VNPU_DIR}/limiter" | head -5

export LD_PRELOAD="${VNPU_DIR}/libvnpu.so"
export VLLM_PLATFORM=ascend
export ASCEND_RT_VISIBLE_DEVICES="${NPU_DEVICE}"
export NPU_GLOBAL_SHM_PATH="${HAMi_SHM}/global_registry_labest_ubuntu_so"
export NPU_LOCAL_SHM_NAME="vnpu_labest_ubuntu_so"
export NPU_MEM_QUOTA=16000
export NPU_PRIORITY=25
export TASK_QUEUE_ENABLE=1
export VLLM_USE_V1=1
export HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1
export VLLM_ASCEND_ENABLE_NZ=2

rm -f "/dev/shm/${NPU_LOCAL_SHM_NAME}" 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
"${VNPU_DIR}/limiter" > "${LOG_DIR}/limiter.log" 2>&1 &
sleep 2
pgrep -x limiter || { cat "${LOG_DIR}/limiter.log"; exit 1; }

python3 -c "import torch, torch_npu; print('torch', torch.__version__, 'npu', torch_npu.__version__)"
python3 -c "import vllm; print('vllm', vllm.__version__)"

echo "--- starting vLLM ---"
python3 -m vllm.entrypoints.openai.api_server \
  --model="${MODEL_PATH}" \
  --trust-remote-code \
  --distributed-executor-backend mp \
  --tensor-parallel-size 1 \
  --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing \
  --port "${PORT}" \
  --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 \
  --max-num-seqs 4 \
  --served-model-name qwen3 \
  --dtype bfloat16 \
  --max_model_len 4096 \
  --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --no-enable_expert_parallel \
  --block-size 128 \
  --async-scheduling \
  --distributed_executor_backend mp \
  --compilation-config '{"cudagraph_mode": "FULL_DECODE_ONLY","cudagraph_capture_sizes":[1]}' \
  --no-enable-prefix-caching \
  > "${LOG_DIR}/vllm.log" 2>&1 &

vllm_pid=$!
echo "vLLM pid=$vllm_pid log=${LOG_DIR}/vllm.log"

deadline=$((SECONDS + WAIT_SECS))
while (( SECONDS < deadline )); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "=== PASS: vLLM up on :${PORT} (Ubuntu so on openEuler) ==="
    curl -s "http://127.0.0.1:${PORT}/v1/models" | head -c 300; echo
    grep -E 'vnpu|Application startup' "${LOG_DIR}/vllm.log" | tail -5 || true
    exit 0
  fi
  if ! kill -0 "$vllm_pid" 2>/dev/null; then
    echo "=== FAIL: vLLM exited ==="
    tail -40 "${LOG_DIR}/vllm.log"
    exit 1
  fi
  if grep -q 'Application startup complete' "${LOG_DIR}/vllm.log" 2>/dev/null; then
    echo "=== PASS (startup log) ==="
    exit 0
  fi
  sleep 10
done
echo "=== TIMEOUT ==="
tail -40 "${LOG_DIR}/vllm.log"
exit 1
