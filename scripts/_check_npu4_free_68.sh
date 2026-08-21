#!/bin/bash
# Is NPU 4 clear enough to host the Qwen-TTS A/B, or is a previous run still on it?
echo "=== npu-smi process table"
npu-smi info | grep -E '^\| [0-9]+ +[0-9]+ +\| [0-9]+' || echo "(no process rows)"
echo
echo "=== all NPU processes with owning container"
for pid in $(npu-smi info | awk -F'|' '/^\| *[0-9]+ +[0-9]+ *\|/ {gsub(/ /,"",$3); if ($3 ~ /^[0-9]+$/) print $3}'); do
  echo "--- pid=$pid"
  ps -o pid,etime,cmd -p "$pid" --no-headers 2>/dev/null || echo "  (gone)"
  for c in $(docker ps -q); do
    if docker top "$c" 2>/dev/null | grep -qw "$pid"; then
      docker inspect --format '  container: {{.Name}}' "$c"
    fi
  done
done
echo
echo "=== leftover qwen containers / limiters"
docker ps --format '{{.Names}}' | grep -i qwen || echo "(none)"
pgrep -af '/opt/hami/limiter|/opt/vnpu/limiter' || echo "(no stray limiters)"
