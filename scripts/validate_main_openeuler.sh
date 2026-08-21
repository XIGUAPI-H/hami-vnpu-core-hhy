#!/usr/bin/env bash
# Quick smoke test for release-main artifacts in openEuler container.
set -euo pipefail
SO="${SO:-/mnt/local/m00953550/FinalTest/openeuler/release-main}"
IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"

docker run --rm --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${SO}:/opt/vnpu:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c '
set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
sha256sum /opt/vnpu/libvnpu.so /opt/vnpu/limiter | cut -c1-16
ldd /opt/vnpu/limiter | head -2
export LD_PRELOAD=/opt/vnpu/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_main_verify
export NPU_LOCAL_SHM_NAME=vnpu_main_verify
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
rm -f /dev/shm/${NPU_LOCAL_SHM_NAME} 2>/dev/null || true
/opt/vnpu/limiter > /tmp/lim.log 2>&1 & sleep 3
pgrep -f /opt/vnpu/limiter
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -c "import torch,torch_npu; torch.npu.set_device(0); x=torch.randn(128,128,device=\"npu:0\"); print(\"matmul_ok\", torch.mm(x,x).sum().item())"
echo "=== PASS release-main openEuler smoke ==="
'
