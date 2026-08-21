#!/bin/bash
# Diagnose the HAMI device-plugin mode on the local node.
LABEL=${1:-?}
echo "################ $LABEL ################"

echo '=== hami-ascend-device-plugin command/args ==='
POD=$(kubectl get pods -n kube-system -o name 2>/dev/null | grep hami-ascend-device-plugin | head -1)
echo "pod=$POD"
[ -n "$POD" ] && {
  kubectl get $POD -n kube-system -o yaml 2>/dev/null | grep -A2 -E 'image:|command:|args:|name: '
}
echo
echo '=== hami-device-plugin configmap ==='
kubectl get cm -n kube-system hami-device-plugin -o yaml 2>/dev/null | head -60
echo
echo '=== hami-scheduler-device configmap ==='
kubectl get cm -n kube-system hami-scheduler-device -o yaml 2>/dev/null | head -80
echo
echo '=== running vLLM pod / its actual resources / its phys_total via exec ==='
VPOD=$(kubectl get pods --no-headers 2>/dev/null | awk '/Running/ && /(mhw-normal|mhw-hami-soft|vllm)/ {print $1; exit}')
echo "vllm-pod=$VPOD"
if [ -n "$VPOD" ]; then
    kubectl get pod "$VPOD" -o jsonpath='{.spec.containers[0].resources}'; echo
    echo
    echo '--- npu-smi inside the running pod (best-effort) ---'
    kubectl exec "$VPOD" -- bash -c 'cat /proc/self/status | grep -E "Pid|Name|Threads"; echo; npu-smi info -t usages -i 0 -c 0 2>/dev/null | grep -E "HBM Cap|HBM Usage|Aicore" | head -5' 2>&1 | head -15
    echo
    echo '--- torch_npu memory_stats inside the pod ---'
    kubectl exec "$VPOD" -- bash -c "python3 -c 'import torch, torch_npu; torch.npu.set_device(0); import json; print(json.dumps({k:v for k,v in torch_npu.npu.memory_stats().items() if \"peak\" in k or \"reserve\" in k or \"alloc\" in k.lower() or \"total\" in k.lower()},indent=2)); print(\"npu0 props:\", torch.npu.get_device_properties(0))'" 2>&1 | head -50
fi
