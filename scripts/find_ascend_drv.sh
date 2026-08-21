#!/bin/bash
echo "=== driver lib64 tree ==="
ls /usr/local/Ascend/driver/lib64/
echo "=== .so under driver ==="
find /usr/local/Ascend/driver -name '*.so' 2>/dev/null
echo "=== providers of halGetDeviceInfo / drvHdcSend ==="
for f in $(find /usr/local/Ascend/driver -name '*.so' 2>/dev/null); do
  if nm -D "$f" 2>/dev/null | grep -Eq ' T (halGetDeviceInfo|drvHdcSend|halHdcSend)'; then
    echo "PROVIDES: $f"
  fi
done
echo "=== host ld.so.conf ascend ==="
grep -rh -i ascend /etc/ld.so.conf /etc/ld.so.conf.d/ 2>/dev/null
