#!/bin/bash
# Which NPUs are already claimed by long-running containers, and which NPU did the
# previous T5 1cut4/1cut20 A/B campaign use?
echo "=== devices held per container"
for c in $(docker ps --format '{{.Names}}' | grep -v '^k8s_'); do
  devs=$(docker inspect "$c" --format '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' 2>/dev/null \
         | tr ' ' '\n' | grep -o 'davinci[0-9]*' | tr '\n' ',' )
  [[ -n "$devs" ]] && echo "$c -> $devs"
done
echo
echo "=== processes on each davinci device"
for d in 0 1 2 3 4 5 6 7; do
  n=$(lsof "/dev/davinci$d" 2>/dev/null | tail -n +2 | wc -l)
  echo "davinci$d: $n open fds"
done
echo
echo "=== NPU used by previous cut4_20 campaign (from bench logs)"
LOGDIR=/mnt/local/m00953550/FinalTest/kylin/smallmodel_ab/robust_cut4_20/logs
grep -ho 'npu=[0-9]*' "$LOGDIR"/../*.log 2>/dev/null | sort | uniq -c | head
grep -rho 'ASCEND_RT_VISIBLE_DEVICES=[0-9]*' "$LOGDIR" 2>/dev/null | sort | uniq -c | head
