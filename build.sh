#!/bin/sh
# SnowSweep 构建入口。本机 SwiftPM 默认沙盒会报 sandbox_apply，统一在这里关闭。
set -eu
cd "$(dirname "$0")"
exec swift build --disable-sandbox "$@"
