#!/usr/bin/env bash
# Merge wheels-full into py310-site for openEuler container vLLM.
set -euo pipefail
OE="${OE:-/mnt/local/m00953550/FinalTest/openeuler}"
WHEELS="${WHEELS:-${OE}/wheels-full}"
SITE="${SITE:-${OE}/py310-site}"
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"

[[ -d "$WHEELS" ]] && ls "$WHEELS"/*.whl >/dev/null 2>&1 || { echo "no wheels in $WHEELS"; exit 1; }

mkdir -p "$SITE"
docker run --rm \
  -v "${WHEELS}:/wheels:ro" \
  -v "${SITE}:/target" \
  -v "${OE}/vllm-workspace:/vllm-workspace:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  "$IMAGE" \
  bash -c '
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
PY=/root/miniconda3/envs/llm_test/bin/python
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend
shopt -s nullglob
skip=(pydantic pydantic_core torch torch_npu numpy transformers tokenizers safetensors huggingface_hub)
for w in /wheels/*.whl; do
  base=$(basename "$w")
  skip_it=0
  for s in "${skip[@]}"; do [[ "$base" == $s* ]] && skip_it=1 && break; done
  [[ $skip_it -eq 1 ]] && continue
  $PY -m pip install --no-index --find-links=/wheels --target=/target --no-deps "$w" -q 2>/dev/null || true
done
PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/target $PY -c "
import sys; sys.path.insert(0,\"/target\")
from vllm.entrypoints.openai import api_server
print(\"api_server import OK\")
" 2>&1 | tail -20
'
