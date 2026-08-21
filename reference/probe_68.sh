#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo '=== npu-smi info -t topo ==='
npu-smi info -t topo 2>&1 | head -20
echo
echo '=== npu-smi info -t board ==='
npu-smi info -t board -i 0 2>&1 | head -30
echo
echo '=== npu-smi info -t usages -i 0 ==='
npu-smi info -t usages -i 0 2>&1
echo
echo '=== npu-smi info -t mem -i 0 -c 0 ==='
npu-smi info -t mem -i 0 -c 0 2>&1
echo
echo '=== npu-smi info -t proc-mem -i 0 -c 0 ==='
npu-smi info -t proc-mem -i 0 -c 0 2>&1
echo
echo '=== HBM full info ==='
npu-smi info  2>&1 | head -40
echo
echo '=== other pods that may consume NPU ==='
kubectl get pods -A -o wide 2>/dev/null | grep -E 'Running|Pending|NAME' | head -30
echo
echo '=== Ascend910B3 resource allocation ==='
kubectl describe node master-node 2>/dev/null | grep -E 'huawei.com|Allocated|Capacity:' | head -30
EOF
