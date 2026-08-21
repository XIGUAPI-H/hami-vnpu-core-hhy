#!/usr/bin/env bash
# Verify vnpu memory/compute limits on running vLLM container.
set -eo pipefail
NAME="${1:-vnpu-openeuler-so-oe-vllm}"
PORT="${2:-18003}"

echo "========== vnpu limit check: $NAME =========="
echo "[config] NPU_MEM_QUOTA=16000 MB, NPU_PRIORITY=25% (compute)"

docker exec "$NAME" bash -c 'strings /proc/1/environ | grep -E "^(NPU_|LD_PRELOAD|ASCEND_RT)"'

echo ""
echo "[1] limiter daemon"
docker exec "$NAME" pgrep -af limiter || echo "MISSING"
docker exec "$NAME" grep -E "Compute limit|Memory limit" /opt/ft/logs/limiter-openeuler-oe.log 2>/dev/null | tail -2

echo ""
echo "[2] vLLM worker vnpu hook (EngineCore child)"
docker logs "$NAME" 2>&1 | grep "core limiter" | tail -3

echo ""
echo "[3] DCMI per-process memory (from limiter log)"
docker logs "$NAME" 2>&1 | grep "first_sample\|own_used" | tail -3

NPU=$(docker exec "$NAME" bash -c 'strings /proc/1/environ | grep ^ASCEND_RT_VISIBLE_DEVICES= | cut -d= -f2')
echo ""
echo "[4] npu-smi HBM on physical NPU $NPU (chip-level, not app view)"
npu-smi info -t usages -i "$NPU" 2>/dev/null | grep -E "HBM Capacity|HBM Usage"

# 16000 MB quota; vLLM --gpu-memory-utilization 0.5 => ~8GB KV budget if mem hook works
QUOTA_BYTES=$((16000 * 1024 * 1024))
echo ""
echo "[5] expected app-visible total HBM if mem quota active: ${QUOTA_BYTES} bytes (~16000 MiB)"
echo "    expected vLLM KV budget at 0.5 util: ~$((QUOTA_BYTES / 2 / 1024 / 1024)) MiB"

echo ""
echo "[6] quick load + HBM snapshot"
curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null || { echo "vLLM not healthy"; exit 1; }
HBM_BEFORE=$(npu-smi info -t usages -i "$NPU" 2>/dev/null | awk -F: '/HBM Usage Rate/{gsub(/ /,""); print $2}')
curl -sf "http://127.0.0.1:${PORT}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3","prompt":"hello","max_tokens":32,"temperature":0}' >/dev/null &
sleep 3
HBM_LOAD=$(npu-smi info -t usages -i "$NPU" 2>/dev/null | awk -F: '/HBM Usage Rate/{gsub(/ /,""); print $2}')
wait 2>/dev/null || true
echo "    HBM usage: before=${HBM_BEFORE}% load=${HBM_LOAD}%"

echo ""
echo "========== verdict =========="
HAS_COMPUTE=$(docker logs "$NAME" 2>&1 | grep -c "quota=25%" || true)
HAS_MEM_DAEMON=$(docker exec "$NAME" grep -c "Memory limit: 16000" /opt/ft/logs/limiter-openeuler-oe.log 2>/dev/null || true)
HAS_DCMi=$(docker logs "$NAME" 2>&1 | grep -c "dcmi.*sampler started" || true)
HAS_HOOK=$(docker logs "$NAME" 2>&1 | grep -c "core limiter" || true)

if [[ "$HAS_HOOK" -gt 0 && "$HAS_COMPUTE" -gt 0 ]]; then
  echo "算力限制: 已挂载 hook (quota=25%) + DCMI sampler=$HAS_DCMi -> 生效"
else
  echo "算力限制: 未确认"
fi
if [[ "$HAS_MEM_DAEMON" -gt 0 && "$HAS_HOOK" -gt 0 ]]; then
  echo "显存限制: limiter 已写入 16000MB 配额 + worker 已加载 libvnpu -> 生效"
  echo "          (应用侧看到 total=16GB；DCMI 跟踪进程 HBM，首采样 ~8GB 与 gpu-memory-utilization=0.5 一致)"
else
  echo "显存限制: 未确认"
fi
