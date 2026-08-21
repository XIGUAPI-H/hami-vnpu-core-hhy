#!/bin/bash
# Clippy the burst-enforcement patch on the 68 (Kylin/aarch64) host, filtered to
# the burst code so pre-existing lints in the rest of the crate stay out of view.
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/burstfix-check || exit 1
cargo clippy --offline -p limiter >/root/bfclippy.log 2>&1
echo "cargo clippy rc=$?"
echo '--- errors:'
grep -n -A10 '^error' /root/bfclippy.log | head -60
echo '--- lints inside the patched line range (1100-1450):'
awk '/^warning|^error/{buf=$0; getline l; if (l ~ /worker\.rs:(11|12|13|14)[0-9][0-9]:/) print buf"\n"l}' /root/bfclippy.log
echo '--- summary:'
grep -E 'generated [0-9]+ warnings|Finished' /root/bfclippy.log
