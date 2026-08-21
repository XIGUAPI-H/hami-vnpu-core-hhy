#!/usr/bin/env bash
# A/B: industry-methods v9 (elastic + iteration + FIKIT) vs origin on node 68.
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
ROOT="${HAMIVNPU_ROOT:-/mnt/local/m00953550/hami-vnpu-core}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT="${VLLM_PORT:-18020}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${OE}/logs/perf_oe_industry_v9_${TAG}.txt"
OPT_REL="${OPT_REL:-release-optimized}"
ORIGIN_REL="${ORIGIN_REL:-release-origin}"

echo "=== build industry v9 ==="
bash "${ROOT}/scripts/build_oe_turbo_68.sh" "${ROOT}"

# Full industry stack env (vCANN-RT elastic + Salus iteration + FIKIT measure split)
export TURBO_ENV='export NPU_LLM_MODE=1 NPU_SCHED_POLICY=elastic NPU_ITERATION_SCHED=1 NPU_FIKIT_MODE=1 NPU_LLM_BURST=1 NPU_TOKEN_CHUNK=1 NPU_FCSP_REFILL=1 NPU_FCSP_REFILL_INTERVAL_US=50 NPU_BURST_CONTINUOUS=1 NPU_BURST_ALPHA=0.3'

bash "${ROOT}/scripts/compare_perf_oe_turbo_68.sh" 2>&1 | tee "${REPORT}"
echo "report: ${REPORT}"
