#!/bin/zsh
# 端對端自我測試：用圖庫的複本實際操作 app，不會動到真正的圖庫和滑鼠。
# 用法：scripts/selftest.sh [只跑的項目]   截圖與紀錄在 build/selftest/
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/selftest
rm -rf "$OUT" && mkdir -p "$OUT/shots"
cp -R "$HOME/Library/Application Support/Wunderkammer" "$OUT/library"
# 從乾淨的 board 與 canvas 狀態開始
python3 - "$OUT/library/library.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["collections"] = []; d["canvases"] = {}
json.dump(d, open(p, "w"))
PY

xcodebuild -project Wunderkammer.xcodeproj -scheme Wunderkammer -configuration Debug \
  -derivedDataPath build build | grep -E "error:|BUILD FAILED" || true
APP=build/Build/Products/Debug/Wunder.app/Contents/MacOS/Wunder

WK_APPEARANCE="${WK_APPEARANCE:-}" WK_SELFTEST_ONLY="${1:-}" WK_SELFTEST="$OUT/shots" WK_LIBRARY_ROOT="$OUT/library" "$APP" -AppleLanguages "(\"${WK_LANG:-zh-Hant}\")" > "$OUT/log" 2>&1 &
PID=$!
for _ in {1..${WK_SELFTEST_TIMEOUT:-120}}; do
  sleep 1
  kill -0 $PID 2>/dev/null || break
done
kill $PID 2>/dev/null || true
grep -E "PASS|FAIL|SKIP|SELFTEST" "$OUT/log"
grep -q "SELFTEST OK" "$OUT/log"
