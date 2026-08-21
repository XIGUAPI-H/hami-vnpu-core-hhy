#!/usr/bin/env bash
# Runs INSIDE the Kylin container. Builds hook+limiter linked against the
# container's glibc (2.38) + Kylin cc, producing a true Kylin-native artifact.
set -euo pipefail

export PATH="/root/.cargo/bin:$PATH"
export CARGO_HOME=/root/.cargo
export RUSTUP_HOME=/root/.rustup
# Separate target dir so we never clobber the host (Ubuntu) build.
export CARGO_TARGET_DIR=/work/target-kylin
# Target the Kunpeng-920 core (rustc 'native' resolves to tsv110 on this host).
# Explicit > native: keeps the same CPU optimizations but is reproducible and
# portable across all Kunpeng-920 boxes (the standard Ascend 910B host CPU).
TARGET_CPU="${TARGET_CPU:-tsv110}"
# Provide Ascend driver lib paths so the linker can resolve transitive deps
# (libruntime/libascend_trace -> driver hal/drv symbols) inside the container.
DRV=/usr/local/Ascend/driver/lib64
export RUSTFLAGS="-C target-cpu=${TARGET_CPU} \
-L ${DRV} -L ${DRV}/common -L ${DRV}/driver \
-C link-arg=-Wl,-rpath-link,${DRV} \
-C link-arg=-Wl,-rpath-link,${DRV}/common \
-C link-arg=-Wl,-rpath-link,${DRV}/driver"

echo "[kylin-build] runtime: $(grep -h PRETTY_NAME /etc/os-release | cut -d= -f2)"
echo "[kylin-build] glibc:   $(ldd --version | head -1)"
echo "[kylin-build] cc:      $(cc --version | head -1)"
echo "[kylin-build] cargo:   $(cargo --version)"

cd /work
cargo build --release -p hook -p limiter --features optimized

install -d "$OUT"
install -m 755 /work/target-kylin/release/libvnpu.so "$OUT/libvnpu.so"
install -m 755 /work/target-kylin/release/limiter "$OUT/limiter"
sha256sum "$OUT/libvnpu.so" "$OUT/limiter" | tee "$OUT/sha256.txt"

echo "[kylin-build] linked NEEDED libc:"
objdump -p "$OUT/libvnpu.so" 2>/dev/null | grep -E 'NEEDED|GLIBC_2\.3[0-9]' | head -10 || true
echo "[kylin-build] deployed to $OUT"
