#!/bin/bash
for i in 0 1 2 3 4 5 6 7; do
  echo "=== dev $i ==="
  npu-smi info -t proc-mem -i "$i" -c 0 2>/dev/null | grep -E "Process id|Process name|No process"
done
