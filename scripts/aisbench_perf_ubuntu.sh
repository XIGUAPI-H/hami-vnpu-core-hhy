#!/usr/bin/env bash
# ais_bench performance on Ubuntu host against running vLLM.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
UB="${FT}/ubuntu"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
PORT="${VLLM_PORT:-18003}"
MODEL="${SERVED_MODEL:-qwen3}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
CONCURRENCY="${CONCURRENCY:-4}"
BATCH_SIZE="${BATCH_SIZE:-4}"
MAX_OUT_LEN="${MAX_OUT_LEN:-500}"
TS="$(date +%Y%m%d_%H%M%S)"
LABEL="${LABEL:-}"
OUT_TAG="${OUT_TAG:-${LABEL:+${LABEL}_}${TS}}"
CFG="${UB}/aisbench_cfg"
MODEL_CFG="${CFG}/models/vllm_api_qwen3_perf.py"
OUT="${BENCH}/outputs/ubuntu_vllm_${OUT_TAG}"
LOG="${UB}/logs/aisbench_perf_${OUT_TAG}.log"

mkdir -p "${CFG}/models" "${UB}/logs"

curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null || { echo "vLLM :${PORT} unhealthy"; exit 1; }

cat > "${MODEL_CFG}" <<EOF
from ais_bench.benchmark.models import VLLMCustomAPIChatStream
from ais_bench.benchmark.utils.model_postprocessors import extract_non_reasoning_content

models = [
    dict(
        attr="service",
        type=VLLMCustomAPIChatStream,
        abbr='vllm-api-stream-chat',
        path="/mnt/project/mhw_68/m00953550/Qwen3-1.7B",
        model="${MODEL}",
        request_rate=0,
        retry=2,
        host_ip="127.0.0.1",
        host_port=${PORT},
        max_out_len=${MAX_OUT_LEN},
        batch_size=${BATCH_SIZE},
        concurrency=${CONCURRENCY},
        trust_remote_code=True,
        generation_kwargs=dict(
            temperature=0.01,
            ignore_eos=True,
        ),
        pred_postprocessor=dict(type=extract_non_reasoning_content),
    )
]
EOF

echo "=== ais_bench perf (Ubuntu) -> 127.0.0.1:${PORT} model=${MODEL} ===" | tee "$LOG"

export PYTHONPATH="${BENCH}:${PYTHONPATH:-}"

cd "$BENCH"
# HTTP client only — hide NPU so host limiters don't trip torch_npu init
env -u LD_PRELOAD \
  ASCEND_RT_VISIBLE_DEVICES=-1 \
  TORCH_DEVICE_BACKEND_AUTOLOAD=0 \
  python3 -m ais_bench.benchmark.cli.main \
  --models vllm_api_qwen3_perf \
  --datasets demo_gsm8k_gen_0_shot_cot_str_perf \
  --mode perf \
  --num-prompts "${NUM_PROMPTS}" \
  --config-dir "${CFG}" \
  -w "${OUT}" 2>&1 | tee -a "$LOG"

CSV="$(find "${BENCH}/outputs" -path "*ubuntu_vllm_${OUT_TAG}*" -name '*.csv' 2>/dev/null | head -1)"
if [[ -n "$CSV" ]]; then
  echo "=== PERF CSV: $CSV ===" | tee -a "$LOG"
  cat "$CSV" | tee -a "$LOG"
else
  echo "=== no csv output, see $LOG ==="
  exit 1
fi
