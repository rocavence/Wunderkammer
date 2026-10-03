# 夜間進度報告（2026-10-04 00:40–）

## 一句話

依照 Product Planning 與 User Stories Roadmap，**Stage 1 的完成定義 11 項全部達成**，Stage 2 在本機做到 OCR、物件與顏色辨識、相似、相關、主題、隨機重新發現、過去的今天與被遺忘的。每項都用 app 本身的端對端自我測試實際操作與截圖驗證；單元測試 56 個、端對端檢查 60 多項全部通過。所有 commit 都只在本機，沒有 push。

## 早上先做這 3 件事（約 5 分鐘）

1. Wunderkammer 已經開著（`dist/Wunderkammer.app`）。你的 30 張迷因已轉成新格式並分析完成。
2. 在 Safari 或 Zen 隨便打開一頁，按 `⌘⇧C`。Safari 會先問「自動化」權限；Zen 要到「系統設定 → 隱私權與安全性 → 輔助使用」打開 Wunderkammer。
3. 在 app 裡按 `R`、`⌘K` 搜尋「receive」（只出現在 Trade Offer 圖裡的字）、搜尋「a cat at a dinner table」（語意搜尋），再右鍵任一張「找相似的」。

截圖在 `docs/screenshots/`。

## 完成項目

### Stage 1 — Foundation

| User Story | 狀態 | 說明 |
|---|---|---|
| US-001 收圖片 | 完成 | 複製圖片後 `⌘⇧C`；保存來源網址 |
| US-002 收網址 | 完成 | 瀏覽器內 `⌘⇧C` 直接收目前分頁；標題、描述、預覽圖、favicon、網域在背景補上 |
| US-003 收文字 | 完成 | 保存文字與來源網頁；畫成文字卡 |
| US-004 拖放檔案 | 完成 | 圖片、影片、聲音、PDF、任何檔案；以參照收藏，不複製 |
| US-005 截圖 | 完成 | `⌃⌘⇧C` |
| US-006 全域快捷鍵 | 完成 | `⌘⇧C`；被佔用時提示改用選單 |
| US-007 瀏覽器擴充 | 完成 | Chrome、Zen、Firefox 共用；另有書籤小程式 |
| US-008 分享 | 完成 | 「分享 → Wunderkammer」，實際用系統分享流程測過 |
| US-009 Cabinet | 完成 | Grid、Masonry、Timeline，外加原本的 Canvas、Infinity |
| US-010 Quick Look | 完成 | `Space`；影音與文件用系統 Quick Look |
| US-011 基本搜尋 | 完成 | `⌘K`；也搜得到圖中文字、物件、顏色、年份 |
| US-012 自動 metadata | 完成 | 標題、網址、網域、尺寸、長度、頁數、檔案類型、建立日期、收藏日期、來源 app |
| US-013 移除與復原 | 完成 | `Delete` 不跳對話框，`⌘Z` 復原 |
| US-014 零整理 | 完成 | 不需要建立任何資料夾或 tag；側欄的 view 都由系統維護 |

另外：服務選單（任何 app 右鍵「服務 → 收進 Wunderkammer」）、`wunderkammer://capture` 連結、app icon（Reicon cabinet）、拖到 Dock icon、選單列 icon、Spotlight、設定視窗（自訂快捷鍵）。關掉視窗後 app 繼續在背景收藏。

### Stage 3 — World（先做的部分）

| User Story | 狀態 | 說明 |
|---|---|---|
| US-301 Canvas | 完成 | 原本就有；現在每個 view（類型、主題、board）都有自己的 canvas |
| US-303 Spatial Clustering | 部分 | Canvas 右鍵「依主題分堆」，系統分成有名稱的堆 |

### Stage 2 — Intelligence（本機）

| User Story | 狀態 | 說明 |
|---|---|---|
| US-203 OCR | 完成 | Vision 自動偵測語言；PDF 讀文字層 |
| US-202 Visual Search | 完成 | 右鍵「找相似的」 |
| US-205 Related | 完成 | Inspector 的「相關的收藏」：長得像、同網站、同作者、共同主題、提到同樣的名字 |
| US-206 Random | 完成 | `R`，依年紀、沒看多久、看過幾次加權；顯示「你在 N 天前收藏了這個」 |
| US-207 Forgotten Gems | 部分 | 「被遺忘的」：超過一個月沒看的；還沒有「品質」與「近期興趣」 |
| US-208 On This Day | 完成 | 「過去的今天」 |
| US-210 Auto Collections | 部分 | 依物件標籤自動長出「主題」（人物、插畫、動物……） |
| US-204 Entities | 部分 | 英文名字可以；中文沒有命名實體辨識（系統不支援） |
| US-201 Semantic Search | 完成 | 本機 MobileCLIP：用描述找圖，30 張迷因上 9 個描述全部第一名命中；中文描述需系統翻譯語言 |
| US-209 Connections | 部分 | Inspector 的名字與網站可以點開，看所有連到它的收藏 |
| US-211 Questions | 未做 | 需要 Apple 的本機語言模型；這台 Mac 回報 `modelNotReady`（Apple Intelligence 模型未就緒），無法驗證所以沒做 |

### 依你半夜的回饋修正

* Infinity 展開後點空白會穿透開啟下一張：已修正，並加入測試。
* 專案結構照 Flione：xcodegen、`Config/Signing.xcconfig`、Reicon、`docs/DECISIONS.md`、本報告。

## 實測數據

測試環境：這台 Mac、Debug build、`scripts/selftest.sh perf`。

| 項目 | 結果 | 目標 |
|---|---|---|
| 收一段文字 | 6–14 ms | ≤ 1 秒 |
| 收一個網址（卡片立即出現，預覽之後補） | 16–23 ms | ≤ 1 秒 |
| 收一張 3000×2000 圖片 | 18–19 ms | ≤ 1 秒 |
| 收進 3,000 張圖 | 14.4 秒（每張 4.9 ms） | — |
| 捲動 3,000 件 | 每步平均 0.6 ms，最差 4.6 ms | 每幀 < 16 ms |
| 捏合縮放 3,000 件 | 每幀 0.45 ms；放開後重排 3.5 ms | 每幀 < 16 ms |
| 搜尋 3,000 件 | 11 ms | — |
| 記憶體（3,000 件捲完） | 約 900 MB（原本 6.8 GB，已修正） | 有上限 |
| 理解 30 件（OCR＋物件＋顏色＋特徵） | 首次約 12 秒（含載入模型），之後約 1 秒 | 背景執行 |

## 我替你做的決定

完整理由與修改方式在 `docs/DECISIONS.md`。重點：

| # | 決定 | 不同意時 |
|---|---|---|
| D02 | 檔案用參照，不複製進圖庫 | 改 `Representer.file(_:)` |
| D03 | 移除不跳確認，`⌘Z` 復原 | — |
| D04 | 沒有圖的東西畫成紙色、襯線字的卡片 | 改 `CardRenderer.swift` |
| D05 | `⌘⇧C`：60 秒內剛複製的優先，否則收瀏覽器目前分頁 | 改 `CaptureController` |
| D07 | 側欄：珍奇室、系統整理、主題、重新發現，board 放最後 | 改 `SidebarViewController` |
| D09 | 圖片、網頁、短文字用自己的飛出預覽；影音、文件、長文字用 Quick Look | 改 `AppDelegate.openPreview` |
| D11 | 瀏覽器擴充透過 `wunderkammer://`，不開本機伺服器 | — |
| D13 | 分享延伸功能透過 App Group 收件匣 | — |

## 需要你決定的事

1. **語意搜尋的模型要不要隨 app 散布。** 目前模型（106 MB）由 `scripts/models/fetch-mobileclip.sh` 另外安裝，已裝在這台 Mac。要給別人用時，可以內建在 app 裡（app 變大），或第一次使用時詢問後下載。
2. **中文描述搜尋。** 需要系統的「中文（繁體）→ 英文」翻譯語言。到選單「編輯 → 啟用中文描述搜尋…」按「下載」即可；沒下載時只對應已知詞（紅色、椅子、貓…）。
3. **`⌘⇧C` 的衝突。** Chrome 開發者工具和 Finder 也用這組。現在可以在設定（⌘,）自己換；要不要換預設值？
4. **Board 的去留。** 規劃文件說 Folder 不應是必要的；目前 board 保留在側欄最下面，Canvas 依然用得到。要不要完全隱藏，只在 Canvas 裡出現？

## 已知問題

* 中文的人名、地名抓不到（Apple NaturalLanguage 不支援中文命名實體辨識）。
* 被參照的檔案如果被刪除，只剩 representation 可看，無法開原檔。
* 淺色模式已修正預覽背景與日期標題；其他畫面只截圖檢查過 Grid、Timeline、Inspector 與預覽。

## Commit 一覽

都在本機，沒有 push。每個 commit 是一個獨立功能，可以單獨 `git revert`。

```text
c4f3148 預覽與提示的細節
a36285a 提到的名字與自動主題
c735e42 效能：3,000 件的記憶體從 6.8 GB 降到約 900 MB；分享收件匣加強驗證
50b2327 分享延伸功能：在任何 app 的分享選單收進 Wunderkammer
b53fd6e App icon 與瀏覽器擴充
27e7c97 Stage 2：在本機理解收藏（OCR、物件、顏色、相似）
98f9bfa Cabinet：Masonry、Timeline、搜尋、系統 view、Inspector、隨機重新發現
7744743 收藏：⌘⇧C、截圖、服務選單、wunderkammer:// 與剪貼簿
686f762 Curiosity 資料模型與 Representation 引擎
00b6de3 改用 Xcode 專案（xcodegen）與 Reicon 圖示
f8eefb9 初始版本：Grid、Canvas、Infinity、Board 與預覽
```
