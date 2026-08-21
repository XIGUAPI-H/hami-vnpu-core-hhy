#!/usr/bin/env bash
set -eo pipefail
export PATH="/root/.cargo/bin:${PATH}"
cd /mnt/local/m00953550/hami-vnpu-core-main
cargo fetch
echo "fetch ok"
