#!/usr/bin/env bash
# Origin hijack lib + /dev/shm=32g in Kylin container; reproduce shm_broadcast.
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
ROOT="${ROOT:-/mnt/local/m00953550/hami-vnpu-core}"
RUN_VLLM="${RUN_VLLM:-${ROOT}/scripts/run_kylin_native_vllm_ms_68.sh}"
SO_REL="${SO_REL:-kylin/release-origin}"
SHM_SIZE="${SHM_SIZE:-32g}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-1}"
PORT="${VLLM_PORT:-18250}"
STRESS_SEC="${STRESS_SEC:-300}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-512}"
MODE="${MODE:-aclgraph}"   # aclgraph | eager
TAG="$(date +%Y%m%d_%H%M%S)"
NAME="vnpu-origin-shm32-${MODE}-${TAG}"
REPORT="${KY}/logs/origin_shm32_${MODE}_${TAG}.txt"

export SHM_SIZE SO_REL VLLM_PORT="$PORT" VLLM_NAME="$NAME" USE_LIMITER=1
export ASCEND_RT_VISIBLE_DEVICES="$NPU"
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
export NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_TOKEN_CHUNK=8
export NPU_KERNEL_BURST=1 NPU_BURST_CONTINUOUS=1
export NPU_KYLIN_LITE=0 NPU_KYLIN_PRESET=0
export VXPU_ORIGIN_COMPAT=1 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=0
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_origin_shm32_${TAG}"
export NPU_LOCAL_SHM_NAME="origin_shm32_${TAG}"
export MAX_NUM_SEQS=4 GPU_MEM_UTIL=0.5 MAX_MODEL_LEN=4096 MAX_BATCHED=4096

if [[ "$MODE" == "aclgraph" ]]; then
  export ENFORCE_EAGER=0
  export COMPILATION_CONFIG='{"cudagraph_mode": "FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,2,4,8,16]}'
else
  export ENFORCE_EAGER=1
  unset COMPILATION_CONFIG
fi

{
  echo "=== origin + shm=${SHM_SIZE} mode=${MODE} ${TAG} ==="
  sha256sum "${FT}/${SO_REL}/libvnpu.so" "${FT}/${SO_REL}/limiter" 2>/dev/null || true
  echo "fixed=1 FCSP=1 token_chunk=8 priority=25 mem_quota=16000"
  echo ""

  bash "$RUN_VLLM" 2>&1 | tee "${KY}/logs/origin_shm32_vllm_${MODE}_${TAG}.log" || {
    echo "FAIL: vLLM startup"
    docker logs "$NAME" 2>&1 | tail -40
    exit 1
  }

  docker exec "$NAME" df -h /dev/shm 2>/dev/null || true
  echo "HEALTH_OK"

  curl -sf "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":64}' >/dev/null || true

  echo "--- stress ${STRESS_SEC}s concurrency=${CONCURRENCY} ---"
  tmp=$(mktemp -d); start=$(date +%s); reqs=0
  while (( $(date +%s) - start < STRESS_SEC )); do
    for ((b=0; b<CONCURRENCY; b++)); do
      rid=$reqs
      ( curl -sf --max-time 180 "http://127.0.0.1:${PORT}/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"压测${rid}\"}],\"max_tokens\":${MAX_TOKENS},\"temperature\":0.01}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("usage",{}).get("completion_tokens",0))' \
          > "${tmp}/t${rid}" 2>/dev/null || echo 0 > "${tmp}/t${rid}" ) &
      reqs=$((reqs+1))
    done
    wait
  done
  tok=0; for f in "${tmp}"/t*; do [[ -f "$f" ]] && tok=$((tok+$(cat "$f"))); done
  rm -rf "$tmp"
  elapsed=$(( $(date +%s) - start ))
  echo "stress reqs=${reqs} tokens=${tok} tok_s=$(python3 -c "print(f'{$tok/max($elapsed,1):.2f}')")"

  shm=$(docker logs "$NAME" 2>&1 | grep -c "No available shared memory" || true)
  fatal=$(docker logs "$NAME" 2>&1 | grep -cE "EngineCore.*fatal|sample_tokens timed out" || true)
  echo "shm_broadcast=${shm} fatal=${fatal}"
  [[ "$shm" -gt 0 ]] && echo ">>> REPRODUCED"

  docker logs "$NAME" 2>&1 | grep -n "No available shared memory" || echo "(no shm_broadcast lines)"
} 2>&1 | tee "$REPORT"
echo "report: $REPORT"
