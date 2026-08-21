#!/usr/bin/env bash
# 4-pod concurrent curl perf + aggregate throughput.
set -uo pipefail
TAG="${1:?usage: $0 TAG}"
BASE_PORT=18151
REQUESTS="${REQUESTS:-16}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_TOKENS="${MAX_TOKENS:-512}"
FT="${FT:-/mnt/local/m00953550/FinalTest}"
REPORT="${FT}/kylin/logs/4pod_curl_perf_${TAG}.txt"

bench_one() {
  local idx=$1 port=$2
  local tmpdir start end elapsed total=0
  tmpdir=$(mktemp -d)
  start=$(date +%s.%N)
  local i=0
  while (( i < REQUESTS )); do
    local batch=0
    while (( batch < CONCURRENCY && i < REQUESTS )); do
      local rid=$i
      (
        resp=$(curl -sf "http://127.0.0.1:${port}/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"性能测试pod${idx}请求${rid}\"}],\"max_tokens\":${MAX_TOKENS},\"temperature\":0.01}")
        tok=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("usage",{}).get("completion_tokens",0))' 2>/dev/null || echo 0)
        echo "$tok" > "${tmpdir}/r${rid}.tok"
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
    total=$((total + $(cat "$f")))
  done
  rm -rf "${tmpdir}"
  python3 -c "print(f'{$total/$elapsed:.2f}')"
}

{
  echo "=== 4pod curl perf TAG=${TAG} ==="
  echo "requests=${REQUESTS} concurrency=${CONCURRENCY} max_tokens=${MAX_TOKENS}"
  echo "--- npu-smi proc-mem card1 ---"
  npu-smi info -t proc-mem -i 1 2>/dev/null | grep -E 'Process|HBM Usage' || true
  echo ""
  for i in 0 1 2 3; do
    bench_one "${i}" "$((BASE_PORT + i))" > "/tmp/4pod_tps_${TAG}_${i}.txt" &
  done
  wait
  agg=0
  for i in 0 1 2 3; do
    tps=$(cat "/tmp/4pod_tps_${TAG}_${i}.txt")
    echo "pod${i} port=$((BASE_PORT + i)) tok_s=${tps}"
    agg=$(python3 -c "print(float('${agg}')+float('${tps}'))")
  done
  echo "aggregate_tok_s=${agg}"
  echo "=== shm scan ==="
  total_shm=0
  for i in 0 1 2 3; do
    shm=$(docker logs "vnpu-4pod-${i}-${TAG}" 2>&1 | grep -c "No available shared memory" || true)
    total_shm=$((total_shm + shm))
    echo "pod${i} shm_broadcast=${shm}"
  done
  echo "TOTAL shm_broadcast=${total_shm}"
} 2>&1 | tee "${REPORT}"
echo "report: ${REPORT}"
