#!/usr/bin/env bash
# ais_bench perf against vLLM in Kylin-track container (sidecar).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
OE="${FT}/openeuler"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
IMAGE="${KYLIN_AISBENCH_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VLLM_CONTAINER="${VLLM_CONTAINER:-vnpu-kylin-perf-release}"
PORT="${VLLM_PORT:-18103}"
MODEL="${SERVED_MODEL:-qwen3}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
TS="$(date +%Y%m%d_%H%M%S)"
LABEL="${LABEL:-}"
OUT_TAG="${OUT_TAG:-${LABEL:+${LABEL}_}${TS}}"
CFG="${KY}/aisbench_cfg"
MODEL_CFG="${CFG}/models/vllm_api_qwen3_perf.py"
LOG="${KY}/logs/aisbench_perf_${OUT_TAG}.log"

mkdir -p "${CFG}/models" "${KY}/logs"

docker ps --format '{{.Names}}' | grep -qx "$VLLM_CONTAINER" || { echo "need $VLLM_CONTAINER running"; exit 1; }
curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null || { echo "vLLM :${PORT} unhealthy"; exit 1; }

cat > "${MODEL_CFG}" <<EOF
from ais_bench.benchmark.models import VLLMCustomAPIChatStream
from ais_bench.benchmark.utils.model_postprocessors import extract_non_reasoning_content

models = [
    dict(
        attr="service",
        type=VLLMCustomAPIChatStream,
        abbr='vllm-api-stream-chat',
        path="/models",
        model="${MODEL}",
        request_rate=0,
        retry=2,
        host_ip="127.0.0.1",
        host_port=${PORT},
        max_out_len=500,
        batch_size=4,
        concurrency=4,
        trust_remote_code=True,
        generation_kwargs=dict(
            temperature=0.01,
            ignore_eos=True,
        ),
        pred_postprocessor=dict(type=extract_non_reasoning_content),
    )
]
EOF

echo "=== ais_bench kylin-track -> 127.0.0.1:${PORT} model=${MODEL} ===" | tee "$LOG"

docker run --rm --network host \
  -v "${BENCH}:/benchmark" \
  -v "${CFG}:/aisbench_cfg:ro" \
  -v "${FT}/models/Qwen3-1.7B:/models:ro" \
  -v "/usr/local/lib/python3.10/dist-packages:/host-py:ro" \
  "$IMAGE" \
  bash -eo pipefail -c "
export PYTHONPATH=/benchmark:/host-py
export TORCH_DEVICE_BACKEND_AUTOLOAD=0
PY=/root/miniconda3/envs/llm_test/bin/python
cd /benchmark
\$PY -m ais_bench.benchmark.cli.main \\
  --models vllm_api_qwen3_perf \\
  --datasets demo_gsm8k_gen_0_shot_cot_str_perf \\
  --mode perf \\
  --num-prompts ${NUM_PROMPTS} \\
  --config-dir /aisbench_cfg \\
  -w /benchmark/outputs/kylin_vllm_${OUT_TAG}
" 2>&1 | tee -a "$LOG"

CSV="$(find "${BENCH}/outputs" -path "*kylin_vllm_${OUT_TAG}*" -name '*.csv' 2>/dev/null | head -1)"
OUT_DIR="$(dirname "$(dirname "$CSV")" 2>/dev/null || true)"
if [[ -n "$CSV" ]]; then
  echo "=== PERF CSV: $CSV ===" | tee -a "$LOG"
  echo "=== OUTPUT DIR: $OUT_DIR ===" | tee -a "$LOG"
  cat "$CSV" | tee -a "$LOG"
else
  echo "=== no csv output, see $LOG ==="
  exit 1
fi
