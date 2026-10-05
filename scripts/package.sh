#!/bin/zsh
# 打包公開下載版：ad-hoc 簽章（未公證）、Intel 與 Apple 晶片通用，輸出 zip 與 SHA-256。
# ad-hoc 簽章下分享延伸功能拿不到共用資料夾，所以不放進下載版；有 Developer ID 後再加回來。
# 用法：scripts/package.sh   輸出：dist/Wunder.zip（Release 用固定檔名，網站的下載連結才不用跟著改）
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Wunderkammer.xcodeproj -scheme Wunderkammer -configuration Release \
  -derivedDataPath build-dist CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build | grep -E "error:|BUILD" || true

APP=build-dist/Build/Products/Release/Wunder.app
[[ -d "$APP" ]] || { echo "建置失敗：找不到 $APP" >&2; exit 1; }
VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)

OUT=dist/package
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$APP" "$OUT/"
rm -rf "$OUT/Wunder.app/Contents/PlugIns"
codesign --force --sign - --options runtime --entitlements Wunderkammer/Wunderkammer.entitlements "$OUT/Wunder.app"
codesign --verify --strict "$OUT/Wunder.app"

ZIP="dist/Wunder.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$OUT/Wunder.app" "$ZIP"
(cd dist && shasum -a 256 Wunder.zip | tee Wunder.zip.sha256)
du -h "$ZIP"
