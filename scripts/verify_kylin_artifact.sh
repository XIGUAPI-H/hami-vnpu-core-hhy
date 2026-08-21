#!/bin/bash
# Verify the optimized artifact is compatible with the target Kylin box.
OUT="${OUT:-/mnt/local/m00953550/FinalTest/kylin/release-optimized}"
for f in libvnpu.so limiter; do
  p="$OUT/$f"
  echo "==================== $f ===================="
  file "$p"
  echo "-- sha256 --"; sha256sum "$p" | awk '{print $1}'
  echo "-- max GLIBC version required --"
  objdump -T "$p" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -3
  echo "-- NEEDED shared libs --"
  objdump -p "$p" 2>/dev/null | awk '/NEEDED/{print "   "$2}'
  echo "-- CPU build target hint (tsv110/Kunpeng-920) via .comment --"
  readelf -p .comment "$p" 2>/dev/null | grep -i rust | head -1
  echo
done
echo "Target box: Kylin V11 (Swan25) glibc 2.38, Kunpeng-920 (tsv110). Artifact must need glibc <= 2.38."
