#!/usr/bin/env bash
# 构建 FolderSync.app（菜单栏应用）。只需 Xcode Command Line Tools，无需 Xcode。
#   UNIVERSAL=1 ./app/build.sh   同时编译 Apple 芯片与 Intel 版本（打 DMG 时使用）
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
OUT="$DIR/build/FolderSync.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

compile() {   # compile <arch> <输出>
  swiftc -O -swift-version 5 -target "$1-apple-macos13.0" \
    -framework AppKit -framework WebKit -framework SwiftUI \
    -o "$2" "$DIR"/Sources/*.swift
}
if [ "${UNIVERSAL:-0}" = 1 ]; then
  compile arm64 "$DIR/build/FolderSync-arm64"
  compile x86_64 "$DIR/build/FolderSync-x86_64"
  lipo -create -output "$OUT/Contents/MacOS/FolderSync" "$DIR/build/FolderSync-arm64" "$DIR/build/FolderSync-x86_64"
  rm -f "$DIR/build/FolderSync-arm64" "$DIR/build/FolderSync-x86_64"
else
  compile "$(uname -m)" "$OUT/Contents/MacOS/FolderSync"
fi
cp "$DIR/Info.plist" "$OUT/Contents/Info.plist"

# 应用图标：用与菜单栏相同的箭头图形生成 icns
ICONSET="$DIR/build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swiftc -O -swift-version 5 -framework AppKit -o "$DIR/build/make-icon" "$DIR/Sources/Logo.swift" "$DIR/tools/make-icon/main.swift"
"$DIR/build/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

cp -R "$DIR/web" "$OUT/Contents/Resources/web"
# 同步引擎（命令行脚本）随应用一起分发：应用首次打开时安装到 ~/.local/bin 并注册后台守护
cp "$ROOT/folder-sync.sh" "$OUT/Contents/Resources/folder-sync"
chmod +x "$OUT/Contents/Resources/folder-sync"

codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "已构建: $OUT"
