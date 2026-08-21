#!/usr/bin/env bash
# Concurrent curl stress on 4 running vnpu-4pod containers; scan shm_broadcast.
set -uo pipefail
TAG="${1:?usage: $0 TAG}"
BASE_PORT=18151
for i in 0 1 2 3; do
  port=$((BASE_PORT + i))
  (
    for r in $(seq 1 6); do
      for c in 1 2 3 4; do
        idx="${i}-${r}-${c}"
        curl -sf "http://127.0.0.1:${port}/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"qwen3\",\"messages\":[{\"role\":\"user\",\"content\":\"压力${idx}\"}],\"max_tokens\":256,\"temperature\":0.01}" >/dev/null &
      done
      wait
    done
    echo "pod${i} curl_done"
  ) &
done
wait
echo "=== post-curl crash scan TAG=${TAG} ==="
total_shm=0 total_fatal=0
for i in 0 1 2 3; do
  name="vnpu-4pod-${i}-${TAG}"
  shm=$(docker logs "${name}" 2>&1 | grep -c "No available shared memory" || true)
  fatal=$(docker logs "${name}" 2>&1 | grep -c "EngineCore.*fatal\|EngineCore proc.*died" || true)
  total_shm=$((total_shm + shm))
  total_fatal=$((total_fatal + fatal))
  echo "pod${i}: shm_broadcast=${shm} engine_fatal=${fatal}"
done
echo "TOTAL shm=${total_shm} fatal=${total_fatal}"
