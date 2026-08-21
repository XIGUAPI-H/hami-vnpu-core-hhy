#!/usr/bin/env bash
set -eo pipefail
FT="/mnt/local/m00953550/FinalTest"
OE="${FT}/openeuler"
IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"
docker run --rm --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES=2 \
  -v "${FT}:/opt/ft" \
  -v "${OE}/vllm-workspace:/vllm-workspace:ro" \
  -v "${OE}/py310-site:/opt/py310-site:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" bash -c '
set -exo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
TRITON_PKG=/root/miniconda3/envs/llm_test/lib/python3.10/site-packages/triton
[[ -d "$TRITON_PKG" && ! -d "${TRITON_PKG}.disabled" ]] && mv "$TRITON_PKG" "${TRITON_PKG}.disabled" || true
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_ubuntu_so_oe_vllm2
export NPU_LOCAL_SHM_NAME=vnpu_ubuntu_so_oe_vllm2
rm -f /dev/shm/${NPU_LOCAL_SHM_NAME} 2>/dev/null || true
/opt/ft/limiter > /tmp/lim.log 2>&1 & sleep 5
echo "pgrep:"; pgrep -af limiter || true
cat /tmp/lim.log
'
