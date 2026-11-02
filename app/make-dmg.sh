#!/usr/bin/env bash
# 打包 DMG：打开后把 FolderSync 拖进"应用程序"，再从"应用程序"打开即可完成安装。
#   ./app/make-dmg.sh   → app/build/FolderSync-<版本>.dmg
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
UNIVERSAL=1 "$DIR/build.sh"
APP="$DIR/build/FolderSync.app"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$DIR/build/dmg-stage"
OUT="$DIR/build/FolderSync-$VER.dmg"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/FolderSync.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "FolderSync $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$STAGE"
echo "已生成: $OUT"
