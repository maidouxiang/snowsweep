#!/bin/sh
# 雪开发残留清理：只清可再生的构建缓存、当前安装版的旧备份和本机测试截图。
# 不删源码、不删当前安装版、不删 ~/Library/Application Support/雪 用户数据、不清空废纸篓。
# 旧 /Applications/SnowSweep.app、旧备份与旧数据目录已于 2026-11-26 删除；若检测到残留，不参与本次轮转。
#
# 用法：
#   ./scripts/cleanup-dev-residue.sh
#   ./scripts/cleanup-dev-residue.sh --keep-build
#   ./scripts/cleanup-dev-residue.sh --keep-backup 2
set -eu
cd "$(dirname "$0")/.."

KEEP_BACKUP=1
KEEP_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-build) KEEP_BUILD=1; shift ;;
    --keep-backup)
      KEEP_BACKUP="${2:-1}"
      case "$KEEP_BACKUP" in
        ''|*[!0-9]*) echo "错误：--keep-backup 需要非负整数"; exit 2 ;;
      esac
      shift 2
      ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

INSTALLED="/Applications/雪.app"
LEGACY_INSTALLED="/Applications/SnowSweep.app"
BACKUP_GLOB="${INSTALLED}.backup-*"
PROJECT_DIR="$(pwd)"

echo "== 清理项目构建缓存 =="
if [ "$KEEP_BUILD" -eq 0 ] && [ -d "$PROJECT_DIR/.build" ]; then
  before="$(du -sk "$PROJECT_DIR/.build" | awk '{print $1}')"
  echo "  删除 .build（${before} KB，可重建）"
  rm -rf "$PROJECT_DIR/.build"
else
  echo "  保留 .build"
fi

echo "== 轮转旧安装备份 =="
if [ -e "$INSTALLED" ]; then
  count="$(ls -1d $BACKUP_GLOB 2>/dev/null | wc -l | tr -d ' ')"
  echo "  当前备份 ${count} 份，保留最近 ${KEEP_BACKUP} 份"
  if [ "$count" -gt "$KEEP_BACKUP" ]; then
    remove_count=$((count - KEEP_BACKUP))
    ls -1d $BACKUP_GLOB 2>/dev/null | sort | head -n "$remove_count" | while IFS= read -r old; do
      echo "  删除旧备份 $old"
      rm -rf "$old"
    done
  fi
else
  echo "  当前安装版不存在，跳过备份轮转"
fi
if [ -e "$LEGACY_INSTALLED" ]; then
  legacy_count="$(ls -1d "${LEGACY_INSTALLED}.backup-"* 2>/dev/null | wc -l | tr -d ' ')"
  echo "  检测到旧 SnowSweep 残留（备份 ${legacy_count} 份）；不参与本次轮转，请人工确认是否删除"
fi

echo "== 清理本机测试残留 =="
for pattern in \
  snowsweep-build'*' snowsweep-test'*' snowsweep-ci.'*' snowshot snow-browser-test scanprobe fam \
  SnowSweep-TestHost'*' SnowSweepApp_'*'.sample.txt \
  xue-v09'*' xue_'*'.sample.txt \
  v0[4-7]*_family.json v0[4-7]*_family.log; do
  find /private/tmp -maxdepth 1 -name "$pattern" -print 2>/dev/null | while IFS= read -r old; do
    echo "  删除 $old"
    rm -rf "$old"
  done
done

echo
echo "清理完成。未清空废纸篓；当前 /Applications/雪.app、旧 SnowSweep 回退副本与两套用户数据未动。"
