#!/usr/bin/env bash
# Shared Kylin vLLM startup (hard/soft)
set -eo pipefail
PORT="${VLLM_PORT:-18125}"
SO_PATH="${VNPU_SO_PATH:-/opt/ft/kylin/release-jun24-snapshot/libvnpu.so}"
DRIVER_LIB="/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64"
rm -rf /tmp/ms-run && cp -a /opt/ms-conda /tmp/ms-run
export LD_LIBRARY_PATH=/tmp/ms-run/lib:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/lib64
export ASCEND_PROCESS_LOG_PATH=/tmp/vllmlog
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site:/usr/local/Ascend/ascend-toolkit/latest/python/site-packages
export ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 HCCL_OP_EXPANSION_MODE=AIV
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True OMP_NUM_THREADS=1
export VLLM_ASCEND_ENABLE_DENSE_OPTIMIZE=1 VLLM_ASCEND_ENABLE_NZ=2
TRITON=/tmp/ms-run/lib/python3.10/site-packages/triton
[[ -d "$TRITON" ]] && mv "$TRITON" "${TRITON}.disabled" || true
/tmp/ms-run/bin/python -c 'import torch,torch_npu; import acl; print("stack_ok")'
if [[ "${VNPU_SOFT:-0}" == "1" ]]; then
  export LD_LIBRARY_PATH="${DRIVER_LIB}:${LD_LIBRARY_PATH:-}"
  exec env LD_PRELOAD="${SO_PATH}" /tmp/ms-run/bin/python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port "$PORT" --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 --max-num-seqs 4 --served-model-name qwen3 \
  --dtype bfloat16 --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
else
  exec /tmp/ms-run/bin/python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code \
  --distributed-executor-backend mp --tensor-parallel-size 1 --pipeline-parallel-size 1 \
  --disable-frontend-multiprocessing --port "$PORT" --host 0.0.0.0 \
  --gpu-memory-utilization 0.5 --max-num-seqs 4 --served-model-name qwen3 \
  --dtype bfloat16 --max_model_len 4096 --max-num-batched-tokens 4096 \
  --enable-auto-tool-choice --tool-call-parser hermes --no-enable_expert_parallel \
  --block-size 128 --async-scheduling --distributed_executor_backend mp \
  --enforce-eager --no-enable-prefix-caching
fi
