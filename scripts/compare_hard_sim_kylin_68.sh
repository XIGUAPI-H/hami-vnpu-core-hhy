#!/usr/bin/env bash
# Hard (vir05) vs soft baseline vs soft hard-sim (NPU_HARD_SIM=1) on Kylin 68.
#
# Usage:
#   bash compare_hard_sim_kylin_68.sh
#   MODES="hard,soft_hs" bash compare_hard_sim_kylin_68.sh
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
SO="${SO:-${KY}/release-optimized/libvnpu.so}"
LIMITER="${LIMITER:-${KY}/release-optimized/limiter}"
# Paths inside docker (-v ${FT}:/opt/ft)
SO_CTR="/opt/ft/kylin/release-optimized/libvnpu.so"
LIMITER_CTR="/opt/ft/kylin/release-optimized/limiter"
START_SH="/opt/ft/kylin/start_vllm_kylin_hardsoft.sh"

NPU_PHY="${NPU_PHY:-5}"
VLLM_PORT="${VLLM_PORT:-18125}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/hard_sim_kylin_${TAG}.txt"
CSV_OUT="${KY}/logs/hard_sim_kylin_${TAG}.csv"
MODES="${MODES:-hard,soft_base,soft_hs}"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$REPORT"; }
want(){ [[ ",${MODES}," == *",$1,"* ]]; }
extract(){ awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }

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

stop_all(){
  docker rm -f vnpu-hs-kylin 2>/dev/null || true
  pkill -f "vllm.entrypoints.openai.api_server.*--port ${VLLM_PORT}" 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 5
}

destroy_vnpu(){
  local i="$1" v id
  for v in $(ls /dev/vdavinci* 2>/dev/null || true); do
    id="${v#/dev/vdavinci}"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    npu-smi set -t destroy-vnpu -i "${i}" -c 0 -v "${id}" 2>/dev/null || true
  done
  sleep 2
}

ensure_vnpu(){
  destroy_vnpu "${NPU_PHY}"
  npu-smi set -t vnpu-mode -d 0 -i "${NPU_PHY}" 2>/dev/null || true
  npu-smi set -t create-vnpu -i "${NPU_PHY}" -c 0 -f vir05_1c_16g
  sleep 2
}

wait_health(){
  local n="$1" d=$((SECONDS+1200))
  while (( SECONDS<d )); do
    curl -sf "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null && { log "health_ok $n"; return 0; }
    docker ps --format '{{.Names}}' | grep -qx "$n" || {
      docker logs "$n" 2>&1 | tail -80 | tee -a "$REPORT"
      return 1
    }
    sleep 15
  done
  return 1
}

run_aisbench(){
  local l="$1"
  OUT_TAG="hsim_${l}_${TAG}" VLLM_PORT="$VLLM_PORT" NUM_PROMPTS="$NUM_PROMPTS" VLLM_CONTAINER="vnpu-hs-kylin" \
    bash "${UB}/aisbench_perf_ubuntu.sh" >"${KY}/logs/aisbench_hsim_${l}_${TAG}.log" 2>&1
  find "${BENCH}/outputs" -path "*ubuntu_vllm_hsim_${l}_${TAG}*" -name gsm8kdataset.csv 2>/dev/null | head -1
}

soft_limiter_env(){
  local tag="$1" extra="${2:-}"
  cat <<EOF
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64
export NPU_MEM_QUOTA=16000 NPU_PRIORITY=25 NPU_FIXED_SHARE_RATIO=0
export NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_GLOBAL_SHM_PATH=/hami-shared-region/gr_hs_${tag}
export NPU_LOCAL_SHM_NAME=vnpu_hs_${tag}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
export NPU_KYLIN_LITE=0 NPU_KYLIN_PRESET=0
mkdir -p /hami-shared-region/local_shmem
${extra}
env LD_PRELOAD=${SO_CTR} ${LIMITER_CTR} > /opt/ft/kylin/logs/lim_hs_${tag}.log 2>&1 &
sleep 3
pgrep -x limiter || { echo limiter_failed; cat /opt/ft/kylin/logs/lim_hs_${tag}.log; exit 1; }
EOF
}

run_soft(){
  local mode="$1" tag="${2:-$1}" extra="${3:-}"
  log "SOFT ${mode} davinci${NPU_PHY}"
  destroy_vnpu "${NPU_PHY}"
  docker rm -f vnpu-hs-kylin 2>/dev/null || true
  docker run -d --name vnpu-hs-kylin --privileged --network host \
    --device "/dev/davinci${NPU_PHY}" "${docker_common[@]}" "$IMAGE" bash -c "
$(soft_limiter_env "${tag}" "${extra}")
export VNPU_SOFT=1 VNPU_SO_PATH=${SO_CTR}
bash ${START_SH}" >/dev/null
  if ! wait_health vnpu-hs-kylin; then
    log "SOFT ${mode} health failed"
    docker logs vnpu-hs-kylin 2>&1 | tail -60 | tee -a "$REPORT"
    return 1
  fi
  run_aisbench "${mode}"
}

mkdir -p "${KY}/logs" "${HAMi_SHM}/local_shmem"
: >"$REPORT"
echo "mode,metric,value" >"$CSV_OUT"
log "=== Hard-Sim Kylin sweep $TAG ==="
log "SO=$SO"

declare -A CSV_MAP

if want hard; then
  stop_all; ensure_vnpu
  VDEV="$(ls /dev/vdavinci* | head -1)"; VNUM="${VDEV#/dev/vdavinci}"
  log "HARD vdavinci${VNUM}"
  docker run -d --name vnpu-hs-kylin --privileged --network host \
    --device "/dev/vdavinci${VNUM}" "${docker_common[@]}" "$IMAGE" bash "${START_SH}" >/dev/null
  wait_health vnpu-hs-kylin || { log "HARD health failed"; exit 1; }
  CSV_MAP[hard]="$(run_aisbench hard)"
  [[ -n "${CSV_MAP[hard]}" && -f "${CSV_MAP[hard]}" ]] || { log "HARD csv missing"; exit 1; }
  stop_all
fi

if want soft_base; then
  stop_all
  CSV_MAP[soft_base]="$(run_soft soft_base base 'export NPU_LLM_MODE=1 NPU_ITERATION_SCHED=0 NPU_COMPUTE_SCHED=manager')"
  [[ -n "${CSV_MAP[soft_base]}" && -f "${CSV_MAP[soft_base]}" ]] || { log "soft_base csv missing"; exit 1; }
  stop_all
fi

if want soft_hs; then
  stop_all
  CSV_MAP[soft_hs]="$(run_soft soft_hs hs 'export NPU_HARD_SIM=1; export VXPU_CORE_LIMIT_PERCENT=25')"
  [[ -n "${CSV_MAP[soft_hs]}" && -f "${CSV_MAP[soft_hs]}" ]] || { log "soft_hs csv missing"; exit 1; }
  stop_all
fi

{
  echo "=== COMPARISON OutputTokenThroughput ==="
  printf "%-16s %-18s\n" Mode tok_s
  for m in hard soft_base soft_hs; do
    [[ -n "${CSV_MAP[$m]:-}" ]] || continue
    printf "%-16s %-18s\n" "$m" "$(extract "${CSV_MAP[$m]}" OutputTokenThroughput)"
  done
  echo
  for m in hard soft_base soft_hs; do
    [[ -n "${CSV_MAP[$m]:-}" ]] || continue
    echo "[$m] csv=${CSV_MAP[$m]}"
    for metric in E2EL TTFT TPOT OutputTokenThroughput OutputTokens; do
      echo "  $metric=$(extract "${CSV_MAP[$m]}" "$metric")"
      echo "${m},${metric},$(extract "${CSV_MAP[$m]}" "$metric")" >>"$CSV_OUT"
    done
  done
} | tee -a "$REPORT"

log "done report=$REPORT csv=$CSV_OUT"
