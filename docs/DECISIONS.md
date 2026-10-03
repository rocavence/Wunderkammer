# Wunderkammer 決策紀錄

規格沒寫清楚、或需要取捨時所做的選擇。每一項都寫明理由與修改方式。

---

## D01　專案結構照 Flione：xcodegen ＋ Reicon

* **選擇**：從 SwiftPM 改成 `project.yml`（xcodegen）產生 Xcode 專案；UI icon 一律走 Reicon（`scripts/reicon/icons.txt` → `generate.py`），經由 `Icon.image(_:)` 取用，不直接用 SF Symbols。
* **理由**：Share extension、Services、asset catalog（app icon、Reicon）都需要 Xcode target；SwiftPM 做不到。結構、簽章設定（`Config/Signing.xcconfig`）沿用 Flione。
* **怎麼改**：新增 icon 在 `icons.txt` 加一行後重跑 `python3 scripts/reicon/generate.py`。

## D02　Curiosity：檔案用參照，不複製

* **選擇**：拖進來的檔案只記路徑和 bookmark（檔案搬家也找得到），不複製進圖庫。只有本身沒有檔案的內容才保存一份：複製的圖片、截圖、瀏覽器拖進來的圖。
* **理由**：規劃文件 §08「Representation, Not Storage」。圖庫只放 representation（`thumbnails/`）與 metadata。
* **代價**：原始檔被刪除後，只剩 representation 可看，不能看原圖或開啟檔案。
* **怎麼改**：`Representer.file(_:)` 改成也寫一份到 `originals/` 即可。

## D03　移除不跳確認，⌘Z 復原

* **選擇**：Delete 直接移除，不跳對話框；⌘Z 可以復原（包含它原本所在的 board 與 canvas 位置）。被移除項目自己保存的副本，下次啟動才清除。
* **理由**：規劃文件「No modal interruption」與 US-013。參照的檔案從來不是 Wunderkammer 的，所以移除永遠不會動到使用者的檔案。

## D04　Representation 卡片風格

* **選擇**：沒有圖的東西（文字、沒有預覽圖的網頁、沒有封面的音樂、其他檔案）畫成紙色底、襯線字的卡片；音樂畫出波形。
* **理由**：規劃文件 §21「Quiet / Editorial / Curatorial / Tactile」。卡片在 `CardRenderer.swift`，用 CoreText 在背景執行緒繪製。

## D05　⌘⇧C 收什麼

* **選擇**：60 秒內剛複製過東西 → 收剪貼簿；否則如果最前面是瀏覽器 → 收目前分頁；都不是 → 收剪貼簿現有的內容。收完在螢幕上方出現 1.6 秒的提示，不搶焦點、不需要回應。
* **理由**：US-001（複製圖片後 ⌘⇧C）與 US-002（在 Safari 直接 ⌘⇧C 收網址）要同一個快捷鍵兩種都能做。
* **瀏覽器**：Safari 與 Chrome 系（Chrome、Arc、Brave、Edge、Vivaldi）用 AppleScript 讀網址，第一次會跳「自動化」權限。Firefox 系（含 Zen）沒有 AppleScript，改送 ⌘L ⌘C 讀網址列，需要「輔助使用」權限；讀完會把剪貼簿還原。
* **已知衝突**：⌘⇧C 在 Chrome 開發者工具（檢查元素）與 Finder（電腦）也有用途；註冊失敗時選單會顯示。
* **怎麼改**：`CaptureController.captureShortcut`。

## D06　截圖收藏：⌃⌘⇧C

* **選擇**：呼叫系統 `screencapture -i`（拖曳選範圍，按空白鍵選視窗），截好直接收進來。
* **理由**：沿用系統的截圖介面，不重做。第一次會要求「螢幕錄製」權限。

## D07　側欄：系統整理的 view，board 最後

* **選擇**：側欄由上到下是「珍奇室」、系統依類型整理的 view（圖片、網頁、文字、影片與聲音、文件與檔案，只有有東西時才出現）、「重新發現」（過去的今天、被遺忘的、隨機一件），最後才是 board。
* **理由**：規劃文件 §15「Auto Collections 是系統建立的 Views，而不是使用者維護的 Folder」與 §20「避免 Folder-first navigation」。board 保留但不是主角。

## D08　搜尋結果在原地篩選

* **選擇**：⌘K 跳到 toolbar 的搜尋欄，邊打邊在目前的 view 篩選（磚塊飛到新位置）。在 Canvas／Infinity 搜尋時切到 Grid，因為搜尋結果是要掃過的清單。
* **範圍**：標題、檔名、網站、作者、文字內容、圖中文字（OCR）、系統辨識的物件與顏色、類型、收藏年份。中文查詢會切開已知詞並對應到英文標籤（「紅色的椅子」→ red、chair）。語意搜尋留給 Stage 2。

## D09　Space：圖片、網頁、文字用自己的預覽；影音與文件用系統 Quick Look

* **選擇**：圖片、網頁、文字從磚塊飛出（自己的預覽）；影片、聲音、PDF、其他檔案交給系統 Quick Look，能播放、翻頁。Enter 用預設 app 或瀏覽器打開。

## D10　理解收藏：全部在本機

* **選擇**：用 Apple Vision 在本機做 OCR（自動偵測語言）、物件辨識、主色與視覺特徵；PDF 直接讀文字層。背景依新到舊一件一件處理，視窗副標題顯示「正在理解 N 件」。
* **理由**：規劃文件 §17「Your curiosities are yours」「AI 功能優先 Local」。不需要網路、不上傳任何內容。
* **OCR 語言**：固定語言清單時第一個語言會主導（中文在前讀英文會讀錯，英文在前讀中文會讀錯），所以用自動偵測。
* **重跑**：`Analyzer.version` 提高時，舊的分析結果會在背景重做。
* **相似**：視覺特徵距離只保留明顯較近的（平均減半個標準差，至少 6、最多 24 件）。「相關的收藏」再加上同網站、同作者、共同物件標籤。
* **還沒做**：語意搜尋（「很像 Blade Runner 的東西」）需要文字與圖片共用的 embedding 模型，留到下一階段評估。
