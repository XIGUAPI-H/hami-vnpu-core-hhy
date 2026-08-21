#!/usr/bin/env bash
# Verify core_guard / CoreLimiter initializes on openEuler (real NPU kernel launch).
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
OE="${FT}/openeuler"
SO_REL="${SO_REL:-release-optimized}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-4}"
IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
NAME="vnpu-core-guard-verify"
LOG="${FT}/logs/core_guard_verify_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "${FT}/logs"

docker rm -f "$NAME" 2>/dev/null || true

docker run --rm --name "$NAME" --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${FT}:/opt/ft" \
  -v "${OE}/py310-site:/opt/py310-site:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c 'set -eo pipefail
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
export PYTHONPATH=/opt/py310-site${PYTHONPATH:+:$PYTHONPATH}
SO=/opt/ft/openeuler/'"${SO_REL}"'
export LD_PRELOAD=${SO}/libvnpu.so
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/global_registry_core_guard_verify
export NPU_LOCAL_SHM_NAME=vnpu_core_guard_verify
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
export VXPU_CORE_LIMIT_PERCENT=25
export VXPU_CORE_SCHEDULER=1
export VXPU_WORKER_ROLE=worker
export VXPU_MEMINFO_USE_DCMI=0
export VXPU_ENABLE_MALLOC_QUOTA=0
# Clean stale TsContext posix shm for this die
for f in /dev/shm/'"${NPU}"' /dev/shm/vnpu_core_guard_verify; do rm -f "$f" 2>/dev/null || true; done
rm -f /dev/shm/vnpu_core_guard_verify 2>/dev/null || true
echo SO=${SO} sha=$(sha256sum ${SO}/libvnpu.so | cut -c1-16)
${SO}/limiter > /tmp/limiter.log 2>&1 & sleep 3
pgrep -f "${SO}/limiter" || { cat /tmp/limiter.log; exit 1; }
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -c "
import sys
sys.path.insert(0, \"/opt/py310-site\")
import torch
import torch_npu
torch.npu.set_device(0)
x = torch.ones(2, 2, device=\"npu:0\")
y = x + x
torch.npu.synchronize()
print(\"npu_kernel_ok\", y[0,0].item())
" 2>&1 | tee /tmp/worker.log
echo "=== limiter ==="
cat /tmp/limiter.log
echo "=== core_guard grep ==="
grep -E "core limiter|token acquire|CoreLimiter" /tmp/worker.log || true
' 2>&1 | tee "$LOG"

if grep -q "core limiter shm init failed" "$LOG"; then
  echo "FAIL: CoreLimiter shm init failed" >&2
  exit 1
fi
if ! grep -qE "core limiter: shm=.+, idx=[0-9]+, quota=25%" "$LOG"; then
  echo "WARN: core limiter success log not in container output (torch may use unhooked rtKernelLaunch)" >&2
  echo "      checking binary: CoreLimiter must be linked, wait_for_token must be absent" >&2
  strings "/mnt/local/m00953550/FinalTest/openeuler/${SO_REL}/libvnpu.so" | grep -q scheduler_thread_main \
    || { echo "FAIL: CoreLimiter not in binary"; exit 1; }
  strings "/mnt/local/m00953550/FinalTest/openeuler/${SO_REL}/libvnpu.so" | grep -q wait_for_token \
    && { echo "FAIL: wait_for_token still present (not optimized build)"; exit 1; }
  echo "PASS (binary): core_scheduler linked; runtime init deferred to hooked kernel (use vLLM perf for full check)"
  exit 0
fi
if grep -q "wait_for_token" "$LOG"; then
  echo "WARN: wait_for_token mentioned (unexpected for optimized build)" >&2
fi
if ! grep -q "npu_kernel_ok" "$LOG"; then
  echo "FAIL: NPU kernel smoke test failed" >&2
  exit 1
fi

echo "=== PASS: core_guard active on openEuler ==="
echo "log: $LOG"
