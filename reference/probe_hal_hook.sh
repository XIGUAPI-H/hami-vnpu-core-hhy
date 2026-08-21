#!/bin/bash
# Quick probe: does LD_PRELOAD libvnpu intercept halGetDeviceInfo?
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@10.143.2.68 'bash -s' <<'EOF'
LIB=/mnt/local/m00953550/FinalTest/New/release/libvnpu.so
LIM=/mnt/local/m00953550/FinalTest/New/release/limiter
cat > /tmp/probe_hal.py <<'PY'
import os, sys
os.environ.setdefault("ASCEND_RT_VISIBLE_DEVICES", "0")
try:
    import torch
    import torch_npu
    torch.npu.set_device(0)
    p = torch.npu.get_device_properties(0)
    print("props:", p)
    free, total = torch_npu.npu.mem_get_info()
    print("mem_get_info free=", free, "total=", total)
except Exception as e:
    print("ERR:", e)
    sys.exit(1)
PY

# Start limiter in background with minimal quota (same as prod)
export NPU_MEM_QUOTA=16000
export NPU_GLOBAL_SHM_PATH=/tmp/probe_shm
mkdir -p /tmp/probe_shm
$pkill -f '/tmp/probe_hal_limiter' 2>/dev/null || true
$LIM > /tmp/probe_hal_limiter.log 2>&1 &
sleep 1

docker run --rm --privileged \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v /dev/davinci0:/dev/davinci0 \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  -v /tmp/probe_hal.py:/tmp/probe_hal.py \
  -v $LIB:/opt/libvnpu.so:ro \
  -v $LIM:/opt/limiter:ro \
  -e LD_PRELOAD=/opt/libvnpu.so \
  -e NPU_MEM_QUOTA=16000 \
  -e NPU_GLOBAL_SHM_PATH=/tmp/probe_shm \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  quay.io/ascend/vllm-ascend:v0.13.0rc1 \
  bash -c '/opt/limiter > /tmp/lim.log 2>&1 & sleep 1; python3 /tmp/probe_hal.py' 2>&1 | head -40

echo '=== limiter log (hal lines) ==='
grep vnpu-hal /tmp/probe_hal_limiter.log 2>/dev/null | head -10
EOF
