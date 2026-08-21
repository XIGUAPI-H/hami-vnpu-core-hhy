#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo '=== before: NPU 0 HBM ==='
npu-smi info -t usages -i 0 -c 0 2>&1 | grep -E 'HBM|NPU ID'
echo
echo '=== delete pod (releases hami partition) ==='
kubectl delete -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml --ignore-not-found=true 2>&1 | head -5
for i in $(seq 1 10); do
  kubectl get pods 2>/dev/null | grep -q mhw-hami-soft || { echo "pod gone"; break; }
  sleep 2
done

echo
echo '=== look for residual ascend processes ==='
ps aux | grep -E 'limiter|libvnpu|ascend|davinci' | grep -v grep | head -10
echo
echo '=== kill leftover hami workers ==='
pkill -9 -f libvnpu.so 2>/dev/null || true
pkill -9 -f /mnt/local/m00953550/FinalTest/New/release/limiter 2>/dev/null || true
sleep 2

echo
echo '=== probe device file holders ==='
fuser /dev/davinci0 2>&1 | head -5

echo
echo '=== try chip-level memory reset (-t mem-reset) ==='
npu-smi set -t mem-reset -i 0 -c 0 2>&1 | head -5
echo
echo '=== try full chip reset ==='
npu-smi set -t reset -i 0 -c 0 2>&1 | head -5
sleep 5

echo
echo '=== after: NPU 0 HBM ==='
npu-smi info -t usages -i 0 -c 0 2>&1 | grep -E 'HBM|NPU ID'
echo
echo '=== re-apply yaml ==='
kubectl apply -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
sleep 3
kubectl get pods | grep mhw-hami-soft
EOF
