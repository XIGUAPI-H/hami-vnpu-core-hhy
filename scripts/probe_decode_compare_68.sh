#!/usr/bin/env bash
# Compare decode: baseline vs ubuntu SO vs kylin SO on 68.
set -euo pipefail

FT=/mnt/local/m00953550/FinalTest
PORT="${VLLM_PORT:-18114}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
MODEL=/mnt/local/m00953550/Qwen3-1.7B
TAG=$(date +%H%M%S)
LOG_DIR="${FT}/kylin/logs"
mkdir -p "$LOG_DIR"
OUT="${LOG_DIR}/probe_decode_compare_${TAG}.log"
exec > >(tee -a "$OUT") 2>&1

run_probe() {
  local label="$1"
  local so_path="${2:-}"   # full path inside container e.g. /opt/ft/ubuntu/release-optimized
  local use_limiter="${3:-0}"
  local name="vnpu-probe-${label}"

  docker rm -f "$name" 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 2

  local preload_args=()
  local limiter_block=""
  if [[ -n "$so_path" ]]; then
    preload_args=(-e "LD_PRELOAD=${so_path}/libvnpu.so")
    if [[ "$use_limiter" == "1" ]]; then
      limiter_block="${so_path}/limiter > ${LOG_DIR}/limiter-${label}-${TAG}.log 2>&1 & sleep 3"
    fi
  fi

  echo "========== PROBE ${label} so=${so_path:-none} limiter=${use_limiter} =========="
  docker run -d --name "$name" --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    "${preload_args[@]}" \
    -e LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64" \
    -e VLLM_PLATFORM=ascend \
    -v "${FT}:/opt/ft" \
    -v "${MODEL}:/models:ro" \
    -v /usr/local/Ascend:/usr/local/Ascend:ro \
    -v /etc/hccn.conf:/etc/hccn.conf:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v /usr/local/hami-shared-region:/hami-shared-region \
    -v /dev/davinci_manager:/dev/davinci_manager \
    -v /dev/devmm_svm:/dev/devmm_svm \
    -v /dev/hisi_hdc:/dev/hisi_hdc \
    quay.io/ascend/vllm-ascend:v0.13.0rc1 \
    bash -c "set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:\$LD_LIBRARY_PATH
source /usr/local/Ascend/nnal/atb/set_env.sh
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_FCSP_REFILL=1 NPU_BURST_CONTINUOUS=1
export TASK_QUEUE_ENABLE=1 VLLM_USE_V1=1 TORCH_COMPILE_DISABLE=1
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_probe_${label}_${TAG}
export NPU_LOCAL_SHM_NAME=vnpu_probe_${label}_${TAG}
${limiter_block}
exec python -m vllm.entrypoints.openai.api_server \
  --model=/models --trust-remote-code --port ${PORT} --host 0.0.0.0 \
  --distributed-executor-backend mp --tensor-parallel-size 1 \
  --disable-frontend-multiprocessing --gpu-memory-utilization 0.5 \
  --max-num-seqs 4 --served-model-name qwen3 --dtype bfloat16 \
  --max_model_len 4096 --max-num-batched-tokens 4096 --enforce-eager \
  --block-size 128 --async-scheduling
"

  local ok=0
  for _ in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then ok=1; break; fi
    sleep 5
  done
  if [[ "$ok" != "1" ]]; then
    echo "HEALTH_FAIL"
    docker logs "$name" 2>&1 | tail -80
    docker rm -f "$name" 2>/dev/null || true
    return 1
  fi
  echo "health_ok"

  curl -s -w "\nHTTP:%{http_code}\n" "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":32,"stream":false,"temperature":0.01}' \
    | head -c 2000
  echo ""

  echo "--- errors (worker/engine/acl) ---"
  docker logs "$name" 2>&1 | grep -iE 'Worker|EngineCore|Traceback|Error|Exception|SIG|abort|limiter|acl|ACL|RuntimeError|killed|segfault' | tail -100

  echo "--- full traceback blocks ---"
  docker logs "$name" 2>&1 | awk '/Traceback/{p=1} p{print} /^[^ ]/{if(p&&NR>1&&!/Traceback/) exit}' | tail -200 || true

  docker rm -f "$name" 2>/dev/null || true
  sleep 3
}

run_probe baseline "" 0 || true
run_probe ubuntu-opt /opt/ft/ubuntu/release-optimized 1 || true
run_probe kylin-opt /opt/ft/kylin/release-optimized 1 || true

echo "DONE log=$OUT"
