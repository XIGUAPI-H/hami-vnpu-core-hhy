#!/usr/bin/env bash
# 68 上代替 labest-m1 的「openEuler 用户态 + Ubuntu so」代理验证（不依赖外网）。
# 说明：
#   - 本脚本验证：openEuler 容器内 glibc/链接/limiter/LD_PRELOAD/torch_npu（≈ labest 原生层）
#   - 完整 vLLM 服务请再跑：run_vllm_ubuntu_so_e2e.sh（vllm-ascend 运行时 + 同一套 Ubuntu so）
#
# 用法（68 上）：
#   bash /mnt/local/m00953550/FinalTest/openeuler/validate_ubuntu_so_openeuler_proxy.sh
set -euo pipefail

IMAGE="${OPENEULER_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindspeed-llm:openeuler22.03-mindspeed-llm-2.3.0-a2-arm}"
FT="${FT:-/mnt/local/m00953550/FinalTest}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
NPU="${ASCEND_RT_VISIBLE_DEVICES:-3}"
NAME="vnpu-ubuntu-so-oe-proxy"

echo "=============================================="
echo " openEuler 容器代理验证 (68 → 代替 labest-m1)"
echo " Ubuntu so: ${FT}/libvnpu.so"
echo " 镜像:      ${IMAGE}"
echo " NPU:       ${NPU}"
echo "=============================================="

docker rm -f "$NAME" 2>/dev/null || true

docker run --rm --name "$NAME" \
  --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES="$NPU" \
  -v "${FT}:/opt/ft:ro" \
  -v /usr/local/Ascend:/usr/local/Ascend:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v "${HAMi_SHM}:/hami-shared-region" \
  -v /dev/davinci_manager:/dev/davinci_manager \
  -v /dev/devmm_svm:/dev/devmm_svm \
  -v /dev/hisi_hdc:/dev/hisi_hdc \
  "$IMAGE" \
  bash -c '
set -eo pipefail

echo "=== [1/5] OS / glibc（应接近 labest-m1 openEuler 22.03）==="
grep PRETTY /etc/os-release
ldd --version | head -1
uname -m

echo "=== [2/5] Ubuntu so 链接（关键：GLIBC 是否 <= 容器 glibc）==="
ls -la /opt/ft/libvnpu.so /opt/ft/limiter
sha256sum /opt/ft/libvnpu.so | cut -c1-64
objdump -T /opt/ft/libvnpu.so | grep GLIBC | sed "s/.*GLIBC/Glibc/" | sort -Vu | tail -3
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64"
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /usr/local/Ascend/nnal/atb/set_env.sh
ldd /opt/ft/limiter | head -6

echo "=== [3/5] limiter + shmem（Ubuntu so 版 limiter）==="
export NPU_GLOBAL_SHM_PATH="/hami-shared-region/global_registry_ubuntu_so_oe_proxy"
export NPU_LOCAL_SHM_NAME="vnpu_ubuntu_so_oe_proxy"
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25
rm -f "/dev/shm/${NPU_LOCAL_SHM_NAME}" 2>/dev/null || true
/opt/ft/limiter > /tmp/limiter.log 2>&1 &
sleep 2
pgrep -x limiter || { cat /tmp/limiter.log; exit 1; }
head -3 /tmp/limiter.log
ls -la "/dev/shm/${NPU_LOCAL_SHM_NAME}"

echo "=== [4/5] LD_PRELOAD + torch_npu（openEuler conda Python）==="
export LD_PRELOAD=/opt/ft/libvnpu.so
PY=/root/miniconda3/envs/llm_test/bin/python
$PY -c "import torch, torch_npu; print(\"torch\", torch.__version__, \"npu\", torch_npu.__version__)"
$PY -c "
import torch, torch_npu
torch_npu.npu.set_device(0)
x = torch.randn(2, 2, device=\"npu\")
y = x @ x
torch_npu.npu.synchronize()
print(\"npu_matmul_ok\", y.shape)
"

echo "=== [5/5] dlopen libvnpu.so ==="
$PY -c "import ctypes; ctypes.CDLL(\"/opt/ft/libvnpu.so\"); print(\"dlopen_ok\")"

pkill -x limiter 2>/dev/null || true
echo "=== PROXY PASS: openEuler 容器 + Ubuntu so 基础层 OK ==="
'

echo ""
echo "----------------------------------------------"
echo "代理验证结论（对应 labest-m1 上「so 能不能用」）："
echo "  ✅ 若上面 PASS → Ubuntu so 在 openEuler 用户态可加载、limiter 可跑、NPU 可算"
echo "  ⚠️  未覆盖：完整 vLLM api_server（openEuler 容器缺 vLLM Python 栈）"
echo ""
echo "完整 vLLM 端到端（同一套 Ubuntu so）请执行："
echo "  bash ${FT}/openeuler/run_vllm_ubuntu_so_e2e.sh"
echo "  curl http://127.0.0.1:18002/health"
echo "----------------------------------------------"
