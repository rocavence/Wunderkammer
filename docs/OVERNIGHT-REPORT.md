# 夜間進度報告（2026-10-04 00:40–）

## 一句話

依照 Product Planning 與 User Stories Roadmap：**Stage 1 的完成定義 11 項全部達成**；Stage 2 除了自然語言問答（US-211），其餘都已在本機實作（OCR、物件、顏色、相似、相關、語意搜尋、主題、名字、隨機、過去的今天、被遺忘的、足跡）；Stage 3 先做了 Canvas 依主題分堆、連線與文化圖譜。

每項都用 app 本身的端對端自我測試實際操作並截圖驗證：單元測試 74 個、端對端檢查 80 多項（另有 4 項效能測試），全部通過。另外跑了三輪背景程式碼審查，找到的 29 個問題全部修正，主要的資料安全問題都補上了回歸測試。所有 commit 都只在本機，沒有 push。

## 早上先做這 4 件事（約 5 分鐘）

1. Wunderkammer 已經開著（`dist/Wunderkammer.app`），選單列有珍奇櫃 icon。你的 30 張迷因已轉成新格式，也分析完了。
2. 在 Safari 或 Zen 隨便打開一頁，按 `⌘⇧C`。Safari 第一次會問「自動化」權限；Zen 要到「系統設定 → 隱私權與安全性 → 輔助使用」打開 Wunderkammer。
3. 在 app 裡試：按 `R`；`⌘K` 搜尋「receive」（只出現在 Trade Offer 圖裡的字）；搜尋「a cat at a dinner table」（語意搜尋）；右鍵任一張「找相似的」；`⌘6` 看文化圖譜。
4. 想用中文描述搜尋：選單「編輯 → 啟用中文描述搜尋…」按「下載」（系統的翻譯語言，在本機運作）。

截圖在 `docs/screenshots/`（23 張）。

## 完成項目

### Stage 1 — Foundation

| User Story | 狀態 | 說明 |
|---|---|---|
| US-001 收圖片 | 完成 | 複製圖片後 `⌘⇧C`；保存來源網址 |
| US-002 收網址 | 完成 | 瀏覽器內 `⌘⇧C` 直接收目前分頁；標題、描述、預覽圖、favicon 在背景補上 |
| US-003 收文字 | 完成 | 保存文字與來源網頁；畫成文字卡 |
| US-004 拖放檔案 | 完成 | 圖片、影片、聲音、PDF、app、任何檔案；以參照收藏，不複製 |
| US-005 截圖 | 完成 | `⌃⌘⇧C` |
| US-006 全域快捷鍵 | 完成 | `⌘⇧C`，可在設定（`⌘,`）自訂 |
| US-007 瀏覽器擴充 | 完成 | Chrome、Zen、Firefox 共用；另有書籤小程式（`extensions/README.md`） |
| US-008 分享 | 完成 | 「分享 → Wunderkammer」，用系統分享流程實測過 |
| US-009 Cabinet | 完成 | Grid、Masonry、Timeline（日期標題固定置頂），外加 Canvas、Infinity、Graph |
| US-010 Quick Look | 完成 | `Space`；影音、文件、長文字用系統 Quick Look |
| US-011 基本搜尋 | 完成 | `⌘K`；也搜得到圖中文字、物件、顏色、年份 |
| US-012 自動 metadata | 完成 | 標題、網址、網域、尺寸、長度、頁數、類型、建立日期、收藏日期、來源 app |
| US-013 移除與復原 | 完成 | `Delete` 不跳對話框，`⌘Z` 復原 |
| US-014 零整理 | 完成 | 不需要建立任何資料夾或 tag；側欄的 view 都由系統維護 |

另外：滑鼠停在影片上原地靜音播放、停在網頁與文件上顯示標題、沒有預覽圖的網頁用頁面截圖、第一次打開的歡迎頁（三種收藏方式，偵測到 Atlas 圖庫時可一鍵帶進來）、服務選單、拖到 Dock、選單列 icon、Spotlight、`wunderkammer://` 連結、app icon（Reicon cabinet）、關掉視窗仍可在背景收藏、淺色與深色模式、VoiceOver（Grid）。

### Stage 2 — Intelligence（全部在本機）

| User Story | 狀態 | 說明 |
|---|---|---|
| US-201 Semantic Search | 完成 | MobileCLIP：用描述找圖；30 張迷因上 9 個描述全部第一名命中 |
| US-202 Visual Search | 完成 | 右鍵「找相似的」 |
| US-203 OCR | 完成 | Vision 自動偵測語言；PDF 讀文字層 |
| US-204 Entities | 部分 | 英文名字可以；中文沒有命名實體辨識（系統不支援） |
| US-205 Related | 完成 | Inspector「相關的收藏」：長得像、同網站、同作者、共同主題、同樣的名字 |
| US-206 Random | 完成 | `R`，依年紀、沒看多久、看過幾次加權，顯示「你在 N 天前收藏了這個」 |
| US-207 Forgotten Gems | 完成 | 「被遺忘的」：超過一個月沒看，以前反覆看過的排前面 |
| US-208 On This Day | 完成 | 「過去的今天」 |
| US-209 Connections | 部分 | Inspector 的名字與網站可點開，看所有連到它的收藏 |
| US-210 Auto Collections | 完成 | 側欄「主題」由物件標籤自動長出（人物、插畫、動物……） |
| US-211 Questions | 未做 | 需要 Apple 本機語言模型；這台 Mac 回報 `modelNotReady`，無法驗證 |

### Stage 3 — World（先做的部分）

| User Story | 狀態 | 說明 |
|---|---|---|
| US-301 Canvas | 完成 | 每個 view（類型、主題、board）都有自己的 canvas |
| US-302 Infinite Canvas | 部分 | 縮放、平移、排列、分堆、連線（⌥ 從一件拖到另一件） |
| US-303 Spatial Clustering | 完成 | Canvas 右鍵「依主題分堆」 |
| US-304 Culture Graph | 完成 | `⌘6`：主題、名字、網站與它們之間的共同收藏 |
| US-305 Curiosity Trails | 部分 | 「足跡」記下看過什麼、怎麼來的；Inspector 顯示上次的來路 |
| US-306～311 | 未做 | Discovery engine、同步、行動版、共享、公開 |

### 依你半夜的回饋

* Infinity 展開後點空白會穿透開啟下一張：已修正並加入測試。
* 專案結構照 Flione：xcodegen、`Config/Signing.xcconfig`、Reicon、`docs/DECISIONS.md`、本報告。

## 實測數據

這台 Mac，Debug build，`scripts/selftest.sh perf`。

| 項目 | 結果 | 目標 |
|---|---|---|
| 收一段文字 | 6–14 ms | ≤ 1 秒 |
| 收一個網址（卡片立即出現，預覽之後補） | 16–23 ms | ≤ 1 秒 |
| 收一張 3000×2000 圖片 | 18–19 ms | ≤ 1 秒 |
| 收 5 個系統檔案（60 秒影片、聲音、HEIC、PDF、app） | 345 ms | — |
| 收進 3,000 張圖 | 14.4 秒（每張 4.9 ms） | — |
| 捲動 3,000 件 | 每步平均 0.6 ms，最差 4.6 ms | 每幀 < 16 ms |
| 捏合縮放 3,000 件 | 每幀 0.45 ms；放開後重排 3.5 ms | 每幀 < 16 ms |
| 搜尋 3,000 件 | 11 ms | — |
| 記憶體（3,000 件捲完） | 約 900 MB（原本 6.8 GB，已修正） | 有上限 |
| 理解 30 件（OCR、物件、顏色、特徵） | 首次約 12 秒（含載入模型），之後約 1 秒 | 背景執行 |

## 我替你做的決定

完整理由與修改方式在 `docs/DECISIONS.md`（D01–D23）。重點：

| # | 決定 | 不同意時 |
|---|---|---|
| D02 | 檔案用參照，不複製進圖庫 | 改 `Representer.file(_:)` |
| D03 | 移除不跳確認，`⌘Z` 復原 | — |
| D04 | 沒有圖的東西畫成紙色、襯線字的卡片 | 改 `CardRenderer.swift` |
| D05 | `⌘⇧C`：60 秒內剛複製的優先，否則收瀏覽器目前分頁 | 改 `CaptureController` |
| D07 | 側欄：珍奇室、系統整理、主題、重新發現，board 放最後 | 改 `SidebarViewController` |
| D17 | Spotlight 只放標題、網站、主題，不放文字內容 | 設定可關閉 |
| D18 | 關掉視窗不結束 app | — |
| D19 | 語意搜尋用本機 MobileCLIP，模型另外安裝 | `scripts/models/fetch-mobileclip.sh` |

## 需要你決定的事

1. **語意搜尋模型怎麼散布。** 模型（106 MB）目前由腳本另外安裝，這台 Mac 已裝。要給別人用時：內建在 app（app 變大），或第一次使用時詢問後下載。
2. **`⌘⇧C` 的預設值。** Chrome 開發者工具和 Finder 也用這組。現在可以在設定裡換；要不要換預設？
3. **Board 的去留。** 規劃文件說 Folder 不應是必要的；目前 board 放在側欄最下面。要不要完全隱藏，只在 Canvas 裡用？
4. **US-211（問收藏問題）。** 要等這台 Mac 的 Apple Intelligence 模型就緒；或改用雲端模型（違反預設 Local-first，需要明確開關）。

## 已知限制

* 中文的人名、地名抓不到（Apple NaturalLanguage 不支援中文命名實體辨識）。
* 被參照的檔案如果被刪除，只剩 representation 可看，無法開原檔。
* 分享延伸功能需要 Team `7F654HZB2H` 簽章；ad-hoc 簽章時不運作。
* 只有圖片時，文化圖譜只有主題節點；收進網頁與文字後才會出現名字與網站。


## Commit 一覽

都在本機，沒有 push。每個 commit 是一個獨立功能，可以單獨 `git revert`。完整列表：`git log --oneline`。
