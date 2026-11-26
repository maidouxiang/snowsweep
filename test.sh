#!/bin/sh
# SnowSweep 测试入口，自动携带 --disable-sandbox。
set -eu
cd "$(dirname "$0")"
exec swift test --disable-sandbox "$@"
