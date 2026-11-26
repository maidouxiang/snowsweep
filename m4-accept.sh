#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  SnowSweep M4 一键验收 + 签核
#  用法：
#    ./m4-accept.sh             完整流程（自动检查 + FDA 引导 + 人工确认 + 签核报告）
#    ./m4-accept.sh --auto      只跑自动段，不弹对话框（CI/无人值守）
#    ./m4-accept.sh --help      帮助
#  安全：全程只读、零网络、不改动任何授权或启动项。唯一写入是签核报告 md。
# ═══════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 1

MODE="${1:-}"
AUTO=0
[ "$MODE" = "--auto" ] && AUTO=1
if [ "$MODE" = "--help" ]; then
  sed -n '2,9p' "$0" | sed 's/^#  \?//'
  exit 0
fi

# 单实例锁：防止重复运行导致多个对话框叠加（表现为"无限弹窗"）。
# 锁放在项目 .build 下（一定有写权限），用 mkdir 的原子性判重。
LOCKDIR=".build/m4-accept.lock"
mkdir -p .build
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "已有验收脚本在运行（锁：${LOCKDIR}）。"
  echo "如确认是上次异常退出残留的锁，执行：rm -rf $LOCKDIR 后重试。"
  exit 1
fi
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT INT TERM

PROBE_BIN=".build/debug/m4probe"
PROBE_JSON="/tmp/m4probe-output.json"
SYS_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
# --auto 只写临时报告，绝不覆盖完整交互模式生成的正式签核报告。
if [ "$AUTO" = "1" ]; then
  REPORT="docs/M4验收签核报告-自动复查.md"
else
  REPORT="docs/M4验收签核报告.md"
fi

# 颜色（非 TTY 自动关闭）
if [ -t 1 ]; then
  GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BLU=$'\033[34m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  GRN=""; RED=""; YEL=""; BLU=""; BLD=""; RST=""
fi

RESULT_LINES=()
PASS=0; FAIL=0; WARN=0
record() { # record 状态 描述
  local status="$1" desc="$2"
  RESULT_LINES+=("| $status | $desc |")
  case "$status" in
    "✅ 通过") PASS=$((PASS+1)) ;;
    "❌ 失败") FAIL=$((FAIL+1)) ;;
    "⚠️ 人工") WARN=$((WARN+1)) ;;
  esac
  printf '  %s%s%s  %s\n' "$([ "$status" = "✅ 通过" ] && echo "$GRN" || [ "$status" = "❌ 失败" ] && echo "$RED" || echo "$YEL")" "$status" "$RST" "$desc"
}

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }
head() { printf '\n%s%s%s\n' "$BLD$BLU" "$1" "$RST"; hr; }

printf '%s\n' "╔══════════════════════════════════════════════════════════╗"
printf '%s\n' "║   SnowSweep · M4 一键验收 + 签核（只读 / 零网络）         ║"
printf '%s\n' "╚══════════════════════════════════════════════════════════╝"

# ── 0. 前置：编译探针 ─────────────────────────────────────────
head "0 · 前置检查"
if ./build.sh >/tmp/m4-build.log 2>&1; then
  record "✅ 通过" "工程构建成功（build.sh）"
else
  record "❌ 失败" "工程构建失败，见 /tmp/m4-build.log"
  echo "构建失败，无法继续。"; exit 1
fi
if swiftc -I .build/debug -L .build/debug -lSnowSweepCore scripts/M4Probe.swift -o "$PROBE_BIN" 2>/tmp/m4probe-build.log; then
  record "✅ 通过" "验收探针编译成功"
else
  record "❌ 失败" "探针编译失败，见 /tmp/m4probe-build.log"; exit 1
fi
if ./test.sh >/tmp/m4-test.log 2>&1; then
  pass_count=$(grep -c 'tests passed' /tmp/m4-test.log 2>/dev/null | tr -d ' ')
  [ -z "$pass_count" ] && pass_count="若干"
  record "✅ 通过" "全量单元测试通过（${pass_count}，双场景另见 ci-check.sh）"
else
  record "❌ 失败" "单元测试失败，见 /tmp/m4-test.log"
fi
"$PROBE_BIN" > "$PROBE_JSON" 2>/dev/null
jval() { jq -r "$1" "$PROBE_JSON" 2>/dev/null; }

# ── 1. 数据层：真实 Inspector 读数 ────────────────────────────
head "1 · 数据层（真实 Inspector，非模拟）"
start_items=$(jval '.startup.items')
untranslated_count=$(jval '.startup.untranslated | length')
hedge_wrong=$(jval '.startup.hedgeMistakenAsEdge')
perm_complete=$(jval '.permission.isComplete')
tcc_denied=$(jval '.permission.hasTCCDeniedGap')
blocks_ok=$(jval '.permission.blocksResultCorrectly')
has_login_gap=$(jval '.startup.hasLoginItemsGap')

if [ "$start_items" -ge 1 ] 2>/dev/null; then
  record "✅ 通过" "启动项采集到 $start_items 条真实配置"
else
  record "❌ 失败" "启动项采集为 0 条"
fi
if [ "$untranslated_count" = "0" ]; then
  record "✅ 通过" "启动项中文标识全覆盖（无'后台服务/未知程序'遗留）"
else
  record "❌ 失败" "仍有 $untranslated_count 条未翻译成中文"
fi
if [ "$hedge_wrong" = "false" ]; then
  record "✅ 通过" "无 Hedge→Edge 误匹配"
else
  record "❌ 失败" "Hedge 被误认成 Edge 浏览器"
fi
if [ "$tcc_denied" = "true" ] && [ "$blocks_ok" = "true" ]; then
  record "✅ 通过" "权限读不到时给出 tccDenied 缺口且 blocksResult=true（不是空白）"
elif [ "$perm_complete" = "true" ]; then
  record "✅ 通过" "权限数据库可读且已完整采集"
else
  record "❌ 失败" "权限缺口行为异常"
fi
if [ "$has_login_gap" = "true" ]; then
  record "✅ 通过" "登录项读不到时给出明确缺口说明（不臆造、不留白）"
else
  record "⚠️ 人工" "登录项已读到或需人工确认缺口提示"
fi

# ── 2. 跳转 URL：修正锁定 ────────────────────────────────────
head "2 · 系统设置跳转 URL"
check_url() { # check_url 字段 期望子串 描述
  local val field="$1" expect="$2" desc="$3"
  val=$(jval ".links.$field")
  if [[ "$val" == *"$expect"* ]]; then
    record "✅ 通过" "$desc"
  else
    record "❌ 失败" "${desc} (实际：${val})"
  fi
}
check_url fda "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles" "FDA 跳新式隐私扩展页"
check_url loginItems "com.apple.LoginItems-Settings.extension" "登录项跳专用扩展（官方 API 兜底）"
check_url location "Privacy_LocationServices" "定位锚点正确"
check_url calendar "Privacy_Calendars" "日历锚点正确"
check_url appleEvents "Privacy_Automation" "自动化锚点正确"
check_url inputMonitoring "Privacy_ListenEvent" "输入监控锚点正确"

# ── 3. 安全边界：静态审计 ────────────────────────────────────
head "3 · 安全边界（静态审计）"
net_hits=$(grep -rEl 'URLSession|Network\.framework|NWConnection|URLRequest' Sources/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$net_hits" = "0" ]; then
  record "✅ 通过" "源码无网络请求 API（零网络）"
else
  record "❌ 失败" "发现 $net_hits 个文件含网络 API，需复核"
fi
write_hits=$(grep -rEl 'openSystemSettings|XCTest|disable|removeItem|trashItem|FileManager.*create' Sources/SnowSweepCore/PermissionInspector.swift Sources/SnowSweepCore/StartupInspector.swift 2>/dev/null | wc -l | tr -d ' ')
if [ "$write_hits" = "0" ]; then
  record "✅ 通过" "两个 Inspector 无写操作/无删除 API（只读）"
else
  record "⚠️ 人工" "Inspector 命中写相关关键字 $write_hits 处，需复核"
fi
# 只匹配真正会改动系统的 API（.disabled 是 SwiftUI 置灰、注释里的"禁用"是说明，都要排除）
disable_hits=$(grep -rEl 'removeLoginItem|SMAppService.*unregister|unregister.*LoginItem|kill\(|terminate\(|TCC.*delete|DELETE FROM access' Sources/SnowSweepApp/ Sources/SnowSweepCore/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$disable_hits" = "0" ]; then
  record "✅ 通过" "源码无注销登录项/改授权/终止进程等写操作 API"
else
  record "❌ 失败" "命中 $disable_hits 个文件含系统改动 API，需复核"
fi

# ── 4. FDA 授权引导（交互模式） ──────────────────────────────
head "4 · 完全磁盘访问权限（FDA）"
fda_ok=0
if /usr/bin/sqlite3 -readonly "$SYS_TCC" "SELECT count(*) FROM access;" >/dev/null 2>&1; then
  fda_ok=1
  record "✅ 通过" "当前已具备 FDA，TCC 数据库可读"
else
  record "⚠️ 人工" "当前无 FDA，权限项读数需授权后可见"
  if [ "$AUTO" = "0" ]; then
    echo ""
    echo "  ${YEL}即将打开「系统设置 › 隐私与安全性 › 完全磁盘访问权限」${RST}"
    echo "  请在列表中找到 SnowSweepApp：打开开关 → 如提示重启请点『稍后重启』"
    open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles" 2>/dev/null || true
    echo ""
    read -r -p "  授权完成后回到此终端按【回车】继续检测… " _
    if /usr/bin/sqlite3 -readonly "$SYS_TCC" "SELECT count(*) FROM access;" >/dev/null 2>&1; then
      fda_ok=1
      record "✅ 通过" "FDA 已生效，TCC 数据库现在可读"
    else
      record "⚠️ 人工" "仍读不到 TCC（可能需重启 App 或确认勾选的是正确的可执行文件）"
    fi
  fi
fi

# ── 5. 人工目视确认（交互模式） ──────────────────────────────
head "5 · 人工目视确认（仅交互模式）"
if [ "$AUTO" = "1" ]; then
  record "⚠️ 人工" "自动模式跳过目视项：权限名对照 / 跳转落地页 / 全程观察"
else
  # 每个问题只弹一次，绝不循环。osascript 返回 "button returned:通过" 或 "button returned:不通过"。
  # 用 button returned 前缀精确取值，避免"不通过"包含"通过"导致的模糊匹配陷阱。
  confirm() { # confirm 问题 → 0=通过 1=不通过/取消
    local q="$1" answer btn
    answer=$(osascript -e "display dialog \"$q\" buttons {\"不通过\",\"通过\"} default button \"通过\" with title \"SnowSweep M4 验收\"" 2>/dev/null) || return 1
    btn="${answer##*button returned:}"
    if [ "$btn" = "通过" ]; then
      return 0
    fi
    return 1
  }
  if confirm "打开 App「权限清单」→ 重新读取：中文权限名/程序名是否都与系统设置一致？（无 FDA 时显示红色缺口也算正确）"; then
    record "✅ 通过" "权限清单中文名与系统设置一致（人工目视）"
  else
    record "❌ 失败" "权限清单对照不通过（人工目视）"
  fi
  if confirm "点任一权限的「前往系统设置」、以及启动项的登录项跳转：是否落到具体分类页而非首页？"; then
    record "✅ 通过" "跳转落地页正确（人工目视）"
  else
    record "❌ 失败" "跳转落地页不正确（人工目视）"
  fi
  if confirm "全程是否无网络请求、App 未自动关闭/禁用任何权限或启动项？"; then
    record "✅ 通过" "无网络、无自动改动（人工目视）"
  else
    record "❌ 失败" "观察到异常网络请求或自动改动（人工目视）"
  fi
fi

# ── 6. 生成签核报告 ──────────────────────────────────────────
head "6 · 生成签核报告"
sysver=$(jval '.systemVersion')
machine=$(jval '.machine')
collected=$(jval '.collectedAt')
now=$(date '+%Y-%m-%d %H:%M:%S %Z')
mkdir -p docs
{
  echo "# M4 真机验收 · 签核报告"
  echo ""
  echo "- 签核时间：$now"
  echo "- 系统：${sysver} (${machine})"
  echo "- 采集时间：${collected}"
  echo "- 验收版本：$(./version.sh)"
  echo "- 执行方式：${MODE:-完整交互} · 全程只读、零网络"
  echo ""
  echo "## 逐项结论"
  echo ""
  echo "| 状态 | 项目 |"
  echo "|---|---|"
  printf '%s\n' "${RESULT_LINES[@]}"
  echo ""
  echo "## 汇总"
  echo ""
  echo "- ✅ 通过：$PASS 项"
  echo "- ❌ 失败：$FAIL 项"
  echo "- ⚠️ 人工待确认：$WARN 项"
  echo ""
  if [ "$FAIL" = "0" ] && [ "$WARN" = "0" ]; then
    echo "**结论：M4 全部通过，允许 bump 到 V0.1.0 · 验雪。**"
  elif [ "$FAIL" = "0" ]; then
    echo "**结论：机器可验项全通过；仍有 $WARN 项待人工目视确认，M4 未完全通过，暂不 bump 版本。**"
  else
    echo "**结论：存在 $FAIL 项失败，M4 不通过，需修正后重跑。不 bump 版本。**"
  fi
  echo ""
  echo "## 签核"
  echo ""
  echo "- 签名：____________________  日期：____________"
  echo ""
  echo "> 本报告由 m4-accept.sh 自动生成。失败/人工项需处理后再执行 `./m4-accept.sh` 重验。"
} > "$REPORT"
record "✅ 通过" "签核报告已写入 $REPORT"

echo ""
hr
printf '  %s汇总：✅ %d 通过   ❌ %d 失败   ⚠️ %d 人工待确认%s\n' "$BLD" "$PASS" "$FAIL" "$WARN" "$RST"
hr
echo ""
echo "  报告：$REPORT"
if [ "$AUTO" = "0" ] && [ "$FAIL" = "0" ]; then
  echo "  下一步：确认报告无误后运行 ./version.sh 核对版本，M4 全过方可 bump V0.1.0。"
fi
echo ""
