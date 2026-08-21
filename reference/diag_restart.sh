#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
echo '===status==='
kubectl get pod $POD -n $NS -o wide
echo '===restartCount==='
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].restartCount}'
echo
echo '===lastState (terminated reason/exit)==='
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{" exit="}{.status.containerStatuses[0].lastState.terminated.exitCode}{" sig="}{.status.containerStatuses[0].lastState.terminated.signal}'
echo
echo '===prev container last lines (no spam)==='
kubectl logs $POD -n $NS --previous 2>&1 | grep -vE 'vnpu-standalone|halGetDeviceInfo' | tail -30
