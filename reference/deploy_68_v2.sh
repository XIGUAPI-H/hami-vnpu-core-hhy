#!/bin/bash
set -u
SRC=/mnt/local/build/hami-vnpu-core/target/release
DST_HOST=10.143.2.68
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo '=== upload new binaries to 68 (staging) ==='
scp $SSH_OPTS "$SRC/libvnpu.so" root@$DST_HOST:/tmp/libvnpu.so.new
scp $SSH_OPTS "$SRC/limiter"    root@$DST_HOST:/tmp/limiter.new

echo
echo '=== orchestrate stop-swap-restart on 68 ==='
ssh $SSH_OPTS root@$DST_HOST 'bash -s' <<'EOF'
set -u
echo '--- delete pod ---'
kubectl delete -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml --ignore-not-found=true 2>&1 | head -10
echo '--- wait for pod gone ---'
for i in $(seq 1 15); do
  kubectl get pods 2>/dev/null | grep -q mhw-hami-soft || { echo "pod gone"; break; }
  sleep 2
done

echo '--- kill leftover limiter daemons (it holds the binary) ---'
pkill -f /mnt/local/m00953550/FinalTest/New/release/limiter 2>/dev/null || true
sleep 1

echo '--- swap files ---'
cp -f /tmp/libvnpu.so.new /mnt/local/m00953550/FinalTest/New/release/libvnpu.so
cp -f /tmp/limiter.new    /mnt/local/m00953550/FinalTest/New/release/limiter
chmod +x /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter
ls -la /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter
sha256sum /mnt/local/m00953550/FinalTest/New/release/libvnpu.so /mnt/local/m00953550/FinalTest/New/release/limiter

echo '--- re-apply yaml ---'
kubectl apply -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
sleep 3
kubectl get pods | grep mhw-hami-soft || true
EOF
