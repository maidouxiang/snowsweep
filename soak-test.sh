#!/bin/sh
# SnowSweep 自用浸泡压力测试一键入口。
#
# 用生产同款真实组件跑数百轮重复清理闭环，观察内存 / 句柄 / 性能趋势，
# 验证长时间自用下无泄漏、无劣化、审计链完整、零误删。
#
# 本机数据安全（代码级强制）：
#   样本只在 Caches/SnowSweepSoak-<token>/ 生成；删除闸门要求路径命中
#   隔离根 + token 前缀；每轮结束按 token 精确清除，不碰用户现有文件。
#
# 用法：
#   ./soak-test.sh                 # 默认 300 轮
#   ./soak-test.sh --quick         # 12 轮冒烟
#   ./soak-test.sh --rounds 1000   # 自定义轮数
#   ./soak-test.sh --interval 0.5  # 每轮间隔 0.5 秒（更贴近真实自用节奏）
#
# 退出码 0 = 全绿且无泄漏趋势；非 0 = 存在失败项。
set -eu
cd "$(dirname "$0")"

echo "== 编译浸泡压测程序 =="
swift build --disable-sandbox --product SoakTest

echo
echo "== 运行浸泡压力测试 =="
exec swift run --disable-sandbox SoakTest "$@"
