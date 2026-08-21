#!/usr/bin/env bash
set -euo pipefail
docker ps -aq --filter 'name=vnpu-oe-sweep-' | xargs -r docker rm -f >/dev/null 2>&1 || true
docker ps -aq --filter 'name=vnpu-kylin-native-' | xargs -r docker rm -f >/dev/null 2>&1 || true
pkill -f 'vllm.entrypoints.openai.api_server.*--port 18020' 2>/dev/null || true
pkill -f 'vllm.entrypoints.openai.api_server.*--port 18120' 2>/dev/null || true
sleep 3
exec bash /mnt/local/compare_perf_openeuler_fcsp_sweep_68.sh
