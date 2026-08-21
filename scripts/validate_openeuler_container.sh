#!/usr/bin/env bash
# Run on 68 host: smoke-test openEuler-built libvnpu.so + limiter inside openEuler container.
set -euo pipefail

IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
VNPU_DIR="${VNPU_DIR:-/mnt/local/m00953550/FinalTest/openeuler}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
CONTAINER_NAME="${CONTAINER_NAME:-vnpu-openeuler-verify}"

echo "=== openEuler verify container ==="
echo "image: $IMAGE"
echo "vnpu:  $VNPU_DIR/release"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run --rm --name "$CONTAINER_NAME" \
  --privileged \
  --network host \
  -v "${VNPU_DIR}:/opt/vnpu:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v "${HAMi_SHM}:/hami-shared-region" \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c '
set -euo pipefail

export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"

echo "=== 1) OS / glibc ==="
cat /etc/os-release | grep PRETTY
ldd --version | head -1
uname -m

echo "=== 2) openEuler so files ==="
ls -la /opt/vnpu/release/libvnpu.so /opt/vnpu/release/limiter
sha256sum /opt/vnpu/release/libvnpu.so /opt/vnpu/release/limiter

echo "=== 3) link check (need CANN runtime) ==="
ldd /opt/vnpu/release/limiter

echo "=== 4) GLIBC max version ==="
objdump -T /opt/vnpu/release/limiter | grep GLIBC | sed "s/.*GLIBC/Glibc/" | sort -u | tail -3

echo "=== 5) start limiter ==="
export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_openeuler_verify"
export NPU_LOCAL_SHM_NAME="vnpu_openeuler_verify"
export NPU_MEM_QUOTA=16000
export NPU_PRIORITY=25
rm -f "/dev/shm/${NPU_LOCAL_SHM_NAME}" 2>/dev/null || true
/opt/vnpu/release/limiter > /tmp/limiter.log 2>&1 &
sleep 2
pgrep -x limiter || { echo "limiter failed:"; cat /tmp/limiter.log; exit 1; }
head -5 /tmp/limiter.log
ls -la "/dev/shm/${NPU_LOCAL_SHM_NAME}" 2>/dev/null || ls -la /dev/shm/ | grep vnpu || true

echo "=== 6) preload smoke (dlopen path) ==="
export LD_PRELOAD=/opt/vnpu/release/libvnpu.so
python3 - << "PY"
import ctypes, os
print("LD_PRELOAD=", os.environ.get("LD_PRELOAD"))
# SchedulerClient init happens on first hook; try loading .so
lib = ctypes.CDLL("/opt/vnpu/release/libvnpu.so")
print("dlopen libvnpu.so OK")
PY

echo "=== 7) npu-smi (optional) ==="
if command -v npu-smi >/dev/null 2>&1; then
  npu-smi info -l 2>&1 | head -8 || true
else
  echo "npu-smi not in container PATH (OK for link-only verify)"
fi

pkill -x limiter 2>/dev/null || true
echo "=== PASS: openEuler container verify OK ==="
'
