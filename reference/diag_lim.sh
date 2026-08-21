#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
echo '===limiter proc in container==='
kubectl exec $POD -n $NS -- bash -lc 'ps aux | grep -i limiter | grep -v grep || echo NO_LIMITER_PROC'
echo '===limiter log tail==='
kubectl exec $POD -n $NS -- bash -lc 'tail -n 25 /tmp/limiter.log 2>/dev/null || echo NO_LIMITER_LOG'
echo '===shared region / shm==='
kubectl exec $POD -n $NS -- bash -lc 'echo "[/hami-shared-region]"; ls -la /hami-shared-region 2>/dev/null || echo MISSING; echo "[/dev/shm]"; ls -la /dev/shm 2>/dev/null'
echo '===env==='
kubectl exec $POD -n $NS -- bash -lc 'env | grep -E "NPU_GLOBAL|NPU_LOCAL|NPU_MEM|VXPU|ASCEND_RT_VISIBLE|ASCEND_VISIBLE"'
