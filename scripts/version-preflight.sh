#!/bin/sh
# 雪版本前磁盘门禁。
#
# 新版本（含补丁）开工前先跑：
#   ./scripts/version-preflight.sh --strict
#
# 默认门槛：
#   - Data 卷可用 < 10 GiB：直接阻断
#   - 10–20 GiB：警告
#   - 项目 > 512 MB 或 .build > 500 MB：警告，建议先跑清理脚本
#   - 当前 `/Applications/雪.app` 安装备份 > 2 份：警告，安装脚本会轮转到 1 份
#   - 雪 / SnowSweep /tmp 测试残留 > 500 MB：警告
#
# --clean 会先调用 cleanup-dev-residue.sh；--strict 有任何警告即非 0。
set -eu
cd "$(dirname "$0")/.."

MIN_FREE_GB=20
BLOCK_FREE_GB=10
STRICT=0
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min-free-gb)
      MIN_FREE_GB="${2:-20}"
      BLOCK_FREE_GB=$((MIN_FREE_GB / 2))
      shift 2
      ;;
    --strict) STRICT=1; shift ;;
    --clean) CLEAN=1; shift ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

if [ "$CLEAN" -eq 1 ]; then
  ./scripts/cleanup-dev-residue.sh
fi

VOLUME="/System/Volumes/Data"
AVAIL_KB="$(df -kP "$VOLUME" | awk 'NR==2 {print $4}')"
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
PROJECT_KB="$(du -sk . | awk '{print $1}')"
BUILD_KB=0
if [ -d .build ]; then BUILD_KB="$(du -sk .build | awk '{print $1}')"; fi

BACKUP_COUNT=0
BACKUP_KB=0
if [ -e "/Applications/雪.app" ]; then
  BACKUP_COUNT="$(ls -1d /Applications/雪.app.backup-* 2>/dev/null | wc -l | tr -d ' ')"
  BACKUP_KB="$(du -ck /Applications/雪.app.backup-* 2>/dev/null | tail -1 | awk '{print $1}')"
fi
LEGACY_APP=0
if [ -e "/Applications/SnowSweep.app" ]; then LEGACY_APP=1; fi

TMP_KB="$(find /private/tmp -maxdepth 1 \( \
  -name 'snowsweep*' -o -name 'SnowSweep*' -o -name 'snowshot' -o -name 'snow-browser-test' \
  -o -name 'xue-*' -o -name 'xue_*' \
  -o -name 'scanprobe' -o -name 'fam' -o -name 'v04*' -o -name 'v05*' -o -name 'v06*' -o -name 'v07*' \
  \) -print0 2>/dev/null | xargs -0 du -ck 2>/dev/null | tail -1 | awk '{print $1}')"
TMP_KB="${TMP_KB:-0}"

WARNINGS=0
warn() { echo "  [警告] $1"; WARNINGS=$((WARNINGS + 1)); }

echo "== 雪版本前磁盘门禁 =="
echo "  磁盘可用: ${AVAIL_GB} GiB"
echo "  项目体积: $((PROJECT_KB / 1024)) MB"
echo "  .build:   $((BUILD_KB / 1024)) MB"
echo "  安装备份: ${BACKUP_COUNT} 份 / $((BACKUP_KB / 1024)) MB"
echo "  旧版残留: $([ "$LEGACY_APP" -eq 1 ] && echo 'SnowSweep.app 在' || echo '无')"
echo "  临时残留: $((TMP_KB / 1024)) MB"
echo

if [ "$AVAIL_GB" -lt "$BLOCK_FREE_GB" ]; then
  echo "  [阻断] 可用空间低于 ${BLOCK_FREE_GB} GiB，先清理再开工。"
  exit 1
elif [ "$AVAIL_GB" -lt "$MIN_FREE_GB" ]; then
  warn "可用空间低于 ${MIN_FREE_GB} GiB。"
fi

if [ "$PROJECT_KB" -gt 524288 ]; then
  warn "项目超过 512 MB，先检查 .build 与测试产物。"
fi
if [ "$BUILD_KB" -gt 512000 ]; then
  warn ".build 超过 500 MB，建议 ./scripts/cleanup-dev-residue.sh。"
fi
if [ "$BACKUP_COUNT" -gt 2 ]; then
  warn "旧安装备份超过 2 份，install-selfuse.sh 会轮转；也可手动清理。"
fi
if [ "$TMP_KB" -gt 512000 ]; then
  warn "雪 / SnowSweep 临时残留超过 500 MB，建议清理。"
fi

if [ "$WARNINGS" -eq 0 ]; then
  echo "结果：通过，可以进入下一版本。"
  exit 0
fi

echo "结果：${WARNINGS} 项警告。"
if [ "$STRICT" -eq 1 ]; then exit 1; fi
echo "可运行 ./scripts/cleanup-dev-residue.sh 清理后再复检。"
