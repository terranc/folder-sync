#!/usr/bin/env bash
# 打包 DMG：打开后把 FolderSync 拖进"应用程序"，再从"应用程序"打开即可完成安装。
#   ./app/make-dmg.sh   → app/build/FolderSync-<版本>.dmg
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
UNIVERSAL=1 "$DIR/build.sh"
APP="$DIR/build/FolderSync.app"
# FS_VERSION：发布时用 tag 覆盖应用版本号（不写则沿用 Info.plist）
# 只覆盖 CFBundleShortVersionString；CFBundleVersion（build）保留 Info.plist 里的递增整数，
# 更新检查只比较版本号，build 仅作展示。
if [ -n "${FS_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $FS_VERSION" "$APP/Contents/Info.plist"
  # 改过 Info.plist 后重新做 ad-hoc 签名，避免签名与包内容不一致
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
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
