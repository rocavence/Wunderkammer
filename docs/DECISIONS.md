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

## D11　瀏覽器擴充走 wunderkammer://，不開本機伺服器

* **選擇**：擴充與書籤小程式都只是組出 `wunderkammer://capture?url=…` 交給 macOS 開啟。Chrome 與 Zen／Firefox 共用同一份 MV3 擴充（`extensions/browser`）。
* **理由**：不需要在本機開 HTTP port，也就沒有被其他網站呼叫的風險；app 只接受 http(s) 網址（見 D05 之後的安全修正）。
* **代價**：瀏覽器第一次會詢問是否開啟 Wunderkammer。

## D12　App icon

* **選擇**：紙色圓角方形，中間是 Reicon 的 `cabinet`（實心）以墨色呈現。由 `scripts/icon/make-icon.sh` 產生。
* **怎麼改**：改 `scripts/icon/make-icon.swift` 後重跑。

## D13　Share extension 透過 App Group 收件匣

* **選擇**：「分享 → Wunderkammer」的延伸功能（沙盒）把內容寫進 App Group `7F654HZB2H.com.rocavence.wunderkammer` 的 `Inbox/`（每次分享一個資料夾，最後寫 `manifest.json`），立刻關閉；app 每 1.5 秒看一次收件匣，收進來後刪掉資料夾。
* **理由**：不能用 `wunderkammer://` 傳檔案路徑，那會讓任何網頁都能要 app 讀本機檔案。檔案仍然以參照方式收藏（D02）；圖片另帶一份副本，以防 app 讀不到原檔。
* **前提**：App Group 需要用 Team `7F654HZB2H` 簽章（`Config/Signing.local.xcconfig`）。ad-hoc 簽章時分享延伸功能不會運作，其他功能不受影響。
* **啟用**：macOS 預設不開新的分享延伸功能，要在「系統設定 → 一般 → 登入項目與延伸功能 → 分享」打開（已用 `pluginkit -e use` 替這台 Mac 打開）。

## D14　記憶體：嚴格的 LRU、小磚塊小解碼、看不到就不畫

* **問題**：收進 3,000 件後記憶體到 6.8 GB。三個原因：背景 Task 不會清 autorelease pool；隱藏中的 Canvas 仍在重畫，縮到全覽時 3,000 件都算「看得到」而全部解碼；NSCache 的上限只是建議。
* **選擇**：同步的圖片工作包 `autoreleasepool`；隱藏的 view 不畫也不留磚塊；解碼加上 160、320 px 兩級；圖片快取改成自己管的 LRU（上限 384 MB）。
* **結果**：3,000 件捲完全部約 900 MB（含快取與 Vision 模型）。

## D15　分享收件匣不信任 manifest

* **選擇**：manifest 裡的檔名只取最後一段且必須在該次分享的資料夾內；參照的檔案必須是家目錄（不含 ~/Library）或外接磁碟上、沒有隱藏路徑的一般檔案；網址只收 http(s)；最多 50 筆。
* **理由**：能寫進收件匣的程式也能寫 manifest，避免被拿來讓 app 讀取任意檔案（背景安全審查提出）。

## D16　名字與主題

* **名字**：用 NaturalLanguage 從標題、文字、圖中文字找出人名、地名、機構名，用在搜尋與「相關的收藏」。實測它分不太清楚類型（Hong Kong 被當成人名），所以只當「提到的名字」使用。中文不支援命名實體辨識，中文名字目前抓不到。
* **主題（Auto Collections）**：至少 3 件、但不到七成的物件標籤，自動成為側欄「主題」裡的 view（例如人物、插畫、動物），最多 6 個。太籠統的標籤（structure、material…）不算。常見標籤有中文名稱。
* **中文搜尋斷詞**：改用系統的 `NLTokenizer`，「王家衛的電影」會切成「王家衛」「電影」。

## D17　Spotlight 只放辨識用的資訊

* **選擇**：Spotlight 只收標題、網域、主題、顏色與縮圖；不放收藏的文字內容與圖中文字（OCR），文字收藏的標題也不含內文。每次啟動先清空再重建索引。
* **理由**：收進來的文字可能是私人內容，不應因此出現在系統搜尋（背景安全審查提出）。完整內容仍可在 app 內用 ⌘K 搜尋。

## D18　關掉視窗不結束 app

* **選擇**：關掉視窗後 app 繼續執行，⌘⇧C、分享、選單列都能用；點 Dock icon、選單列「打開珍奇室」或 ⌘0 叫回視窗。選單列有 Reicon cabinet icon。
* **理由**：收藏工具要隨時在背景接住東西。

## D19　語意搜尋：本機 MobileCLIP

* **選擇**：用 Apple 的 MobileCLIP S0（Core ML，約 106 MB）把圖片與英文描述放進同一個向量空間。搜尋時先顯示文字比對結果，約 0.25 秒後再補上「意思相符」的收藏。
* **中文描述**：系統裝有「中文（繁體）→ 英文」翻譯語言（macOS 26 以上）時，先在本機翻成英文；沒裝時只用已知詞的對照（紅色 → red）。選單「編輯 → 啟用中文描述搜尋…」會跳出系統的語言下載確認。
* **模型位置**：`~/Library/Application Support/Wunderkammer/models`，由 `scripts/models/fetch-mobileclip.sh` 下載與編譯，不進版控、不隨 app 散布。沒有模型時，搜尋只用文字比對，其他功能不受影響。
* **門檻**：只收明顯相符的（餘弦相似度 ≥ 0.19，且與最佳結果差距在 0.05 內，最多 24 件）。在 30 張迷因上，9 個描述全部第一名命中。
* **與規劃文件**：這是 Stage 2 的 US-201。仍是本機運算，符合 Local-first。
