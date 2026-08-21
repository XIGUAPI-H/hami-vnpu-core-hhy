#!/usr/bin/env bash
# Run soft-split only (hard already done in prior run)
set -euo pipefail
FT=/mnt/local/m00953550/FinalTest
KY=$FT/kylin
UB=$FT/ubuntu
TAG="$(date +%Y%m%d_%H%M%S)"
VLLM_PORT=18125
NPU_PHY=5
REPORT="$KY/logs/hard_vs_soft_kylin_softonly_${TAG}.txt"
CSV_H="${1:-/mnt/local/m00953550/benchmark/outputs/ubuntu_vllm_hardsoft_hard_20260629_220753/20260629_221013/performances/vllm-api-stream-chat/gsm8kdataset.csv}"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$REPORT"; }
extract(){ awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }

docker rm -f vnpu-soft-kylin 2>/dev/null || true
pkill -f "vllm.entrypoints.openai.api_server.*--port ${VLLM_PORT}" 2>/dev/null || true
pkill -x limiter 2>/dev/null || true
sleep 3

log "SOFT davinci${NPU_PHY} libvnpu 25%"
docker run -d --name vnpu-soft-kylin --privileged --network host \
  --device /dev/davinci${NPU_PHY} --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc \
  -e ASCEND_RT_VISIBLE_DEVICES=0 -e VLLM_PLATFORM=ascend -e VLLM_PORT=${VLLM_PORT} \
  -v ${FT}:/opt/ft -v /mnt/local/m00953550/Qwen3-1.7B:/models:ro \
  -v ${KY}/ms-conda:/opt/ms-conda:ro -v ${FT}/openeuler/vllm-workspace:/vllm-workspace:ro \
  -v ${FT}/openeuler/py310-site:/opt/py310-site:ro \
  -v /usr/local/Ascend:/usr/local/Ascend:ro -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/hami-shared-region:/hami-shared-region \
  kylin-server:v11-2503-arm64 bash -c "
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export NPU_KYLIN_LITE=1 NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/gr_soft_${TAG}
export NPU_LOCAL_SHM_NAME=vnpu_soft_${TAG}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
mkdir -p /hami-shared-region/local_shmem
LD_PRELOAD=/opt/ft/kylin/release-jun24-snapshot/libvnpu.so \
  /opt/ft/kylin/release-jun24-snapshot/limiter > /opt/ft/kylin/logs/lim_soft_${TAG}.log 2>&1 &
sleep 3; pgrep -x limiter
export VNPU_SOFT=1 VNPU_SO_PATH=/opt/ft/kylin/release-jun24-snapshot/libvnpu.so
bash /opt/ft/kylin/start_vllm_kylin_hardsoft.sh"

deadline=$((SECONDS+1200))
while (( SECONDS<deadline )); do
  curl -sf http://127.0.0.1:${VLLM_PORT}/health >/dev/null && { log health_ok; break; }
  docker ps --format '{{.Names}}' | grep -qx vnpu-soft-kylin || { docker logs vnpu-soft-kylin 2>&1 | tail -40 | tee -a "$REPORT"; exit 1; }
  sleep 15
done

OUT_TAG="hardsoft_soft_${TAG}" VLLM_PORT=$VLLM_PORT NUM_PROMPTS=16 VLLM_CONTAINER=vnpu-soft-kylin \
  bash ${UB}/aisbench_perf_ubuntu.sh 2>&1 | tee -a ${KY}/logs/aisbench_softonly_${TAG}.log
CSV_S=$(find /mnt/local/m00953550/benchmark/outputs -path "*ubuntu_vllm_hardsoft_soft_${TAG}*" -name gsm8kdataset.csv | head -1)

{
  echo "=== Hard vs Soft (Kylin) ==="
  printf "%-28s %-18s %-18s\n" Metric "Hard(vir05)" "Soft(libvnpu25%)"
  for m in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
    printf "%-28s %-18s %-18s\n" "$m" "$(extract "$CSV_H" "$m")" "$(extract "$CSV_S" "$m")"
  done
  echo "hard_csv=$CSV_H"; echo "soft_csv=$CSV_S"
} | tee -a "$REPORT"
log "done $REPORT"
