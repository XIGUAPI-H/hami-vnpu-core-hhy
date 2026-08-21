#!/bin/bash
set -u
SRC=/mnt/local/build/hami-vnpu-core/target/release
DST_HOST=10.143.2.68
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

scp $SSH_OPTS "$SRC/libvnpu.so" root@$DST_HOST:/tmp/libvnpu.so.new
scp $SSH_OPTS "$SRC/limiter"    root@$DST_HOST:/tmp/limiter.new

ssh $SSH_OPTS root@$DST_HOST 'bash -s' <<'EOF'
set -u
kubectl delete -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml --ignore-not-found=true 2>&1 | head -5
sleep 5
pkill -9 -f /mnt/local/m00953550/FinalTest/New/release/limiter 2>/dev/null || true
cp -f /tmp/libvnpu.so.new /mnt/local/m00953550/FinalTest/New/release/libvnpu.so
cp -f /tmp/limiter.new    /mnt/local/m00953550/FinalTest/New/release/limiter
chmod +x /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter
sha256sum /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter
kubectl apply -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
sleep 5
kubectl get pods | grep mhw-hami-soft
EOF
