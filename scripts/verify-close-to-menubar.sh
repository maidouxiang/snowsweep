#!/bin/sh
# 关窗收进菜单栏的 UI 回归验证。
#
# 验证真实 AppKit 生命周期，而不是只测 RunModePolicy：
#   1. 打开主窗口 → 激活策略 Foreground、窗口数 >= 1；
#   2. 点红色关闭按钮 → 进程仍在、窗口数 0、激活策略 UIElement；
#   3. 顶部菜单栏仍有「雪」状态项；
#   4. 再按 Bundle ID 打开 → 恢复 Foreground 与主窗口；
#   5. 按脚本启动前的状态收尾，不改变用户原来的开窗/关窗状态。
#
# 依赖辅助功能权限；这是本机自用验收脚本，不进入 App 运行时。
set -eu

APP="/Applications/雪.app"
PROCESS="SnowSweepApp"
BUNDLE_ID="com.selfuse.xue"

fail() {
  echo "  [失败] $1"
  exit 1
}

app_type() {
  lsappinfo info -only ApplicationType "$1" 2>/dev/null \
    | sed -n 's/.*type="\([^"]*\)".*/\1/p' | head -n 1
}

window_count() {
  osascript -e "tell application \"System Events\" to count windows of application process \"$PROCESS\"" 2>/dev/null || echo -1
}

menu_bar_count() {
  osascript -e "tell application \"System Events\" to tell application process \"$PROCESS\" to count menu bars" 2>/dev/null || echo -1
}

menubar_item_description() {
  osascript -e "tell application \"System Events\" to tell application process \"$PROCESS\" to get description of menu bar item 1 of menu bar 2" 2>/dev/null || echo ""
}

click_close_button() {
  osascript -e "tell application \"System Events\" to tell application process \"$PROCESS\" to click button 1 of window 1" >/dev/null
}

wait_for() {
  label="$1"
  shift
  count=0
  while [ "$count" -lt 20 ]; do
    if "$@"; then return 0; fi
    count=$((count + 1))
    sleep 0.5
  done
  fail "$label 未在 10 秒内达到预期"
}

is_foreground_with_window() {
  pid="$(pgrep -x "$PROCESS" || true)"
  [ -n "$pid" ] || return 1
  [ "$(app_type "$pid")" = "Foreground" ] || return 1
  [ "$(window_count)" -ge 1 ] || return 1
}

is_menubar_only() {
  pid="$(pgrep -x "$PROCESS" || true)"
  [ -n "$pid" ] || return 1
  [ "$(app_type "$pid")" = "UIElement" ] || return 1
  [ "$(window_count)" -eq 0 ] || return 1
}

echo "== 关窗收进菜单栏 UI 回归 =="
[ -d "$APP" ] || fail "没有找到 $APP"
if pgrep -f "/Applications/SnowSweep.app/Contents/MacOS/SnowSweepApp" >/dev/null 2>&1; then
  fail "旧 SnowSweep 也在运行，进程同名会干扰 UI 回归；请先退出旧版"
fi

initial_open=0
if pgrep -x "$PROCESS" >/dev/null 2>&1 && [ "$(window_count)" -ge 1 ]; then
  initial_open=1
fi
echo "  启动前状态：$([ "$initial_open" -eq 1 ] && echo 主窗口打开 || echo 仅菜单栏)"

open -b "$BUNDLE_ID"
wait_for "打开主窗口" is_foreground_with_window
pid="$(pgrep -x "$PROCESS")"
echo "  [通过] 打开：pid=$pid type=Foreground windows=$(window_count)"

click_close_button
wait_for "关闭主窗口" is_menubar_only
echo "  [通过] 关窗：进程仍在，type=UIElement windows=0"
[ "$(menu_bar_count)" -ge 2 ] || fail "顶部菜单栏没有恢复"
description="$(menubar_item_description)"
[ "$description" = "雪" ] || fail "顶部状态项不是「雪」，实际：$description"
echo "  [通过] 顶部菜单栏状态项：$description"

open -b "$BUNDLE_ID"
wait_for "重新打开主窗口" is_foreground_with_window
echo "  [通过] 重开：type=Foreground windows=$(window_count)"

if [ "$initial_open" -eq 0 ]; then
  click_close_button
  wait_for "恢复仅菜单栏" is_menubar_only
  echo "  [收尾] 已恢复启动前的仅菜单栏状态"
else
  echo "  [收尾] 保持启动前的主窗口打开状态"
fi

echo "结果：通过"
