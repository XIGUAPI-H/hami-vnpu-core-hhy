#!/usr/bin/env bash
set -euo pipefail

KY=/mnt/local/m00953550/FinalTest/kylin
IMAGE=kylin-server:v11-2503-arm64
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"

docker run --rm --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${KY}/vllm-extract/vllm-workspace:/vllm-workspace:ro" \
  -v "${KY}/vllm-extract/python3.11.13:/usr/local/python3.11.13:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c '
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/vllm-workspace/vllm:/vllm-workspace/vllm-ascend:/usr/local/python3.11.13/lib/python3.11/site-packages
/usr/local/python3.11.13/bin/python3.11 -c "
import torch, torch_npu
torch_npu.npu.set_device(0)
x = torch.ones(2, device=\"npu:0\")
print(\"npu_tensor_ok\", x.device)
import vllm
print(\"vllm_ok\", vllm.__version__)
"
' 2>&1 | tail -30
