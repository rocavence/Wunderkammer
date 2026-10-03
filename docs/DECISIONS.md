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
