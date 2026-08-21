#!/bin/bash
# Install the patched optimized artifacts into the A/B release dir on 68,
# keeping a timestamped backup of whatever was there before.
set -euo pipefail
SRC=/root/burstfix-check/target/release
DST=/mnt/local/m00953550/FinalTest/kylin/release-optimized
TS=$(date +%Y%m%d_%H%M%S)

echo "=== previous artifacts"
sha256sum "$DST/libvnpu.so" "$DST/limiter" 2>/dev/null || true
cat "$DST/sha256.txt" 2>/dev/null || true

mkdir -p "$DST/backup_burstfix_$TS"
cp -a "$DST/libvnpu.so" "$DST/limiter" "$DST/backup_burstfix_$TS/"

install -m 755 "$SRC/libvnpu.so" "$DST/libvnpu.so"
install -m 755 "$SRC/limiter" "$DST/limiter"
sha256sum "$DST/libvnpu.so" "$DST/limiter" | tee "$DST/sha256.txt"

echo "=== origin artifacts (unchanged, for reference)"
sha256sum /mnt/local/m00953550/FinalTest/kylin/release-origin/libvnpu.so \
          /mnt/local/m00953550/FinalTest/kylin/release-origin/limiter
echo "=== backup at $DST/backup_burstfix_$TS"
