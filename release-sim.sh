#!/bin/sh
# SnowSweep 发布前仿真验收一键入口（V1.0.0 准入门槛）。
#
# 仿真多人物画像（不同文件布局 / 自定义保护清单 / 勾选行为），
# 每人跑 3 轮（首次清理 → 重扫幂等 → 变更体删除被拒），
# 从 8 个维度断言：判定 / 闸门 / 复核 / 审计 / 幂等 / 性能 / 边界 / 中文标识。
#
# 用生产同款真实组件（真实 RuleEngine / NativeScanner / SystemFileTrasher /
# SystemTargetVerifier / AuditLog），样本带 token，结束精确自清理，不碰用户文件。
#
# 退出码 0 = 全部断言通过，才允许进入 V1.0.0 自用正式版发布。
set -eu
cd "$(dirname "$0")"

echo "== 编译仿真验收程序 =="
swift build --disable-sandbox --product ReleaseSim

echo
echo "== 运行发布前仿真验收 =="
exec swift run --disable-sandbox ReleaseSim
