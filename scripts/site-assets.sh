#!/bin/zsh
# 把 showcase 截圖（build/shots/<en|zh>-<light|dark>，見 scripts/selftest.sh showcase）轉成網站用的 JPEG，並放上 App 圖示。
# 用法：scripts/site-assets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=site/assets
mkdir -p "$OUT"
rm -f "$OUT"/*.jpg
for lang in en zh; do
  prefix=$([[ $lang == zh ]] && echo "zh-" || echo "")
  for look in light dark; do
    for name in collection inspector wander workbench; do
      shot=(build/shots/$lang-$look/showcase-*-$name.png)
      [[ -f "$shot" ]] || continue
      sips -s format jpeg -s formatOptions 78 -Z 1800 "$shot" --out "$OUT/$prefix$name-$look.jpg" >/dev/null
    done
  done
done
ICON=Wunderkammer/Resources/Assets.xcassets/AppIcon.appiconset
cp "$ICON/icon_256x256@2x.png" "$OUT/icon.png"
cp "$ICON/icon_32x32@2x.png" "$OUT/favicon.png"
# 分享預覽圖：收藏畫面裁成 1200×630
sips -Z 1200 "build/shots/en-light/showcase-1-collection.png" --out /tmp/wunder-og.png >/dev/null
sips -c 630 1200 /tmp/wunder-og.png --out "$OUT/og.png" >/dev/null
du -sh "$OUT"
