# 從瀏覽器收藏

三種方式，挑一種就好。都是透過 `wunderkammer://capture` 交給 app，不經過任何伺服器。

## 1. ⌘⇧C（不用裝任何東西）

在瀏覽器裡按 ⌘⇧C 收目前頁面；剛複製過圖片或文字時，收的是剪貼簿。

* Safari、Chrome、Arc、Brave、Edge：第一次會詢問「自動化」權限。
* Zen、Firefox：需要「輔助使用」權限（系統設定 → 隱私權與安全性 → 輔助使用 → 打開 Wunderkammer）。

## 2. 瀏覽器擴充（Chrome、Zen、Firefox）

右鍵選單「收進 Wunderkammer」可以收頁面、連結、圖片或選取的文字；工具列按鈕收目前頁面。

* **Chrome 系**：打開 `chrome://extensions` → 開啟「開發人員模式」→「載入未封裝項目」→ 選 `extensions/browser`。
* **Zen／Firefox**：打開 `about:debugging#/runtime/this-firefox` →「載入暫時附加元件」→ 選 `extensions/browser/manifest.json`。

第一次收藏時瀏覽器會問「要打開 Wunderkammer 嗎？」，勾選「一律允許」之後就不會再問。

## 3. 書籤小程式（任何瀏覽器）

新增一個書籤，網址填入下面這行。有選取文字時收文字（附上來源頁面），沒有就收整個頁面。

```
javascript:(()=>{const s=getSelection().toString();location.href='wunderkammer://capture?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)+(s?'&text='+encodeURIComponent(s):'')})()
```
