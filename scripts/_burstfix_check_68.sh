#!/bin/bash
# Type-check the burst-enforcement patch on the 68 (Kylin/aarch64) host.
# The local Windows checkout has no `vendor/`, so checking happens here against
# the vendored registry of an existing build tree.
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/burstfix-check || exit 1
cargo check --offline --workspace >/root/bfcheck.log 2>&1
rc=$?
echo "cargo check rc=$rc"
echo '--- error blocks:'
grep -n -A8 '^error' /root/bfcheck.log | head -80
echo '--- warnings mentioning burst:'
grep -n -B2 -A6 -i 'burst' /root/bfcheck.log | grep -i -A6 warning | head -60
echo '--- finished:'
grep -E 'Finished|^error' /root/bfcheck.log
