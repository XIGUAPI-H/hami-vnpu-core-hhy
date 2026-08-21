#!/usr/bin/env bash
# Rigorous hard (vir05=5 AICore) vs soft (NPU_PRIORITY) comparison on 68.
#
# Scenarios (env RUN="S0,S1,S2,S3,S4", default all):
#   S0  baseline   full davinci, no vnpu, no libvnpu        (~100% ref)
#   S1  hard       vir05_1c_16g vdavinci, single tenant     (5 AICore ≈ 25%)
#   S2  soft25     davinci + libvnpu, NPU_PRIORITY=25        (25% target)
#   S3  soft100    davinci + libvnpu, NPU_PRIORITY=100       (limit sanity)
#   S4  soft25_mt  two containers prio=25 share one card     (multi-tenant)
#
# Pass criteria for soft limiter:
#   - S3 throughput >> S2 (single-tenant)
#   - S4 each tenant throughput << S2 (multi-tenant contention)
#   - S1 vs S2 comparable if both truly ~25% (±10%)
#
set -euo pipefail

FT="${FT:-/mnt/local/m00953550/FinalTest}"
KY="${FT}/kylin"
UB="${FT}/ubuntu"
BENCH="${BENCH:-/mnt/local/m00953550/benchmark}"
IMAGE="${KYLIN_IMAGE:-kylin-server:v11-2503-arm64}"
MODEL="${MODEL_HOST:-/mnt/local/m00953550/Qwen3-1.7B}"
HAMi_SHM="${HAMi_SHM:-/usr/local/hami-shared-region}"
SO="${SO:-${KY}/release-jun24-snapshot/libvnpu.so}"
LIMITER="${LIMITER:-${KY}/release-jun24-snapshot/limiter}"
START_SH="/opt/ft/kylin/start_vllm_kylin_hardsoft.sh"

NPU_PHY="${NPU_PHY:-5}"
VIR05="${VIR05:-vir05_1c_16g}"
MEM_QUOTA="${MEM_QUOTA:-16000}"
NUM_PROMPTS="${NUM_PROMPTS:-16}"
PORT_A="${PORT_A:-18125}"
PORT_B="${PORT_B:-18126}"
TAG="$(date +%Y%m%d_%H%M%S)"
REPORT="${KY}/logs/rigorous_hardsoft_${TAG}.txt"
RESULTS="${KY}/logs/rigorous_hardsoft_${TAG}.csv"
RUN="${RUN:-S0,S1,S2,S3,S4}"

declare -A CSV_MAP

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$REPORT"; }
want(){ [[ ",${RUN}," == *",$1,"* ]]; }
extract(){ awk -F, -v k="$2" '$1==k && $2=="total" {print $3; exit}' "$1"; }

docker_common=(
  -v "${FT}:/opt/ft" -v "${MODEL}:/models:ro"
  -v "${KY}/ms-conda:/opt/ms-conda:ro"
  -v "${FT}/openeuler/vllm-workspace:/vllm-workspace:ro"
  -v "${FT}/openeuler/py310-site:/opt/py310-site:ro"
  -v /usr/local/Ascend:/usr/local/Ascend:ro -v /usr/local/dcmi:/usr/local/dcmi:ro
  --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc
  -e VLLM_PLATFORM=ascend -e ASCEND_RT_VISIBLE_DEVICES=0
)

stop_all(){
  docker rm -f vnpu-rig-a vnpu-rig-b 2>/dev/null || true
  pkill -f 'vllm.entrypoints.openai.api_server.*--port 1812' 2>/dev/null || true
  pkill -x limiter 2>/dev/null || true
  sleep 4
}

destroy_vnpu_on_npu(){
  local i="$1" v
  for v in $(ls /dev/vdavinci* 2>/dev/null || true); do
    local id="${v#/dev/vdavinci}"
    log "destroy vnpu id=${id} on NPU ${i}"
    npu-smi set -t destroy-vnpu -i "${i}" -c 0 -v "${id}" 2>/dev/null || true
  done
  sleep 2
}

ensure_hard_vnpu(){
  destroy_vnpu_on_npu "${NPU_PHY}"
  npu-smi set -t vnpu-mode -d 0 -i "${NPU_PHY}" 2>/dev/null || true
  npu-smi set -t create-vnpu -i "${NPU_PHY}" -c 0 -f "${VIR05}"
  sleep 2
  ls /dev/vdavinci* >/dev/null
  log "hard vnpu ready: $(ls /dev/vdavinci* | tr '\n' ' ')"
}

wait_health(){
  local name="$1" port="$2" deadline=$((SECONDS+1200))
  while (( SECONDS < deadline )); do
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null && { log "health_ok ${name}:${port}"; return 0; }
    docker ps --format '{{.Names}}' | grep -qx "$name" || {
      log "FAIL ${name} exited"; docker logs "$name" 2>&1 | tail -50 | tee -a "$REPORT"; return 1; }
    sleep 15
  done
  log "FAIL health timeout ${name}"; return 1
}

run_bench(){
  local sid="$1" cname="$2" port="$3"
  local out="rigorous_${sid}_${TAG}"
  OUT_TAG="$out" VLLM_PORT="$port" NUM_PROMPTS="$NUM_PROMPTS" VLLM_CONTAINER="$cname" \
    bash "${UB}/aisbench_perf_ubuntu.sh" 2>&1 | tee -a "${KY}/logs/aisbench_${out}.log"
  local csv
  csv=$(find "${BENCH}/outputs" -path "*ubuntu_vllm_${out}*" -name gsm8kdataset.csv | head -1)
  [[ -n "$csv" ]] || { log "FAIL no csv for ${sid}"; return 1; }
  CSV_MAP["$sid"]="$csv"
  log "csv ${sid}=${csv}"
}

verify_soft_limiter(){
  local limlog="$1"
  log "--- limiter verify: ${limlog} ---"
  grep -E 'core limiter|quota|NPU_PRIORITY|Registered as Global' "$limlog" 2>/dev/null | tail -8 | tee -a "$REPORT" || true
  pgrep -xa limiter 2>/dev/null | tee -a "$REPORT" || true
}

soft_launch_cmd(){
  local tag="$1" prio="$2" port="$3" gshm="$4" lshm="$5" limlog="$6"
  cat <<EOS
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64
export NPU_MEM_QUOTA=${MEM_QUOTA} NPU_PRIORITY=${prio} NPU_FIXED_SHARE_RATIO=0
export NPU_KYLIN_LITE=1 NPU_FCSP_REFILL=0 NPU_BURST_CONTINUOUS=1 NPU_TOKEN_CHUNK=8
export VXPU_MEMINFO_USE_DCMI=0 VXPU_ENABLE_MALLOC_QUOTA=0
export NPU_GLOBAL_SHM_PATH=${gshm}
export NPU_LOCAL_SHM_NAME=${lshm}
export NPU_LOCAL_SHM_DIR=/hami-shared-region/local_shmem
export VLLM_PORT=${port}
mkdir -p /hami-shared-region/local_shmem
LD_PRELOAD=${SO} ${LIMITER} > ${limlog} 2>&1 &
sleep 3
pgrep -x limiter
export VNPU_SOFT=1 VNPU_SO_PATH=${SO}
bash ${START_SH}
EOS
}

run_baseline(){
  log "===== S0 baseline (full card, no vnpu/libvnpu) ====="
  destroy_vnpu_on_npu "${NPU_PHY}"
  docker run -d --name vnpu-rig-a --privileged --network host \
    --device "/dev/davinci${NPU_PHY}" "${docker_common[@]}" \
    -e VLLM_PORT="${PORT_A}" "$IMAGE" bash -c "export VLLM_PORT=${PORT_A}; bash ${START_SH}"
  wait_health vnpu-rig-a "$PORT_A"
  run_bench S0 vnpu-rig-a "$PORT_A"
  stop_all
}

run_hard(){
  log "===== S1 hard vir05 (5 AICore, 16GB) ====="
  ensure_hard_vnpu
  local vnum; vnum=$(ls /dev/vdavinci* | head -1); vnum="${vnum#/dev/vdavinci}"
  docker run -d --name vnpu-rig-a --privileged --network host \
    --device "/dev/vdavinci${vnum}" "${docker_common[@]}" \
    -e VLLM_PORT="${PORT_A}" "$IMAGE" bash -c "export VLLM_PORT=${PORT_A}; bash ${START_SH}"
  wait_health vnpu-rig-a "$PORT_A"
  run_bench S1 vnpu-rig-a "$PORT_A"
  stop_all
}

run_soft_single(){
  local sid="$1" prio="$2"
  log "===== ${sid} soft single-tenant NPU_PRIORITY=${prio} ====="
  destroy_vnpu_on_npu "${NPU_PHY}"
  local g="/hami-shared-region/gr_${sid}_${TAG}"
  local l="vnpu_${sid}_${TAG}"
  local lim="/opt/ft/kylin/logs/lim_${sid}_${TAG}.log"
  docker run -d --name vnpu-rig-a --privileged --network host \
    --device "/dev/davinci${NPU_PHY}" -v "${HAMi_SHM}:/hami-shared-region" \
    "${docker_common[@]}" -e VLLM_PORT="${PORT_A}" "$IMAGE" bash -c "$(soft_launch_cmd "$TAG" "$prio" "$PORT_A" "$g" "$l" "$lim")"
  wait_health vnpu-rig-a "$PORT_A"
  verify_soft_limiter "${KY}/logs/lim_${sid}_${TAG}.log"
  run_bench "$sid" vnpu-rig-a "$PORT_A"
  stop_all
}

run_soft_multitenant(){
  log "===== S4 soft25 multi-tenant (2x prio=25 same card) ====="
  destroy_vnpu_on_npu "${NPU_PHY}"
  local g="/hami-shared-region/gr_S4_${TAG}"
  local lima="/opt/ft/kylin/logs/lim_S4a_${TAG}.log"
  local limb="/opt/ft/kylin/logs/lim_S4b_${TAG}.log"
  docker run -d --name vnpu-rig-a --privileged --network host \
    --device "/dev/davinci${NPU_PHY}" -v "${HAMi_SHM}:/hami-shared-region" \
    "${docker_common[@]}" -e VLLM_PORT="${PORT_A}" "$IMAGE" \
    bash -c "$(soft_launch_cmd "${TAG}a" 25 "$PORT_A" "$g" "vnpu_S4a_${TAG}" "$lima")"
  docker run -d --name vnpu-rig-b --privileged --network host \
    --device "/dev/davinci${NPU_PHY}" -v "${HAMi_SHM}:/hami-shared-region" \
    "${docker_common[@]}" -e VLLM_PORT="${PORT_B}" "$IMAGE" \
    bash -c "$(soft_launch_cmd "${TAG}b" 25 "$PORT_B" "$g" "vnpu_S4b_${TAG}" "$limb")"
  wait_health vnpu-rig-a "$PORT_A"
  wait_health vnpu-rig-b "$PORT_B"
  verify_soft_limiter "${KY}/logs/lim_S4a_${TAG}.log"
  verify_soft_limiter "${KY}/logs/lim_S4b_${TAG}.log"
  log "bench A alone (B loaded idle)"
  run_bench S4a vnpu-rig-a "$PORT_A"
  log "bench B alone (A loaded idle)"
  run_bench S4b vnpu-rig-b "$PORT_B"
  stop_all
}

write_summary(){
  {
    echo ""
    echo "scenario,metric,value,csv"
    for sid in S0 S1 S2 S3 S4a S4b; do
      [[ -n "${CSV_MAP[$sid]:-}" ]] || continue
      for m in E2EL TTFT TPOT OutputTokenThroughput; do
        echo "${sid},${m},$(extract "${CSV_MAP[$sid]}" "$m"),${CSV_MAP[$sid]}"
      done
    done
  } > "$RESULTS"

  {
    echo ""
    echo "======== RIGOROUS SUMMARY ${TAG} ========"
    echo "Quota: hard=5AICore(vir05) soft25/soft100/mem=${MEM_QUOTA}MB NPU=${NPU_PHY}"
    echo "Model=${MODEL} prompts=${NUM_PROMPTS} stack=Kylin+mindspeed"
    printf "\n%-6s %-12s %-12s %-12s %-12s\n" "Scene" "E2EL" "TTFT" "TPOT" "tok/s"
    for sid in S0 S1 S2 S3 S4a S4b; do
      [[ -n "${CSV_MAP[$sid]:-}" ]] || continue
      printf "%-6s %-12s %-12s %-12s %-12s\n" "$sid" \
        "$(extract "${CSV_MAP[$sid]}" E2EL)" \
        "$(extract "${CSV_MAP[$sid]}" TTFT)" \
        "$(extract "${CSV_MAP[$sid]}" TPOT)" \
        "$(extract "${CSV_MAP[$sid]}" OutputTokenThroughput)"
    done
    echo ""
    echo "--- Interpretation ---"
    if [[ -n "${CSV_MAP[S2]:-}" && -n "${CSV_MAP[S3]:-}" ]]; then
      python3 - <<PY
s2=float("$(extract "${CSV_MAP[S2]}" OutputTokenThroughput)".split()[0])
s3=float("$(extract "${CSV_MAP[S3]}" OutputTokenThroughput)".split()[0])
print(f"soft100/soft25 throughput ratio = {s3/s2:.2f}x (expect >>1 if limiter works in single-tenant)")
PY
    fi
    if [[ -n "${CSV_MAP[S1]:-}" && -n "${CSV_MAP[S2]:-}" ]]; then
      python3 - <<PY
h=float("$(extract "${CSV_MAP[S1]}" OutputTokenThroughput)".split()[0])
s=float("$(extract "${CSV_MAP[S2]}" OutputTokenThroughput)".split()[0])
print(f"hard(5core)/soft25 throughput ratio = {h/s:.2f}x (expect ~0.85-1.15 if both ~25%)")
PY
    fi
    echo "csv: $RESULTS"
    echo "report: $REPORT"
  } | tee -a "$REPORT"
}

# -------- main --------
mkdir -p "${KY}/logs" "${HAMi_SHM}/local_shmem"
: >"$REPORT"
[[ -f "${SO}" && -x "${LIMITER}" ]] || { log "missing SO/limiter"; exit 1; }

log "RIGOROUS hard vs soft TAG=${TAG} RUN=${RUN}"
stop_all

want S0 && run_baseline
want S1 && run_hard
want S2 && run_soft_single S2 25
want S3 && run_soft_single S3 100
want S4 && run_soft_multitenant

write_summary
log "DONE"
