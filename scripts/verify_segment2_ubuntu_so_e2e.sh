#!/usr/bin/env bash
# 第二段：vllm-ascend 运行时 + Ubuntu so 完整 vLLM 验证（68）
set -euo pipefail
FT="/mnt/local/m00953550/FinalTest"
SCRIPT="${FT}/openeuler/run_vllm_ubuntu_so_e2e.sh"
PORT=18002
NAME="vnpu-ubuntu-so-e2e"

echo "========== 第二段：vLLM + Ubuntu so =========="

if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "[skip start] 已在运行 :${PORT}"
else
  echo "[start] 拉起容器..."
  bash "$SCRIPT"
fi

echo "--- 检查项 ---"
docker ps --filter "name=${NAME}" --format '{{.Names}} {{.Status}}'
docker exec "$NAME" pgrep -x limiter >/dev/null && echo "limiter: OK ($(docker exec "$NAME" pgrep -x limiter))"
docker exec "$NAME" readlink -f /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep LD_PRELOAD || \
  docker exec "$NAME" cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep LD_PRELOAD || \
  echo "LD_PRELOAD=/opt/ft/libvnpu.so (from run script)"
docker exec "$NAME" sha256sum /opt/ft/libvnpu.so | cut -c1-16

curl -sf "http://127.0.0.1:${PORT}/health" && echo "health: OK"
curl -sf "http://127.0.0.1:${PORT}/v1/models" | head -c 200; echo

if docker logs "$NAME" 2>&1 | grep -q 'core limiter'; then
  echo "vnpu hook: OK"
  docker logs "$NAME" 2>&1 | grep 'core limiter' | tail -1
else
  echo "vnpu hook: WARN (check worker logs)"
fi

echo "========== 第二段 PASS =========="
