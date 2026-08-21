#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
echo '======== POD STATUS / RESTART ========'
kubectl get pod $POD -n $NS -o wide
printf 'restartCount='
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].restartCount}'
printf '\nlastTerminated reason='
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
printf ' exit='
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
printf ' signal='
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].lastState.terminated.signal}'
echo

echo '======== POD DEVICE ASSIGNMENT ========'
kubectl get pod $POD -n $NS -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep -iE 'ascend|device|npu|huawei' || echo none
echo '--- container env (visible devices) ---'
kubectl exec $POD -n $NS -- bash -lc 'env | grep -iE "VISIBLE_DEVICES|ASCEND_DEVICE"' 2>/dev/null

echo '======== HOST npu-smi (per-card mem/usage) ========'
npu-smi info 2>/dev/null | head -40

echo '======== dmesg host OOM / kill (last) ========'
dmesg -T 2>/dev/null | grep -iE 'oom|killed process|out of memory' | tail -10 || echo none

echo '======== kubelet/containerd recent kill events ========'
kubectl get events -n $NS --field-selector involvedObject.name=$POD 2>/dev/null | tail -15
