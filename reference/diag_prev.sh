#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
echo '===prev container: error/oom/kv/quota lines==='
kubectl logs $POD -n $NS --previous 2>&1 | grep -iE 'NPU out of memory|Quota Exceeded|GPU KV cache|Available memory|RuntimeError|Engine core|EngineCore failed|Error|Traceback|startup complete' | grep -vE 'vnpu-standalone|halGetDeviceInfo' | tail -30
echo '===prev container: very last 12 lines==='
kubectl logs $POD -n $NS --previous 2>&1 | grep -vE 'vnpu-standalone|halGetDeviceInfo' | tail -12
echo '===which physical device does the worker open? (ASCEND env + visible)==='
kubectl exec $POD -n $NS -- bash -lc 'env | grep -iE "ASCEND_RT_VISIBLE|ASCEND_VISIBLE|ASCEND_DEVICE_ID"' 2>/dev/null
