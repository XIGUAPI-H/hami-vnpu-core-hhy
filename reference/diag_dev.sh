#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
echo '===davinci devices mounted IN container==='
kubectl exec $POD -n $NS -- bash -lc 'ls -l /dev/davinci* 2>/dev/null' 2>/dev/null
echo '===ASCEND env in container==='
kubectl exec $POD -n $NS -- bash -lc 'env | grep -iE "ASCEND_RT_VISIBLE|ASCEND_VISIBLE|ASCEND_DEVICE"' 2>/dev/null
echo '===what device does CANN pick? (npu-smi mapping host)==='
npu-smi info -m 2>/dev/null | head -20
echo '===host davinci device files==='
ls -l /dev/davinci* 2>/dev/null
