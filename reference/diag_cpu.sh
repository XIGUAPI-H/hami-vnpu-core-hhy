#!/bin/bash
POD=mhw-hami-soft-1split4-a
NS=default
get() { kubectl exec $POD -n $NS -- bash -lc 'awk "{print \$14+\$15}" /proc/88/task/88/stat 2>/dev/null'; }
echo "main-thread(88) utime+stime ticks sample1: $(get)"
sleep 20
echo "main-thread(88) utime+stime ticks sample2: $(get)"
echo '===last real vllm worker log line==='
kubectl logs $POD -n $NS 2>&1 | grep -E 'Worker pid=88|EngineCore|backends.py|GPU KV cache|Available memory|capturing|startup complete' | grep -v vnpu-standalone | tail -6
