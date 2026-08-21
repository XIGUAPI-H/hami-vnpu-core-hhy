#!/bin/bash
# Verify the fixed-share duty cycle of origin vs the patched optimized limiter.
# Only the manager's arithmetic is under test (FinalTokens / Rest), so no NPU
# workload is needed: start each limiter with a priority and read its [Sched] line.
KY=/mnt/local/m00953550/FinalTest/kylin
SHM=/usr/local/hami-shared-region
OUT=/root/dutycycle_verify
rm -rf "$OUT"; mkdir -p "$OUT" "$SHM/local_shmem"

run_one() {
  local variant="$1" bin="$2" prio="$3"
  local tag="${variant}_p${prio}"
  local gshm="global_dc_${tag}_$$"
  local lshm="vnpu_dc_${tag}_$$"
  rm -f "$SHM/$gshm" "$SHM/local_shmem/$lshm" "/dev/shm/$lshm"
  env -i PATH=/usr/bin:/bin \
    LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/ascend-toolkit/latest/lib64:/usr/local/Ascend/ascend-toolkit/latest/runtime/lib64 \
    NPU_GLOBAL_SHM_PATH="$SHM/$gshm" \
    NPU_LOCAL_SHM_NAME="$lshm" \
    NPU_LOCAL_SHM_DIR="$SHM/local_shmem" \
    NPU_LOCAL_SHM_BACKEND=file \
    NPU_MEM_QUOTA=16000 \
    NPU_PRIORITY="$prio" \
    NPU_FIXED_SHARE_RATIO=1 \
    NPU_KYLIN_LITE=1 \
    VXPU_MEMINFO_USE_DCMI=0 \
    RUST_LOG=limiter=debug \
    "$bin" >"$OUT/$tag.log" 2>&1 &
  local pid=$!
  sleep 12
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "--- $variant prio=$prio"
  grep -m3 '\[Sched\]' "$OUT/$tag.log" || tail -5 "$OUT/$tag.log"
}

for prio in 25 5; do
  run_one origin    "$KY/release-origin/limiter"    "$prio"
  run_one optimized "$KY/release-optimized/limiter" "$prio"
done

echo
echo "=== duty cycle = run/(run+rest), run = FinalTokens * MyAvg"
for f in "$OUT"/*.log; do
  python3 - "$f" <<'PY'
import re,sys
p=sys.argv[1]
m=None
for line in open(p, errors='replace'):
    g=re.search(r'MyAvg: (\d+)us, Prio: ([\d.]+).*FinalTokens: (\d+).*Rest: (\d+)ms', line)
    if g: m=g
if not m:
    print(f"{p.split('/')[-1]:<24} no [Sched] line")
else:
    avg,prio,tok,rest=int(m.group(1)),float(m.group(2)),int(m.group(3)),int(m.group(4))
    run=tok*avg/1000.0
    duty=run/(run+rest)*100 if run+rest else 0
    print(f"{p.split('/')[-1]:<24} prio={prio:<5g} tokens={tok:<7} run={run:>8.1f}ms rest={rest:>6}ms duty={duty:>5.1f}% (target {prio:g}%)")
PY
done
