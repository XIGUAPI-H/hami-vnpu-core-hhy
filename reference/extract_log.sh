#!/bin/bash
POD=$(kubectl get pods --no-headers 2>/dev/null | awk '/^mhw-normal-job-ray-head-/ {print $1; exit}')
echo "POD=$POD"
[ -z "$POD" ] && exit 0

mkdir -p /tmp/61logs
LOG=/tmp/61logs/${POD}.full.log
kubectl logs "$POD" > "$LOG" 2>&1
echo "saved $(wc -l < $LOG) lines to $LOG"

echo
echo '=== profile / kv-cache / memory key lines ==='
grep -nE 'profile|kv.?cache|Available|GPU memory|NPU memory|peak|allocated_bytes|non_torch|OOM|memory.profil|gpu_memory_utilization|KV cache|free memory|Initial free' "$LOG" | head -80

echo
echo '=== first 30 vxpu_meminfo_shim lines ==='
grep -n 'vxpu_meminfo_shim' "$LOG" | head -30

echo
echo '=== count vxpu lines ==='
grep -c 'vxpu_' "$LOG"
echo

echo '=== last applied=1 line ==='
grep -n 'applied=1' "$LOG" | tail -5
echo
echo '=== unique applied values ==='
grep -oE 'applied=[0-9]+' "$LOG" | sort | uniq -c
echo
echo '=== unique via= values ==='
grep -oE 'via=[a-z]+' "$LOG" | sort | uniq -c
