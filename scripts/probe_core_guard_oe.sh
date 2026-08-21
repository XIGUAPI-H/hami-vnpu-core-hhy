#!/usr/bin/env bash
set -euo pipefail
FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
IMAGE="swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm"

docker run --rm --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${FT}:/opt/ft" \
  -v "${OE}/py310-site:/opt/py310-site:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c 'set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
export PYTHONPATH=/opt/py310-site
SO=/opt/ft/openeuler/release-optimized
export LD_PRELOAD=${SO}/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_cg_probe
export NPU_LOCAL_SHM_NAME=vnpu_cg_probe
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
export VXPU_CORE_LIMIT_PERCENT=25 VXPU_CORE_SCHEDULER=1 VXPU_WORKER_ROLE=worker
rm -f /dev/shm/'"${NPU}"' 2>/dev/null || true
${SO}/limiter >/tmp/lim.log 2>&1 & sleep 3
PY=/root/miniconda3/envs/llm_test/bin/python
${PY} -c "
import sys
sys.path.insert(0, \"/opt/py310-site\")
import torch, torch_npu
torch.npu.set_device(0)
x = torch.ones(2, 2, device=\"npu:0\")
y = x + x
torch.npu.synchronize()
print(\"ok\", float(y[0,0]))
" > /tmp/py.out 2> /tmp/py.err || true
echo "=== stdout ==="
cat /tmp/py.out
echo "=== stderr (core limiter logs here) ==="
cat /tmp/py.err
echo "=== /dev/shm ==="
ls -la /dev/shm/ | head -20
echo "=== strings check ==="
strings ${SO}/libvnpu.so | grep wait_for_token | head -3 || echo "no wait_for_token OK"
strings ${SO}/libvnpu.so | grep scheduler_thread_main | head -2
'
