#!/bin/sh
# 打包公开发布用的 macOS 安装包（供 GitHub Actions 与本地手动发版共用）。
#
# 做的事：
#   1. 复用 install-selfuse.sh 的 release 构建与 .app 组装，但装到临时目录而不是 /Applications；
#   2. 用 ad-hoc 签名（CI 没有开发者证书）；
#   3. 清除二进制里编进去的打包机绝对路径（#filePath 常量），再重新签名；
#   4. 打成 zip，并生成同名 SHA256 校验文件。
#
# 用法：
#   ./scripts/package-macos.sh [输出目录，默认 dist]
#
# 产物：dist/snowsweep-macos-v<版本>.zip 与 dist/SHA256SUMS-v<版本>.txt
set -eu
cd "$(dirname "$0")/.."

OUT="${1:-dist}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/xue-package.XXXXXX")"
APP="$WORK/雪.app"
trap 'rm -rf "$WORK"' EXIT

echo "== 1/4 构建并组装到 $APP =="
LOG="$WORK/build.log"
if ! SNOWSWEEP_INSTALL_PATH="$APP" SNOWSWEEP_SIGN_IDENTITY= ./install-selfuse.sh >"$LOG" 2>&1; then
  echo "构建失败，最后 80 行日志："
  tail -80 "$LOG"
  exit 1
fi

echo "== 2/4 清除打包机绝对路径 =="
python3 scripts/strip-local-paths.py "$APP" || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

VERSION="$(./version.sh | sed 's/ · .*//' | sed 's/^V//')"
NAME="snowsweep-macos-v${VERSION}.zip"

echo "== 3/4 打包 $NAME =="
mkdir -p "$OUT"
rm -f "$OUT/$NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME"

echo "== 4/4 生成校验值 =="
( cd "$OUT" && shasum -a 256 "$NAME" > "SHA256SUMS-v${VERSION}.txt" )

echo "完成：$OUT/$NAME"
cat "$OUT/SHA256SUMS-v${VERSION}.txt"
