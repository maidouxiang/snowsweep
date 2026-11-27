#!/bin/sh
# 雪自用安装脚本：把 release 构建打包成真正的 .app 装到本机。
#
# 这是「自用、先不发最终版本」阶段：App 版本号停在 V0.9.x，
# 默认用本机固定自签名证书签名（跨版本保留 TCC 授权），
# 证书不可用时回退 ad-hoc；不公证、不上架、零网络。
#
# 做三件事：
#   1. release 构建 App + 浸泡压测程序；
#   2. 组装 雪.app（可执行文件 + 规则 + 中文词典 bundle + Info.plist），
#      用固定自签名身份签名后安装到 /Applications；
#   3. 把浸泡压测工具与一键脚本放到 ~/Library/Application Support/雪/。
#
# 固定签名身份：
#   SNOWSWEEP_SIGN_IDENTITY  默认 "SnowSweep Local Code Signing"
#   SNOWSWEEP_SIGN_KEYCHAIN  默认 ~/Library/Keychains/xue-signing.keychain-db
#   想临时回 ad-hoc：SNOWSWEEP_SIGN_IDENTITY= 后再运行。
#
# 幂等：重复运行会覆盖旧的 雪.app（先备份再替换），不碰旧的 SnowSweep.app。
# 备份轮转：默认不保留旧安装，避免 /Applications 堆积备份；需要时显式设置 KEEP=1。
# 默认不保留安装备份；确需临时回退时用 SNOWSWEEP_BACKUP_KEEP=1 ./install-selfuse.sh。
set -eu
cd "$(dirname "$0")"

# 版本前磁盘门禁：可用空间低于 10 GiB 时直接阻断，避免构建/安装把系统盘吃满。
./scripts/version-preflight.sh --min-free-gb 10

APP_NAME="雪"
BUNDLE_ID="com.selfuse.xue"
INSTALLED="${SNOWSWEEP_INSTALL_PATH:-/Applications/${APP_NAME}.app}"
BUILD_DIR=".build/release"
STAGE=".build/selfuse-stage/${APP_NAME}.app"
TOOLS_DIR="$HOME/Library/Application Support/雪"

echo "== 1/3 release 构建 =="
swift build --disable-sandbox -c release --product SnowSweepApp -Xswiftc -gnone -debug-info-format none
swift build --disable-sandbox -c release --product SoakTest -Xswiftc -gnone -debug-info-format none
swift build --disable-sandbox -c release --product ScannerService -Xswiftc -gnone -debug-info-format none
swift build --disable-sandbox -c release --product ModelHost -Xswiftc -gnone -debug-info-format none

echo
echo "== 2/3 组装 ${APP_NAME}.app =="
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/Rules" \
  "$STAGE/Contents/Helpers" \
  "$STAGE/Contents/XPCServices/ScannerService.xpc/Contents/MacOS" \
  "$STAGE/Contents/XPCServices/ModelHost.xpc/Contents/MacOS"

cp "$BUILD_DIR/SnowSweepApp" "$STAGE/Contents/MacOS/SnowSweepApp"
chmod +x "$STAGE/Contents/MacOS/SnowSweepApp"

# XPC 服务：扫描器与模型宿主各自独立进程；规则库由主 App 随请求传入。
cp "$BUILD_DIR/ScannerService" "$STAGE/Contents/XPCServices/ScannerService.xpc/Contents/MacOS/ScannerService"
cp Packaging/ScannerService-Info.plist "$STAGE/Contents/XPCServices/ScannerService.xpc/Contents/Info.plist"
chmod +x "$STAGE/Contents/XPCServices/ScannerService.xpc/Contents/MacOS/ScannerService"

cp "$BUILD_DIR/ModelHost" "$STAGE/Contents/XPCServices/ModelHost.xpc/Contents/MacOS/ModelHost"
cp Packaging/ModelHost-Info.plist "$STAGE/Contents/XPCServices/ModelHost.xpc/Contents/Info.plist"
chmod +x "$STAGE/Contents/XPCServices/ModelHost.xpc/Contents/MacOS/ModelHost"

# 自签名证书无法通过 macOS 27 对 .xpc 服务的 AMFI 校验；
# 同时放一份 Helper，App 用 stdin/stdout 行协议拉起，扫描与模型照样在独立进程。
cp "$BUILD_DIR/ScannerService" "$STAGE/Contents/Helpers/ScannerService"
cp "$BUILD_DIR/ModelHost" "$STAGE/Contents/Helpers/ModelHost"
chmod +x "$STAGE/Contents/Helpers/ScannerService" "$STAGE/Contents/Helpers/ModelHost"

VERSION="$(./version.sh | sed 's/ · .*//' | sed 's/^V//')"

# 完全磁盘访问按“App 身份”授权。裸 helper 即使手动加入 FDA 也不会生效，
# 因此扫描器再包一层最小 .app；App 仍用 stdin/stdout 行协议直接拉起。
HELPER_SCANNER_APP="$STAGE/Contents/Helpers/ScannerService.app"
mkdir -p "$HELPER_SCANNER_APP/Contents/MacOS"
cp "$BUILD_DIR/ScannerService" "$HELPER_SCANNER_APP/Contents/MacOS/ScannerService"
chmod +x "$HELPER_SCANNER_APP/Contents/MacOS/ScannerService"
cat > "$HELPER_SCANNER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ScannerService</string>
  <key>CFBundleDisplayName</key><string>雪 扫描服务</string>
  <key>CFBundleIdentifier</key><string>com.selfuse.xue.ScannerService</string>
  <key>CFBundleExecutable</key><string>ScannerService</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 规则库与中文词典：安装后从 Bundle.main 读取，不依赖源码目录。
cp Rules/rules.json "$STAGE/Contents/Resources/Rules/rules.json"
# 雪花应用图标（与菜单栏同一符号，scripts/make-icon.swift 可复现）。
if [ -f Assets/AppIcon.icns ]; then
  cp Assets/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
fi
cp Rules/glossary.json "$STAGE/Contents/Resources/Rules/glossary.json"
cp Rules/software-families.json "$STAGE/Contents/Resources/Rules/software-families.json"

# SnowSweepCore 的 SwiftPM 资源 bundle（glossary 的第二来源）。
if [ -d "$BUILD_DIR/SnowSweepCore_SnowSweepCore.bundle" ]; then
  cp -R "$BUILD_DIR/SnowSweepCore_SnowSweepCore.bundle" "$STAGE/Contents/Resources/"
fi

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>雪</string>
  <key>CFBundleDisplayName</key><string>雪</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundleExecutable</key><string>SnowSweepApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>雪只读取桌面目录与文件体积，用于空间分析。</string>
  <key>NSDocumentsFolderUsageDescription</key><string>雪只读取文稿目录与文件体积，用于空间分析。</string>
  <key>NSDownloadsFolderUsageDescription</key><string>雪只读取下载目录与文件体积，用于空间分析。</string>
  <key>NSRemovableVolumesUsageDescription</key><string>雪只读取外置硬盘的目录与文件体积，不修改、不删除任何文件。</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict>
</plist>
PLIST

# 签名：优先用本机固定自签名证书，保证重装后 TCC 授权仍认同一身份；
# 证书不可用时才回退 ad-hoc（ad-hoc 每次构建 DR 都变，权限会丢）。
SIGN_IDENTITY="${SNOWSWEEP_SIGN_IDENTITY-SnowSweep Local Code Signing}"
SIGN_KEYCHAIN="${SNOWSWEEP_SIGN_KEYCHAIN-$HOME/Library/Keychains/xue-signing.keychain-db}"
SIGN_PASSWORD="${SNOWSWEEP_SIGN_PASSWORD-snowsweep}"
if [ -n "$SIGN_IDENTITY" ] && security find-certificate -c "$SIGN_IDENTITY" "$SIGN_KEYCHAIN" >/dev/null 2>&1; then
  security unlock-keychain -p "$SIGN_PASSWORD" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
  codesign --force --deep --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" "$STAGE"
  SIGN_MODE="固定自签名（${SIGN_IDENTITY}）"
else
  codesign --force --deep --sign - "$STAGE"
  SIGN_MODE="ad-hoc（临时）"
fi

echo "  安装到 $INSTALLED"
if [ -e "$INSTALLED" ]; then
  BACKUP="${INSTALLED}.backup-$(date +%Y%m%d-%H%M%S)"
  echo "  已存在旧版，备份到 $BACKUP"
  mv "$INSTALLED" "$BACKUP"
fi
cp -R "$STAGE" "$INSTALLED"

# 默认不保留备份（N=0）；安装脚本只清理自己生成的 *.backup-*。
prune_backups() {
  keep="${SNOWSWEEP_BACKUP_KEEP:-0}"
  count="$(ls -1d "$INSTALLED".backup-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -gt "$keep" ] || return 0
  remove_count=$((count - keep))
  ls -1d "$INSTALLED".backup-* 2>/dev/null | sort | head -n "$remove_count" | while IFS= read -r old; do
    echo "  清理旧备份 $old"
    rm -rf "$old"
  done
}
prune_backups

echo
echo "== 3/3 安装浸泡压测工具到 $TOOLS_DIR =="
mkdir -p "$TOOLS_DIR/Rules"
cp "$BUILD_DIR/SoakTest" "$TOOLS_DIR/SoakTest"
chmod +x "$TOOLS_DIR/SoakTest"
# 安装版：不再 swift build（工具目录没有 Package.swift），直接跑已编译二进制。
cat > "$TOOLS_DIR/soak-test.sh" <<RUNNER
#!/bin/sh
# 雪自用浸泡压测（已安装版，直接运行预编译二进制）。
# 用法：./soak-test.sh [--rounds N] [--interval 秒] [--quick]
set -eu
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\$HERE"
exec "\$HERE/SoakTest" "\$@"
RUNNER
chmod +x "$TOOLS_DIR/soak-test.sh"
# 压测程序从当前目录找 Rules/，随工具一并安装。
cp Rules/rules.json "$TOOLS_DIR/Rules/rules.json"
cp Rules/glossary.json "$TOOLS_DIR/Rules/glossary.json"
cp Rules/software-families.json "$TOOLS_DIR/Rules/software-families.json"

echo
echo "== 安装完成 =="
echo "  App:      $INSTALLED"
echo "  版本:     $(./version.sh)（自用版，$SIGN_MODE 签名）"
echo "  压测工具: $TOOLS_DIR/"
echo
echo '  启动 App：open -a "/Applications/雪.app" 或 open -b com.selfuse.xue（旧 SnowSweep 已删除）'
echo "  跑浸泡：   \"$TOOLS_DIR/soak-test.sh\" --rounds 300"
echo "  提示：规则与词典已随 App 打包，安装后可脱离源码目录运行。"
