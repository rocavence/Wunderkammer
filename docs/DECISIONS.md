# Wunderkammer 決策紀錄

規格沒寫清楚、或需要取捨時所做的選擇。每一項都寫明理由與修改方式。

---

## D01　專案結構照 Flione：xcodegen ＋ Reicon

* **選擇**：從 SwiftPM 改成 `project.yml`（xcodegen）產生 Xcode 專案；UI icon 一律走 Reicon（`scripts/reicon/icons.txt` → `generate.py`），經由 `Icon.image(_:)` 取用，不直接用 SF Symbols。
* **理由**：Share extension、Services、asset catalog（app icon、Reicon）都需要 Xcode target；SwiftPM 做不到。結構、簽章設定（`Config/Signing.xcconfig`）沿用 Flione。
* **怎麼改**：新增 icon 在 `icons.txt` 加一行後重跑 `python3 scripts/reicon/generate.py`。
