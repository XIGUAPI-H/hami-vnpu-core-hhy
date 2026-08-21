#!/usr/bin/env bash
set -euo pipefail
export PATH="/root/.cargo/bin:$PATH"
export CARGO_NET_OFFLINE=true
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"
mkdir -p /work/.cargo
cat > /work/.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "vendor"
EOF
cargo build --release -p hook -p limiter --offline
sha256sum target/release/libvnpu.so target/release/limiter
nm -D target/release/libvnpu.so 2>/dev/null | grep -E 'wait_for_token|end_kernel_burst' | head -5 || true
