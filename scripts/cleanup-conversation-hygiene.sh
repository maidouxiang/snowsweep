#!/bin/sh
# 每次对话收尾的卫生清理。
#
# 规则：
#   - 截图按版本/对话分组，只保留最近 6 组；
#   - 更早的截图移到废纸篓，不永久删除；
#   - 不清空废纸篓；
#   - 不碰用户桌面、照片库和个人文件；
#   - 保留 .build，避免下次重编；当前 `雪.app` 的旧安装备份只留 1 份；旧 SnowSweep 回退副本不轮转；
#   - 清 /private/tmp 下雪与旧 SnowSweep 测试残留。
#
# 用法：
#   ./scripts/cleanup-conversation-hygiene.sh --dry-run
#   ./scripts/cleanup-conversation-hygiene.sh
set -eu
cd "$(dirname "$0")/.."

KEEP=6
DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; fi

TRASH_ROOT="$HOME/.Trash/雪-conversation-hygiene-$(date +%Y%m%d-%H%M%S)"

python3 - "$KEEP" "$DRY" "$TRASH_ROOT" <<'PY'
import os
import re
import shutil
import sys
from pathlib import Path

keep_n = int(sys.argv[1])
dry = sys.argv[2] == "1"
trash_root = Path(sys.argv[3])

roots = [Path("docs/images"), Path("docs/验收截图")]
version_re = re.compile(r"V?(\d+\.\d+\.\d+)")

files = []
for root in roots:
    if not root.is_dir():
        continue
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg"}:
            match = version_re.search(path.name)
            group = match.group(1) if match else "未标注"
            files.append((group, path, path.stat().st_mtime))

groups = {}
for group, path, mtime in files:
    groups.setdefault(group, {"latest": mtime, "files": []})
    groups[group]["latest"] = max(groups[group]["latest"], mtime)
    groups[group]["files"].append(path)

ordered = sorted(groups.items(), key=lambda kv: kv[1]["latest"], reverse=True)
keep = ordered[:keep_n]
drop = ordered[keep_n:]

print(f"截图分组 {len(ordered)} 个，保留最近 {keep_n} 组：")
for group, info in keep:
    print(f"  保留 V{group}" if group != "未标注" else "  保留 未标注")

if not drop:
    print("没有需要清理的旧截图。")
    raise SystemExit(0)

print(f"准备移入废纸篓：{sum(len(i['files']) for _, i in drop)} 张，来自 {len(drop)} 个旧分组。")
if dry:
    for group, info in drop:
        print(f"  [dry-run] V{group} / {len(info['files'])} 张")
    raise SystemExit(0)

trash_root.mkdir(parents=True, exist_ok=True)
moved = 0
for group, info in drop:
    for path in info["files"]:
        target = trash_root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(target))
        moved += 1
print(f"已移入废纸篓 {moved} 张：{trash_root}")
PY

if [ "$DRY" -eq 0 ]; then
  echo
  echo "== 其他临时残留 =="
  ./scripts/cleanup-dev-residue.sh --keep-build
fi
