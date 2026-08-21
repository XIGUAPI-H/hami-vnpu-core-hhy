#!/usr/bin/env bash
set -euo pipefail

KY=/mnt/local/m00953550/FinalTest/kylin
IMAGE=kylin-server:v11-2503-arm64
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"

probe() {
  local label="$1"
  shift
  echo "========== $label =========="
  docker run --rm --privileged --network host \
    -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
    -v "${KY}/vllm-extract/vllm-workspace:/vllm-workspace:ro" \
    -v "${KY}/vllm-extract/python3.11.13:/usr/local/python3.11.13:ro" \
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
    -v /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro \
    -v /usr/local/Ascend/toolbox:/usr/local/Ascend/toolbox:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v /dev/davinci_manager:/dev/davinci_manager \
    -v /dev/devmm_svm:/dev/devmm_svm \
    -v /dev/hisi_hdc:/dev/hisi_hdc \
    "$@" \
    "$IMAGE" \
    bash -c '
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:${LD_LIBRARY_PATH:-}
if [[ -f /usr/local/Ascend/nnal/atb/set_env.sh ]]; then
  source /usr/local/Ascend/nnal/atb/set_env.sh
elif [[ -f /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash ]]; then
  source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
fi
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/usr/local/python3.11.13/lib/python3.11/site-packages
/usr/local/python3.11.13/bin/python3.11 -c "import torch; import torch_npu; torch_npu.npu.set_device(0); print(\"torch_npu_ok\", torch.__version__)"
' 2>&1 | tail -15
  echo ""
}

# A: driver-only mounts (no full ascend toolkit from host)
probe "A driver-only" \
  -v /usr/local/Ascend/nnal:/usr/local/Ascend/nnal:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro || true

# B: bind nnal+toolkit symlinks via selective mounts
probe "B toolkit selective" \
  -v /usr/local/Ascend/nnal:/usr/local/Ascend/nnal:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  -v /usr/local/Ascend/ascend-toolkit/latest:/usr/local/Ascend/ascend-toolkit/latest:ro || true

# C: mindspeed openEuler python in Kylin container
echo "========== C mindspeed py in kylin =========="
MS=swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm
OE=/mnt/local/m00953550/FinalTest/openeuler
docker run --rm --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${KY}/vllm-extract/vllm-workspace:/vllm-workspace:ro" \
  -v "${OE}/py310-site:/opt/py310-site:ro" \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro \
  -v /usr/local/Ascend/nnal:/usr/local/Ascend/nnal:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  kylin-server:v11-2503-arm64 \
  bash -c '
set -eo pipefail
PY=/opt/ms-py/bin/python
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/opt/py310-site
$PY -c "import torch; import torch_npu; print(\"ms_py_ok\", torch.__version__)"
' 2>&1 | tail -15 || true
