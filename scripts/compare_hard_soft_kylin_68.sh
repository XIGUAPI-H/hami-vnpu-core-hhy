#!/usr/bin/env bash
set -euo pipefail
FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
NPU_PHY="${NPU_PHY:-5}"
VLLM_PORT="${VLLM_PORT:-18125}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/hard_vs_soft_kylin_${TAG}.txt"
SO="${SO:-${KY}/release-optimized/libvnpu.so}"
LIMITER="${LIMITER:-${KY}/release-optimized/limiter}"
START_SH="${KY}/start_vllm_kylin_hardsoft.sh"

mkdir -p "${KY}/logs" "${HAMi_SHM}/local_shmem"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$REPORT"; }
extract_metric(){ awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }

stop_all(){
  docker rm -f vnpu-hard-kylin vnpu-soft-kylin 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${VLLM_PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

ensure_vnpu(){
  ls /dev/vdavinci* >/dev/null 2>&1 && return 0
  npu-smi set -t vnpu-mode -d 0 -i "${NPU_PHY}" || true
  npu-smi set -t create-vnpu -i "${NPU_PHY}" -c 0 -f vir05_1c_16g
  sleep 2
}

wait_health(){
  local n="$1" d=$((SECONDS+1200))
  while (( SECONDS<d )); do
    curl -sf "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null && { log "health_ok $n"; return 0; }
    docker ps --format '{{.Names}}' | grep -qx "$n" || { docker logs "$n" 2>&1 | tail -60 | tee -a "$REPORT"; return 1; }
    sleep 15
  done
  return 1
}

docker_common=(
  -v "${FT}:/opt/ft" -v "${MODEL}:/models:ro"
  -v "${KY}/ms-conda:/opt/ms-conda:ro"
  -v "${FT}/openeuler/vllm-workspace:/vllm-workspace:ro"
  -v "${FT}/openeuler/py310-site:/opt/py310-site:ro"
  -v "${HAMi_SHM}:/hami-shared-region"
  -v /usr/local/Ascend:/usr/local/Ascend:ro -v /usr/local/dcmi:/usr/local/dcmi:ro
  --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc
  -e VLLM_PLATFORM=ascend -e ASCEND_RT_VISIBLE_DEVICES=0 -e VLLM_PORT="${VLLM_PORT}"
)

run_aisbench(){
  local l="$1"
  OUT_TAG="hardsoft_${l}_${TAG}" VLLM_PORT="$VLLM_PORT" NUM_PROMPTS="$NUM_PROMPTS" VLLM_CONTAINER="vnpu-${l}-kylin" \
    bash "${UB}/aisbench_perf_ubuntu.sh" 2>&1 | tee -a "${KY}/logs/aisbench_${l}_${TAG}.log"
  find "${BENCH}/outputs" -path "*ubuntu_vllm_hardsoft_${l}_${TAG}*" -name gsm8kdataset.csv | head -1
}

: >"$REPORT"
log "=== Hard vs Soft Kylin $TAG ==="
[[ -f "$START_SH" ]] || { log "missing $START_SH"; exit 1; }
stop_all; ensure_vnpu

VDEV="$(ls /dev/vdavinci* | head -1)"; VNUM="${VDEV#/dev/vdavinci}"
log "HARD vdavinci${VNUM}"
docker rm -f vnpu-hard-kylin 2>/dev/null || true
docker run -d --name vnpu-hard-kylin --privileged --network host --device "/dev/vdavinci${VNUM}" \
  "${docker_common[@]}" "$IMAGE" bash /opt/ft/kylin/start_vllm_kylin_hardsoft.sh
wait_health vnpu-hard-kylin
CSV_H="$(run_aisbench hard)"; stop_all

log "SOFT davinci${NPU_PHY} libvnpu25% (hard-sim)"
docker run -d --name vnpu-soft-kylin --privileged --network host --device "/dev/davinci${NPU_PHY}" \
  "${docker_common[@]}" "$IMAGE" bash -c "
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export NPU_HARD_SIM=1 VXPU_CORE_LIMIT_PERCENT=25
export NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_KYLIN_LITE=0 NPU_KYLIN_PRESET=0
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/gr_hs_${TAG}
export NPU_LOCAL_SHM_NAME=vnpu_hs_soft_${TAG}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
mkdir -p /hami-shared-region/local_shmem
env LD_PRELOAD=${SO:-/opt/ft/kylin/release-optimized/libvnpu.so} \
  ${LIMITER:-/opt/ft/kylin/release-optimized/limiter} > /opt/ft/kylin/logs/lim_${TAG}.log 2>&1 &
sleep 3; pgrep -x limiter
export VNPU_SOFT=1 VNPU_SO_PATH=${SO:-/opt/ft/kylin/release-optimized/libvnpu.so}
bash /opt/ft/kylin/start_vllm_kylin_hardsoft.sh"
wait_health vnpu-soft-kylin
CSV_S="$(run_aisbench soft)"; stop_all

{
  echo "=== COMPARISON ==="
  printf "%-28s %-18s %-18s\n" Metric Hard Soft
  for m in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
    printf "%-28s %-18s %-18s\n" "$m" "$(extract_metric "$CSV_H" "$m")" "$(extract_metric "$CSV_S" "$m")"
  done
  echo "hard=$CSV_H"; echo "soft=$CSV_S"
} | tee -a "$REPORT"
log "done $REPORT"
