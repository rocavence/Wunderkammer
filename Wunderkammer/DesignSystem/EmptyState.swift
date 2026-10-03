import Foundation

/// What an empty view says. Never just "No items": it says what this place is
/// for and the one thing to do.
enum EmptyState {
    static func message(for scope: Scope) -> String {
        if scope.isSearching { return "找不到「\(scope.search)」\n試試別的字，或是顏色、年份、網站名稱" }
        switch scope.base {
        case .all: return "珍奇室還是空的\n看到喜歡的東西，按 ⌘⇧C 收進來\n也可以把檔案、圖片、網址或文字拖到這裡"
        case .board: return "這個 board 還是空的\n把收藏拖到左邊的 board 名稱上，或直接拖檔案進來"
        case .kind(let k): return "還沒有\(k.title)\n收進來的\(k.title)會自動出現在這裡"
        case .onThisDay: return "過去的今天，你還沒有收藏東西\n明年的今天，這裡會有今天收的東西"
        case .forgotten: return "沒有被遺忘的東西\n收藏超過一個月沒看的，會慢慢出現在這裡"
        case .similar: return "系統還在看這件收藏\n看完就能找到相似的東西"
        case .subject: return "這個主題現在沒有東西了"
        case .mentions(let name): return "沒有其他收藏提到「\(name)」"
        case .site(let domain): return "沒有其他來自 \(domain) 的收藏"
        }
    }
}
