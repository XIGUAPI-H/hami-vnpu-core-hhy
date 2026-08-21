#!/bin/bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo '=== LD_PRELOAD / mounts / paths used by hamiNewVllm.yaml ==='
grep -E 'LD_PRELOAD|libvnpu|limiter|FinalTest|xpu' /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml | head -40
echo
echo '=== current libvnpu.so on disk ==='
ls -la /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter 2>&1
echo
echo '=== sha256 of current artifacts in expected dirs ==='
sha256sum /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter /opt/xpu/lib/libvnpu.so /opt/xpu/bin/limiter 2>&1
EOF
