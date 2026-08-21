#!/usr/bin/env bash
set -euo pipefail
docker ps -aq --filter 'name=vnpu-kylin-native-' | xargs -r docker rm -f 2>/dev/null || true
pkill -f 'vllm.entrypoints.openai.api_server.*--port 18120' 2>/dev/null || true
sleep 3
export SCENARIOS="fcsp0_burst_off fcsp0_chunk8 fcsp0_meminfo_trace fcsp1_baseline"
exec bash /mnt/local/compare_perf_kylin_native_sweep_68.sh
