#!/bin/bash
# Release-build the patched tree with the same feature set as the deployed
# optimized artifact, to confirm the burst-enforcement patch compiles in the
# configuration that actually ships.
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/burstfix-check || exit 1
cargo build --release --offline -p hook -p limiter --features optimized >/root/bfbuild.log 2>&1
echo "cargo build rc=$?"
grep -n -A10 '^error' /root/bfbuild.log | head -60
grep -E 'Finished|warning: `limiter`|warning: `hook`' /root/bfbuild.log
ls -la target/release/libvnpu.so target/release/limiter 2>/dev/null
nm -D target/release/libvnpu.so 2>/dev/null | grep -cE 'wait_for_token|end_kernel_burst'
