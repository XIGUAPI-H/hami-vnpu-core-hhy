#!/usr/bin/env bash
# Single-pod fixed A/B via curl (avoids host aisbench segfault).
set -uo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
RUN_VLLM="${RUN_VLLM:-/mnt/local/run_kylin_native_vllm_ms_68.sh}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18125}"
TAG="${TAG:-$(date +%Y%m%d_%H%M%S)}"
REQUESTS="${REQUESTS:-16}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_TOKENS="${MAX_TOKENS:-512}"
KERNEL_BURST="${KERNEL_BURST:-1}"
LOG="${KY}/logs/singlepod_fixed_curl_ab_${TAG}.log"

stop_all() {
  docker ps -aq --filter 'name=vnpu-spfixed-' | xargs -r docker rm -f >/dev/null 2>&1 || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

warmup() {
  curl -sf "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3","messages":[{"role":"user","content":"warmup"}],"max_tokens":128,"temperature":0.01}' >/dev/null || true
}

bench_curl() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local start end elapsed total_tokens=0 ok=0
  start=$(date +%s.%N)
  local i=0
  while (( i < REQUESTS )); do
    local batch=0
    while (( batch < CONCURRENCY && i < REQUESTS )); do
      local idx=$i
      (
        resp=$(curl -sf "http://127.0.0.1:${PORT}/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"请详细解释机器学习原理，举例说明。请求编号${idx}\"}],\"max_tokens\":${MAX_TOKENS},\"temperature\":0.01}")
        tok=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("usage",{}).get("completion_tokens",0))' 2>/dev/null || echo 0)
        echo "$tok" > "${tmpdir}/r${idx}.tok"
      ) &
      i=$((i + 1))
      batch=$((batch + 1))
    done
    wait
  done
  end=$(date +%s.%N)
  elapsed=$(python3 -c "print(float('$end')-float('$start'))")
  for f in "${tmpdir}"/r*.tok; do
    [[ -f "$f" ]] || continue
    t=$(cat "$f")
    total_tokens=$((total_tokens + t))
    ok=$((ok + 1))
  done
  rm -rf "$tmpdir"
  local tps
  tps=$(python3 -c "print(f'{$total_tokens/$elapsed:.2f}')")
  echo "requests_ok=$ok/$REQUESTS total_tokens=$total_tokens elapsed_s=$elapsed throughput_tok_s=$tps"
  echo "$tps"
}

run_one() {
  local label=$1 so_rel=$2
  local burst=$KERNEL_BURST
  local name=vnpu-spfixed-${label}-${TAG}
  stop_all
  export ASCEND_RT_VISIBLE_DEVICES=$NPU
  export VXPU_ORIGIN_COMPAT=0 VXPU_COMPUTE_LIMIT=1 VXPU_ACL_MEMINFO_HOOK=1 VXPU_SYNC_HOOK=0
  export NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=1 NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50
  export NPU_TOKEN_CHUNK=8 NPU_KERNEL_BURST=$burst NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3
  export NPU_KYLIN_PRESET=0 NPU_KYLIN_LITE=0 NPU_MEM_QUOTA=16000
  export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_spfixed_${label}_${TAG}
  export NPU_LOCAL_SHM_NAME=local_spfixed_${label}_${TAG}
  echo "=== RUN $label SO=$so_rel burst=$burst ==="
  sha256sum "${FT}/${so_rel}/libvnpu.so" 2>/dev/null || true
  SO_REL=$so_rel VLLM_PORT=$PORT VLLM_NAME=$name USE_LIMITER=1 bash "$RUN_VLLM" >"${KY}/logs/spfixed_curl_vllm_${label}_${TAG}.log" 2>&1
  warmup; warmup
  local bench_out tps
  bench_out=$(bench_curl)
  tps=$(echo "$bench_out" | tail -1)
  echo "$bench_out" | head -1
  THR[$label]=$tps
  stop_all
}

declare -A THR
mkdir -p "${KY}/logs"
{
  echo "=== single Pod fixed curl A/B ${TAG} ==="
  echo "fixed=1 prio=25 FCSP=1 chunk=8 burst=$KERNEL_BURST requests=$REQUESTS concurrency=$CONCURRENCY max_tokens=$MAX_TOKENS"
  run_one origin kylin/release-origin
  run_one optimized kylin/release-optimized
  echo ""
  echo "=== comparison (curl throughput tok/s) ==="
  echo "origin=${THR[origin]:-na} optimized=${THR[optimized]:-na}"
  if [[ -n "${THR[origin]:-}" && -n "${THR[optimized]:-}" ]]; then
    python3 -c "o=float('${THR[origin]}'); p=float('${THR[optimized]}'); print(f'delta: {((p-o)/o*100):+.1f}%')"
  fi
} 2>&1 | tee "$LOG"
echo "log: $LOG"
