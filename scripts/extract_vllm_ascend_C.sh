#!/usr/bin/env bash
# Extract prebuilt vllm_ascend_C from vllm-ascend image into vllm-workspace.
set -euo pipefail
FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
VLLM_IMAGE="${VLLM_IMAGE:-quay.io/ascend/vllm-ascend:v0.13.0rc1}"
OUT="${OE}/vllm-workspace/vllm-ascend-extras"

mkdir -p "$OUT"
docker run --rm "$VLLM_IMAGE" bash -c '
find /usr/local -path "*/vllm_ascend_C*" 2>/dev/null
find / -path "*/site-packages/vllm_ascend*" -name "*.so" 2>/dev/null | head -20
python -c "import vllm_ascend.vllm_ascend_C as m; import os; print(os.path.dirname(m.__file__))" 2>/dev/null || true
' | tee "${OE}/logs/extract_vllm_ascend_C_probe.log"

docker run --rm -v "${OUT}:/out" "$VLLM_IMAGE" bash -c '
PY=$(python -c "import site; print(site.getsitepackages()[0])")
cp -a "$PY/vllm_ascend_C" /out/ 2>/dev/null || cp -a $(python -c "import vllm_ascend.vllm_ascend_C as m; import os; print(os.path.dirname(m.__file__))") /out/vllm_ascend_C
ls -la /out/
'

echo "extracted to $OUT"
ls -la "$OUT"
