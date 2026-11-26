#!/bin/sh
# 把旧 SnowSweep 的本地模型权重复制到雪的数据目录。
#
# 只复制、不移动、不删除旧目录；目标已存在且字节一致时跳过。
# 默认只搬 models/ 下的普通文件，不碰规则、审计、日常记录等用户数据。
#
# 用法：
#   ./scripts/migrate-models-to-xue.sh
#   ./scripts/migrate-models-to-xue.sh --verify
#
# 可用环境变量覆盖路径：
#   SNOWSWEEP_LEGACY_SUPPORT  旧数据目录
#   XUE_SUPPORT               新数据目录
set -eu

OLD_ROOT="${SNOWSWEEP_LEGACY_SUPPORT:-$HOME/Library/Application Support/SnowSweep}"
NEW_ROOT="${XUE_SUPPORT:-$HOME/Library/Application Support/雪}"
SRC="$OLD_ROOT/models"
DST="$NEW_ROOT/models"
VERIFY_ONLY=0
[ "${1:-}" = "--verify" ] && VERIFY_ONLY=1

fail() {
  echo "  [失败] $1" >&2
  exit 1
}

[ -d "$SRC" ] || fail "没有找到旧模型目录：$SRC"
[ -d "$NEW_ROOT" ] || fail "没有找到雪数据目录：$NEW_ROOT"

echo "== 旧模型 → 雪 =="
echo "  来源: $SRC"
echo "  目标: $DST"

if [ "$VERIFY_ONLY" -eq 1 ]; then
  [ -d "$DST" ] || fail "目标模型目录不存在：$DST"
else
  mkdir -p "$DST"
fi

count=0
copied=0
skipped=0
failed=0
for source in "$SRC"/*; do
  [ -f "$source" ] || continue
  count=$((count + 1))
  name="$(basename "$source")"
  target="$DST/$name"

  if [ "$VERIFY_ONLY" -eq 0 ] && [ ! -e "$target" ]; then
    tmp="$DST/.${name}.migrate-$$"
    if cp -c "$source" "$tmp" 2>/dev/null; then
      mv "$tmp" "$target"
      echo "  [复制] $name（APFS 克隆）"
      copied=$((copied + 1))
    else
      rm -f "$tmp"
      if cp -p "$source" "$tmp"; then
        mv "$tmp" "$target"
        echo "  [复制] $name（普通复制）"
        copied=$((copied + 1))
      else
        rm -f "$tmp"
        echo "  [失败] $name 复制失败"
        failed=$((failed + 1))
        continue
      fi
    fi
  elif [ -e "$target" ]; then
    skipped=$((skipped + 1))
  else
    failed=$((failed + 1))
    continue
  fi

  if cmp -s "$source" "$target"; then
    echo "  [校验] $name 字节一致"
  else
    echo "  [失败] $name 与旧文件不一致"
    failed=$((failed + 1))
  fi
done

echo
echo "结果：扫描 ${count} 个，复制 ${copied} 个，已存在 ${skipped} 个，失败 ${failed} 个。"
echo "旧模型目录未移动、未删除。"
[ "$failed" -eq 0 ] || exit 1
