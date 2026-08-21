#!/bin/bash
set -u
IMG=quay.io/ascend/vllm-ascend:v0.13.0rc1
docker run --rm "$IMG" bash -c '
set -u
TP=$(python3 -c "import torch_npu; import os; print(os.path.dirname(torch_npu.__file__))" 2>/dev/null || echo /usr/local/python3.11.13/lib/python3.11/site-packages/torch_npu)
echo "torch_npu dir=$TP"
for so in "$TP"/lib/*.so "$TP"/*.so; do
  [ -f "$so" ] || continue
  echo "=== $so ==="
  nm -D "$so" 2>/dev/null | grep -iE "GetDevice|MemInfo|DeviceProp|DeviceInfo|GetMem|total|HBM" | head -40
done
echo
echo "=== strings torch_npu (device/mem) ==="
strings "$TP"/lib/libtorch_npu.so 2>/dev/null | grep -iE "aclrtGet|rtGet|rtMem|GetDevice|mem_get|total_memory|HBM" | sort -u | head -60
echo
echo "=== driver runtime symbols ==="
for lib in /usr/local/Ascend/driver/lib64/driver/libruntime.so /usr/local/Ascend/driver/lib64/libascendcl.so; do
  [ -f "$lib" ] || continue
  echo "--- $lib ---"
  nm -D "$lib" 2>/dev/null | grep -iE "rtGetDeviceInfo|rtMemGetInfo|GetDeviceAttr|aclrtGetDevice" | head -20
done
'
