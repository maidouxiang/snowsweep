#!/bin/sh
# SnowSweep 清理闭环 · 真机实测一键入口。
#
# 与单元测试不同：这里用真实文件系统 + 真实扫描器 + 真实规则库 +
# 真实废纸篓（SystemFileTrasher）+ 真实审计链，跑通完整清理闭环，
# 并对每个安全断言做验证。测试样本带随机 token，运行结束自动从
# 废纸篓与 Caches 精确清除，不碰用户任何现有文件。
#
# 退出码 0 = 全部断言通过；非 0 = 存在失败项。
set -eu
cd "$(dirname "$0")"

echo "== 编译真机实测程序 =="
swift build --disable-sandbox --product CleanupE2E

echo
echo "== 运行清理闭环真机实测 =="
exec swift run --disable-sandbox CleanupE2E
