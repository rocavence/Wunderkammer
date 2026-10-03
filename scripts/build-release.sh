#!/bin/zsh
# 建置 Release 版 Wunderkammer.app（本機簽章，未公證）。
# 用法：scripts/build-release.sh   輸出：dist/Wunderkammer.app
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Wunderkammer.xcodeproj -scheme Wunderkammer -configuration Release \
  -derivedDataPath build-release build | grep -E "error:|BUILD" || true

APP=build-release/Build/Products/Release/Wunderkammer.app
[[ -d "$APP" ]] || { echo "建置失敗：找不到 $APP" >&2; exit 1; }
rm -rf dist && mkdir -p dist
cp -R "$APP" dist/
echo "完成：dist/Wunderkammer.app"
