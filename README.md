# Wunderkammer

macOS 原生的視覺靈感圖庫。目標手感參考 Atlas for Mac：數千張圖也能流暢捲動與縮放，排版自動完成。

## 目前功能（v0.2）

三種顯示方式，用 toolbar 或 ⌘1、⌘2、⌘3 切換：

- **Grid**：justified 排版。縮放（雙指捏合、⌘ + 滾輪、⌘= 或 ⌘-）時，每張圖會從舊位置飛到新位置
- **Canvas**：由多個「堆」組成，每一堆裡的圖自動排緊。框選幾張圖拖出去，就會在放開的位置成為新的一堆；原本那堆會自動補位；放在別堆上面就合併進去。堆和堆重疊時會自動推開。右鍵選單有「整理成整齊的排列」
- **Infinity**：圖庫排成一面沒有邊界的牆，往任何方向都能一直拖。可以拖曳、甩動或捲動；閒置 2.5 秒後會開始慢慢漂移，按空白鍵暫停

共通操作：

- **選取**：點選、⌘ 點選、⇧ 點選，或在空白處拖曳框選；⌘A 全選
- **預覽**：雙擊或按空白鍵，圖片從原位飛出放大；方向鍵切換，Esc 關閉
- **Board**：在側欄管理（＋ 新增、雙擊改名、右鍵刪除）。把圖拖到側欄的 board 名稱上，或用右鍵選單「加入 board」
- **刪除**：在 board 裡按 ⌫，會從 board 移除；在「全部圖片」按 ⌫，確認後原始檔會移到垃圾桶
- **匯入**：拖入圖片或資料夾、⌘V 貼上、⌘O 開啟、「檔案 → 從 Atlas 匯入」。在 board 裡匯入的圖會直接加進那個 board

## 架構

| 檔案 | 用途 |
|---|---|
| `JustifiedLayout.swift`、`CanvasLayout.swift` | 排版演算法（純函式，有測試） |
| `TilePool.swift` | 三種顯示方式共用的 CALayer tile 管理：只建立畫面附近的 tile，並依顯示大小載入對應的解析度 |
| `GridView.swift`、`CanvasView.swift`、`InfinityView.swift` | 三種顯示方式 |
| `Thumbnailer.swift` | 背景解碼，分 600、1200、2400 三級並快取；每個請求可以單獨取消 |
| `Library.swift` | `~/Library/Application Support/Wunderkammer/`：`library.json`（圖片、board、canvas 的堆）、`originals/`、`thumbnails/` |
| `SelfTest.swift` | 端對端自我測試（見下方） |

## 建置

```bash
./Scripts/build-app.sh   # 產出 build/Wunderkammer.app
swift test               # 排版與選取的單元測試
```

端對端自我測試會用圖庫的複本實際操作三種顯示方式，不會動到真正的圖庫和滑鼠：

```bash
cp -R ~/Library/Application\ Support/Wunderkammer /tmp/wk-lib
WK_SELFTEST=/tmp/wk-shots WK_LIBRARY_ROOT=/tmp/wk-lib .build/debug/Wunderkammer
# 印出 PASS／FAIL，截圖存在 /tmp/wk-shots
```

## 待做

tag、搜尋、相似圖（Vision feature print）、MCP、復原（⌘Z）。
