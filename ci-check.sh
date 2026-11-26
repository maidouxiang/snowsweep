#!/bin/sh
# SnowSweep CI 自检：
# 1) 正常构建 + 全量测试（有 Foundation Models 的环境）
# 2) 定义 SNOWSWEEP_DISABLE_AI 后再构建 + 测试，模拟低版本 macOS / 无模型框架
# 两个场景都必须通过，确保模型层是可选增强而非硬依赖。
#
# 默认在 /tmp 的干净副本里跑：
# 本机 macOS 在 Desktop 路径上会让 SwiftPM 链接测试包时卡在 getxattr（TCC），
# 复制到非 Desktop 路径后链接正常。CI 只验代码，不依赖现场构建缓存，
# 干净副本也避免把双场景构建产物留回项目目录。
# 需要在原目录直接跑时：SNOWSWEEP_CI_IN_PLACE=1 ./ci-check.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

if [ "${SNOWSWEEP_CI_IN_PLACE:-0}" != "1" ] && [ "${SNOWSWEEP_CI_IN_TEMP:-0}" != "1" ]; then
    TMP=$(mktemp -d /tmp/snowsweep-ci.XXXXXX)
    trap 'rm -rf "$TMP"' EXIT HUP INT TERM
    echo "== 准备 CI 干净副本 =="
    echo "  源目录: $ROOT"
    echo "  副本:   $TMP"
    rsync -a --exclude '.build/' --exclude '.git/' --exclude '.DS_Store' "$ROOT/" "$TMP/"
    cd "$TMP"
    SNOWSWEEP_CI_IN_TEMP=1 ./ci-check.sh
    exit 0
fi

cd "$ROOT"

echo "== 场景一：完整能力 =="
./build.sh
./test.sh

echo "== 场景二：关闭端侧模型（模拟无 Foundation Models） =="
./build.sh -Xswiftc -DSNOWSWEEP_DISABLE_AI
./test.sh -Xswiftc -DSNOWSWEEP_DISABLE_AI

echo "全部通过"
