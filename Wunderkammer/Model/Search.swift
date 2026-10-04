import Foundation
import NaturalLanguage

/// Search over everything the system knows: titles, file names, sites, text,
/// words in pictures (OCR), what's in them (labels), their colours, when they
/// were collected. Structure built by the system, never by the user.
enum Search {
    /// Words that carry no meaning in "things I saved in 2025".
    private static let stopwords: Set<String> = [
        "the", "a", "an", "of", "in", "on", "at", "with", "and", "or", "that", "this", "i", "my", "me",
        "things", "thing", "saved", "collected", "stuff", "from", "to", "for", "some", "any",
        "的", "我", "我的", "收藏", "收藏的", "存的", "那個", "那張", "東西", "有", "在", "和", "跟",
    ]

    /// Chinese words for the things Vision labels and colours are named in.
    static let synonyms: [String: [String]] = [
        "紅": ["red"], "紅色": ["red"], "橙": ["orange"], "橘": ["orange"], "橘色": ["orange"], "黃": ["yellow"], "黃色": ["yellow"],
        "綠": ["green"], "綠色": ["green"], "藍": ["blue"], "藍色": ["blue"], "紫": ["purple"], "紫色": ["purple"],
        "粉": ["pink"], "粉紅": ["pink"], "粉紅色": ["pink"], "棕": ["brown"], "咖啡色": ["brown"], "黑": ["black"], "黑色": ["black"],
        "白": ["white"], "白色": ["white"], "灰": ["gray"], "灰色": ["gray"],
        "椅子": ["chair"], "桌子": ["table"], "沙發": ["sofa", "couch"], "燈": ["lamp", "light"], "貓": ["cat", "feline"], "狗": ["dog", "canine"],
        "人": ["people", "person"], "臉": ["face", "people"], "車": ["car", "vehicle"], "建築": ["building", "structure", "architecture"],
        "房子": ["house", "building"], "海": ["sea", "ocean", "water"], "山": ["mountain"], "樹": ["tree"], "花": ["flower"], "天空": ["sky"],
        "食物": ["food"], "書": ["book", "document"], "海報": ["poster"], "字": ["text", "document"], "文字": ["text"],
        "電影": ["movie", "film", "poster"], "音樂": ["music", "audio"], "照片": ["photo", "image"], "圖片": ["image"],
        "網頁": ["web"], "網站": ["web"], "影片": ["video"], "文件": ["pdf", "document"], "截圖": ["screenshot"],
    ]

    /// Kind words in both languages, so "pdf" or "影片" find by type.
    private static let kindWords: [Item.Kind: [String]] = [
        .image: ["image", "picture", "photo", "圖片", "圖", "照片"],
        .video: ["video", "movie", "影片", "視訊"],
        .audio: ["audio", "music", "sound", "song", "音樂", "聲音", "歌"],
        .pdf: ["pdf", "document", "文件"],
        .web: ["web", "website", "page", "link", "網頁", "網站", "連結"],
        .text: ["text", "quote", "note", "文字", "引文", "筆記"],
        .file: ["file", "檔案"],
    ]

    static func run(_ query: String, in items: [Item], now: Date = Date()) -> [Item] {
        let terms = tokens(query)
        guard !terms.isEmpty else { return items }
        let scored: [(Item, Double)] = items.compactMap { item in
            var score = 0.0
            for term in terms {
                let s = match(term, item)
                if s == 0 { return nil } // every term has to be somewhere
                score += s
            }
            // Recent things win ties.
            score += 0.2 / (1 + now.timeIntervalSince(item.dateAdded) / 86400 / 30)
            return (item, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Lowercased, accent- and width-insensitive words, minus stopwords. A
    /// Chinese phrase with no spaces is split around the words we know.
    static func tokens(_ query: String) -> [String] {
        var words: [String] = []
        for raw in normalize(query).split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == "、" }) {
            let w = String(raw)
            if w.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                words.append(contentsOf: splitCJK(w))
            } else {
                words.append(w)
            }
        }
        return words.filter { !$0.isEmpty && !stopwords.contains($0) }
    }

    /// "紅色的椅子" → ["紅色", "椅子"], "王家衛的電影" → ["王家衛", "電影"]: the
    /// system word segmenter, then stopwords dropped.
    private static func splitCJK(_ s: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        return tokenizer.tokens(for: s.startIndex..<s.endIndex).map { String(s[$0]) }
    }

    /// How well one term matches: 0 if nowhere.
    private static func match(_ term: String, _ item: Item) -> Double {
        let alternatives = [term] + (synonyms[term] ?? [])
        var best = 0.0
        for t in alternatives {
            if let year = Int(t), (1990...2100).contains(year) {
                if Calendar.current.component(.year, from: item.dateAdded) == year { best = max(best, 2) }
                continue
            }
            if contains(item.title, t) { best = max(best, 3) }
            if contains(item.originalFilename, t) { best = max(best, 2.5) }
            if contains(item.domain, t) || contains(item.creator, t) { best = max(best, 2) }
            if item.labels?.contains(where: { normalize($0) == t || normalize($0).hasPrefix(t) }) == true { best = max(best, 2) }
            if item.colors?.contains(where: { normalize($0) == t }) == true { best = max(best, 1.8) }
            if item.entities?.contains(where: { normalize($0.name).contains(t) }) == true { best = max(best, 2.2) }
            if item.labels?.contains(where: { Subjects.chinese[$0].map(normalize) == t }) == true { best = max(best, 2) }
            if kindWords[item.kind]?.contains(t) == true { best = max(best, 1.5) }
            if contains(item.text, t) || contains(item.ocrText, t) { best = max(best, 1.2) }
            if contains(item.pageText, t) { best = max(best, 0.8) }
            if contains(item.url, t) || contains(item.sourceApp, t) { best = max(best, 1) }
        }
        return best
    }

    /// Why this item is among the results, in a few words: 「標題」, 「圖中文字」,
    /// 「名字 Wong Kar-Wai」. nil-free: what the words didn't find, meaning did.
    static func reason(_ query: String, _ item: Item) -> String {
        var found: [String] = []
        func add(_ r: String) { if !found.contains(r) { found.append(r) } }
        for term in tokens(query) {
            for t in [term] + (synonyms[term] ?? []) {
                if let year = Int(t), (1990...2100).contains(year) {
                    if Calendar.current.component(.year, from: item.dateAdded) == year { add("\(year) 年收藏") }
                    continue
                }
                if contains(item.title, t) { add("標題"); break }
                if contains(item.originalFilename, t) { add("檔名"); break }
                if let name = item.entities?.first(where: { normalize($0.name).contains(t) }) { add("名字 \(name.name)"); break }
                if contains(item.creator, t) { add("作者 \(item.creator ?? "")"); break }
                if contains(item.domain, t) { add("網站"); break }
                if let label = item.labels?.first(where: { normalize($0) == t || normalize($0).hasPrefix(t) || Subjects.chinese[$0].map(normalize) == t }) {
                    add("主題 \(Subjects.title(label))"); break
                }
                if item.colors?.contains(where: { normalize($0) == t }) == true { add("顏色"); break }
                if kindWords[item.kind]?.contains(t) == true { add("類型"); break }
                if contains(item.ocrText, t) { add("圖中文字"); break }
                if contains(item.text, t) { add("內文"); break }
                if contains(item.pageText, t) { add("頁面內文"); break }
                if contains(item.url, t) { add("網址"); break }
            }
        }
        return found.isEmpty ? "意思相近" : "符合：" + found.prefix(3).joined(separator: "、")
    }

    private static func contains(_ field: String?, _ term: String) -> Bool {
        guard let field, !field.isEmpty else { return false }
        return normalize(field).contains(term)
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
