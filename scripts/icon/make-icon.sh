#!/bin/zsh
# 產生 AppIcon.appiconset 與瀏覽器擴充的 icon。
# 用法：scripts/icon/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

SET=Wunderkammer/Resources/Assets.xcassets/AppIcon.appiconset
# 圖示原稿：scripts/icon/cards-source.png（白底），去背後的主體在 cards-1024.png
MASTER=build/icon-1024.png
mkdir -p build "$SET"
python3 scripts/icon/make-icon.py "$MASTER"

images=""
for s in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((s * scale))
    suffix=""
    if [[ $scale == 2 ]]; then suffix="@2x"; fi
    name="icon_${s}x${s}${suffix}.png"
    sips -z $px $px "$MASTER" --out "$SET/$name" >/dev/null
    images+="{\"filename\":\"$name\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${s}x${s}\"},"
  done
done
echo "{\"images\":[${images%,}],\"info\":{\"author\":\"xcode\",\"version\":1}}" | python3 -m json.tool > "$SET/Contents.json"
sips -z 128 128 "$MASTER" --out extensions/browser/icon-128.png >/dev/null
echo "完成：$SET、extensions/browser/icon-128.png"
