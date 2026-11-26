#!/bin/bash
# M4 真机验收助手：只读打印本机权限/启动项读数，供对照系统设置。
# 不做任何写入、不联网、不改动授权。需要 FDA 才能读到 TCC 与登录项。
set -u
echo "╔══════════════════════════════════════════╗"
echo "║  SnowSweep M4 验收助手（只读 / 零网络）  ║"
echo "╚══════════════════════════════════════════╝"
echo

echo "【1】完全磁盘访问权限（FDA）状态探测"
SYS="/Library/Application Support/com.apple.TCC/TCC.db"
if /usr/bin/sqlite3 -readonly "$SYS" "SELECT count(*) FROM access;" >/dev/null 2>&1; then
  echo "  ✅ 当前进程可读 TCC 数据库（FDA 已授予或系统放宽）"
else
  echo "  ⚠️  读不到 TCC 数据库 —— 请在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 中添加本 App"
fi
echo

echo "【2】权限授权读数（只读，仅已授权项）"
if /usr/bin/sqlite3 -readonly -separator $'\t' "$SYS" \
  "SELECT service, client, auth_value FROM access WHERE auth_value>=2;" 2>/dev/null | head -40; then
  :
fi
echo "  （若上面空白 = 读不到或无授权，对照 App「权限清单」页应显示缺口提示）"
echo

echo "【3】本机启动项 Label（只读，对照 App「启动项审查」页中文名）"
{ for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    for f in "$d"/*.plist; do
      [ -f "$f" ] || continue
      /usr/libexec/PlistBuddy -c 'Print :Label' "$f" 2>/dev/null
    done
  done; } | sort -u | sed 's/^/  • /'
echo

echo "【4】系统设置的登录项（需 FDA 才能读，读不到请人工对照）"
BTDIR="/var/db/com.apple.backgroundtaskmanagement"
if ls "$BTDIR" >/dev/null 2>&1; then
  echo "  ✅ 可访问 $BTDIR"
  find "$BTDIR" -maxdepth 1 -iname 'backgrounditems*.btm' 2>/dev/null | sed 's/^/  • /'
else
  echo "  ⚠️  不可访问（需 FDA）。请到 系统设置 › 通用 › 登录项与扩展 人工核对。"
fi
echo
echo "══════════════════════════════════════════"
echo "对照要点："
echo "  • App 权限清单的中文名/程序名 应与上面 client 一一对应"
echo "  • App 启动项审查的中文名 应与上面 Label 一一对应"
echo "  • 读不到的项 App 应显示缺口说明，不能空白、不能臆造"
echo "  • 全程无网络请求；App 不提供任何关闭/禁用开关"
