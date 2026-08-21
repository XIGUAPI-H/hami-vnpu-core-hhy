#!/bin/bash
echo '=== job status ==='
kubectl get job mhw-normal-job-ray-head -o yaml 2>/dev/null | tail -40
echo
echo '=== pod history (rkpvt) ==='
kubectl describe pod mhw-normal-job-ray-head-rkpvt 2>/dev/null | tail -60
echo
echo '=== current pods ==='
kubectl get pods | grep -E 'mhw|vllm|vnpu'
echo
echo '=== podgroup ==='
kubectl get podgroup 2>/dev/null | tail -10
echo
echo '=== OOM in dmesg (last 5min) ==='
dmesg -T 2>/dev/null | tail -200 | grep -iE 'oom|killed|memory' | tail -20
