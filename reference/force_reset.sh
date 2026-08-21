#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo '=== before reset ==='
npu-smi info -t usages -i 0 -c 0 2>&1 | grep -E 'HBM Cap|HBM Usage'

echo '=== chip reset with auto-confirm ==='
echo Y | npu-smi set -t reset -i 0 -c 0 2>&1 | head -10
echo
echo '=== wait 15s for chip back up ==='
sleep 15

for i in $(seq 1 5); do
  out=$(npu-smi info -t usages -i 0 -c 0 2>&1 | grep 'HBM Usage Rate')
  echo "[t=${i}*5s] $out"
  sleep 5
done

echo
echo '=== restart hami device-plugin to reissue partitions ==='
kubectl delete pod -n kube-system $(kubectl get pods -n kube-system -o name | grep hami-ascend-device-plugin | head -1 | cut -d/ -f2) 2>&1 || true
sleep 8
kubectl get pods -n kube-system | grep hami-ascend
echo
echo '=== re-apply yaml ==='
kubectl apply -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
sleep 5
kubectl get pods | grep mhw-hami-soft
echo
echo '=== HBM now ==='
npu-smi info -t usages -i 0 -c 0 2>&1 | grep -E 'HBM Cap|HBM Usage'
EOF
