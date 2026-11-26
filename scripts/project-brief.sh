#!/bin/sh
# 雪 · 项目简报
#
# 一条命令给出下一轮开工所需的最小事实集：版本、安装态、规模、最近改动、
# 最近验证和先读文档。目的是替代“全量扫项目 + 逐个打开文档 + 重复截图”。
#
# 用法：
#   ./scripts/project-brief.sh          # 打印到终端
#   ./scripts/project-brief.sh --write  # 同时写入 docs/项目当前状态.md 的生成区
#
# 只读：不改源码、不跑测试、不安装。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP="/Applications/雪.app"
VERSION_FILE="Sources/SnowSweepCore/AppVersion.swift"

number=$(sed -n 's/.*number: "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -n 1)
codename=$(sed -n 's/.*codeName: "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -n 1)
stage=$(sed -n 's/.*stage: "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -n 1)
devtag=$(sed -n 's/.*devTag: "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -n 1)

installed="未安装"
if [ -f "$APP/Contents/Info.plist" ]; then
  installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "读取失败")
fi

pid=$(pgrep -x SnowSweepApp 2>/dev/null | head -n 1 || true)
if [ -n "${pid:-}" ]; then
  app_state="运行中 PID $pid"
else
  app_state="未运行"
fi

backups=$(find /Applications -maxdepth 1 -name '雪.app.backup-*' 2>/dev/null | wc -l | tr -d ' ')

source_count=$(find Sources -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
test_file_count=$(find Tests -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
test_func_count=$(grep -rho '@Test' Tests 2>/dev/null | wc -l | tr -d ' ')
doc_count=$(find docs -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
build_size=$(du -sh .build 2>/dev/null | awk '{print $1}')
[ -n "${build_size:-}" ] || build_size="无 .build"
disk_avail=$(df -h . | awk 'NR==2 {print $4}')

recent=$(find Sources Tests scripts docs -type f -mtime -2 \
  ! -path 'docs/images/*' ! -path 'docs/samples/*' ! -name '*.png' 2>/dev/null \
  | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f '%m' "$f" 2>/dev/null || echo 0)" "$f"; done \
  | sort -rn | head -n 10 | cut -f2-)

latest_log() {
  # 传入 glob；返回最新的一个文件
  ls -t $1 2>/dev/null | head -n 1 || true
}

test_log=$(latest_log '/tmp/xue-*-test*.log')
ci_log=$(latest_log '/tmp/xue-*-ci*.log')
install_log=$(latest_log '/tmp/xue-install-*.log')

test_summary="无（本轮未跑或 /tmp 已清）"
if [ -n "${test_log:-}" ]; then
  test_summary=$(grep -E 'Test run with|error:' "$test_log" 2>/dev/null | tail -n 2 | tr '\n' ' ' | sed 's/  */ /g')
  [ -n "$test_summary" ] || test_summary="有日志但未识别到汇总"
fi

ci_summary="无（本轮未跑或 /tmp 已清）"
if [ -n "${ci_log:-}" ]; then
  ci_summary=$(grep -E 'Test run with|全部通过|error:|warning:' "$ci_log" 2>/dev/null | tail -n 2 | tr '\n' ' ' | sed 's/  */ /g')
  [ -n "$ci_summary" ] || ci_summary="有日志但未识别到汇总"
fi

install_summary="无"
if [ -n "${install_log:-}" ]; then
  install_summary=$(grep -E '安装完成|版本:|SIG_OK|error:' "$install_log" 2>/dev/null | head -n 3 | tr '\n' ' ' | sed 's/  */ /g')
  [ -n "$install_summary" ] || install_summary="有日志但未识别到汇总"
fi

version_line="V$number · $codename"
if [ -n "${devtag:-}" ]; then
  version_line="$version_line（${devtag}）"
fi

cat <<EOF
# 雪 · 项目简报

生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
项目根:   $ROOT

## 身份
$version_line
阶段: $stage
已安装: ${installed}（${app_state}）
安装备份: $backups 份

## 规模
Swift 源文件: $source_count
测试文件: ${test_file_count}（@Test 标记 ${test_func_count}）
md 文档: $doc_count
.build: $build_size
磁盘可用: $disk_avail

## 最近改动（2 天内，已排除截图）
${recent:-无}

## 最近验证
test: $test_summary
日志: ${test_log:-无}
ci: $ci_summary
日志: ${ci_log:-无}
install: $install_summary
日志: ${install_log:-无}

## 先读这些（按顺序，够了就停）
1. docs/项目交接与阅读地图.md            # 10/30 分钟上手，源码地图与任务路由
2. docs/项目当前状态.md                  # 上轮交接与未决项
3. docs/雪_V1.0_主动维护Agent决策锁定_v3_2026-11-27.md  # 当前执行口径：D1–D26 已锁定
4. docs/雪_V1.0_主动维护Agent重构规划_2026-11-26.md  # 技术架构细节：ToolProxy/事件溯源/空间树/模型层
5. docs/雪_项目总流程与省时运行手册_V0.9.30.md  # 全项目流程
6. docs/雪_降本增效作业流程_V0.9.30.md   # 单轮闭环与截图门槛
7. 只读任务涉及的具体源码/文档，不读全部 docs 全集
8. 需要架构时才读 docs/技术文档.md 的对应章节
9. 需要安全边界时才读 docs/安全边界与规则库.md

## 常用入口
版本:   ./version.sh
测试:   ./test.sh
门禁:   ./ci-check.sh
安装:   ./install-selfuse.sh
构建:   ./build.sh
磁盘门禁: ./scripts/version-preflight.sh --strict
安装核对: /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/雪.app/Contents/Info.plist
EOF

if [ "${1:-}" = "--write" ]; then
  out="docs/项目当前状态.md"
  snap=$(mktemp /tmp/xue-project-brief.XXXXXX)
  "$0" > "$snap"

  if [ ! -f "$out" ]; then
    {
      echo "# 雪 · 项目当前状态"
      echo
      echo "> 本文件的「自动快照」由 \`./scripts/project-brief.sh --write\` 覆盖；"
      echo "> 「上轮交接」由每次任务结束时手工更新，保持 ≤12 行。"
      echo
      echo "## 自动快照"
      echo "<!-- AUTO:BEGIN -->"
      cat "$snap"
      echo "<!-- AUTO:END -->"
      echo
      echo "## 上轮交接"
      echo
      echo "<!-- 每次任务结束替换本节：版本 / 做了什么 / 验证 / 未决 / 下轮入口 -->"
    } > "$out"
  else
    awk -v snap="$snap" '
      /<!-- AUTO:BEGIN -->/ {
        print
        while ((getline line < snap) > 0) print line
        close(snap)
        skip=1
        next
      }
      /<!-- AUTO:END -->/ { skip=0 }
      !skip { print }
    ' "$out" > "$out.new"
    mv "$out.new" "$out"
  fi

  rm -f "$snap"
  printf '已更新 %s（上轮交接保留）\n' "$out"
fi
