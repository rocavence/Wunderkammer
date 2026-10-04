import Foundation
import FoundationModels

/// Questions about the cabinet, answered on this Mac by Apple's on-device
/// model: it reads the question, the cabinet finds what's relevant with its
/// own search, and the model answers from those curiosities only.
@available(macOS 26.0, *)
@MainActor
final class Asker {
    struct Answer {
        var text: String
        /// What the answer is about, most relevant first.
        var items: [Item]
    }

    enum Failure: Error {
        case unavailable
        case refused
        case tooSlow
    }

    /// Long enough for a few sentences; a runaway generation stops here.
    private static let options = GenerationOptions(maximumResponseTokens: 300)

    /// Gives up after `seconds` rather than leaving the question hanging.
    func ask(_ question: String, within seconds: Double, now: Date = Date()) async throws -> Answer {
        try await withThrowingTaskGroup(of: Answer.self) { group in
            group.addTask { try await self.ask(question, now: now) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure.tooSlow
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    @Generable
    enum Kind {
        case anything, book, film, music, product, place, image, video, audio, document, webPage, text
    }

    @Generable
    struct Plan {
        @Guide(description: "Names, titles, topics and words from the question to search for, each also in English when the question isn't in English. No generic words like collection, thing, item.", .maximumCount(8))
        var keywords: [String]
        @Guide(description: "If the question is about what something looks like, a short English description of the picture; otherwise empty.")
        var looksLike: String
        @Guide(description: "What kind of curiosity the question is about.")
        var kind: Kind
        @Guide(description: "How many days back the question reaches (7 for last week, 30 for last month); 0 when it doesn't say.")
        var days: Int
    }

    /// What the last question was turned into (tests, debugging).
    private(set) var lastPlan = ""

    private let library: Library
    /// Curiosities that look like an English description (MobileCLIP), if installed.
    private let lookup: (String, [Item]) async -> [UUID]

    init(library: Library, lookup: @escaping (String, [Item]) async -> [UUID]) {
        self.library = library
        self.lookup = lookup
    }

    func ask(_ question: String, now: Date = Date()) async throws -> Answer {
        guard Self.isAvailable else { throw Failure.unavailable }
        do {
            let plan = try await LanguageModelSession(instructions: """
                You turn a question about someone's personal collection of curiosities \
                (images, films, books, music, web pages, notes, files) into a search.
                """).respond(to: question, generating: Plan.self, options: Self.options).content
            lastPlan = "\(plan.keywords) \(plan.looksLike) \(plan.kind) \(plan.days)"
            let found = await candidates(for: plan, question: question, now: now)
            let session = LanguageModelSession(instructions: """
                你是使用者私人收藏的助理。只根據提供的收藏回答，不要編造；\
                收藏裡沒有的就直說沒有。用繁體中文（台灣）回答，提到收藏時用它的標題。\
                人名與作品名可能用不同語言或拼法出現（例如王家衛就是 Wong Kar-Wai），視為同一個。\
                回答兩三句，用《》標出符合問題的收藏標題；沒有符合的就只說沒有，不要列舉其他收藏。
                """)
            let listing = found.enumerated().map { "[\($0.offset + 1)] \(Self.describe($0.element, now: now))" }.joined(separator: "\n")
            let reply = try await session.respond(to: """
                收藏（共 \(library.items.count) 件，以下是和問題相關的 \(found.count) 件）：
                \(listing.isEmpty ? "（沒有找到相關的收藏）" : listing)

                問題：\(question)
                """, options: Self.options).content
            // Plain text, not a structured reply: a long answer cut short still
            // reads. What it's about is whatever it names.
            return Answer(text: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                          items: found.filter { Self.names($0, in: reply) })
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { throw Failure.refused }
            if case .refusal = error { throw Failure.refused }
            throw error
        }
    }

    /// The cabinet's own search does the finding: words, names, then what
    /// things look like; with nothing to search for, the most recent.
    private func candidates(for plan: Plan, question: String, now: Date) async -> [Item] {
        var pool = library.items.filter { Self.matches($0, plan.kind) }
        if plan.days > 0, let since = Calendar.current.date(byAdding: .day, value: -plan.days, to: now) {
            pool = pool.filter { $0.dateAdded >= since }
        }
        var score: [UUID: Double] = [:]
        for keyword in plan.keywords {
            for (rank, item) in Search.run(keyword, in: pool, now: now).prefix(20).enumerated() {
                score[item.id, default: 0] += 2 - Double(rank) / 20
            }
        }
        if !plan.looksLike.isEmpty {
            for (rank, id) in await lookup(plan.looksLike, pool).enumerated() {
                score[id, default: 0] += 1.5 - Double(rank) / 24
            }
        }
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = score.sorted { $0.value > $1.value }.compactMap { byID[$0.key] }
        // When the question narrows by kind or time ("my films", "last week"),
        // the rest of that narrower pool comes after the hits: names in another
        // language or spelling are left for the model to recognise.
        let narrowed = plan.kind != .anything || plan.days > 0
        let namesNothing = plan.keywords.isEmpty && plan.looksLike.isEmpty
        let hits = Set(ranked.map(\.id))
        let rest = narrowed || namesNothing ? pool.filter { !hits.contains($0.id) } : []
        return Array((ranked + rest).prefix(20))
    }

    /// Whether the answer mentions this curiosity by its title, or names who
    /// made it ("the music is by Khruangbin").
    nonisolated static func names(_ item: Item, in answer: String) -> Bool {
        // "The Dispossessed: An Ambiguous Utopia" is often just "The Dispossessed".
        let title = (item.displayTitle.split(separator: ":").first.map(String.init) ?? item.displayTitle)
            .trimmingCharacters(in: .whitespaces)
        if title.count >= 3, answer.localizedCaseInsensitiveContains(title) { return true }
        return (item.credits ?? []).contains { $0.role != .brand && $0.name.count >= 3 && answer.localizedCaseInsensitiveContains($0.name) }
    }

    static func matches(_ item: Item, _ kind: Kind) -> Bool {
        switch kind {
        case .anything: true
        case .book: item.thing == .book
        case .film: item.thing == .movie || item.thing == .show
        case .music: item.thing == .music
        case .product: item.thing == .product
        case .place: item.thing == .place
        case .image: item.kind == .image
        case .video: item.kind == .video
        case .audio: item.kind == .audio
        case .document: item.kind == .pdf || item.kind == .file
        case .webPage: item.kind == .web
        case .text: item.kind == .text
        }
    }

    /// One line the model can read: what it is, who made it, where from, when.
    static func describe(_ item: Item, now: Date) -> String {
        let kinds: [Item.Kind: String] = [.image: "圖片", .video: "影片", .audio: "聲音", .pdf: "PDF", .web: "網頁", .text: "文字", .file: "檔案"]
        var parts = ["\(item.thing?.title ?? kinds[item.kind] ?? "")《\(item.displayTitle.prefix(80))》"]
        if let credits = item.credits, !credits.isEmpty {
            parts.append(credits.prefix(3).map { "\($0.role.title) \($0.name)" }.joined(separator: "、"))
        } else if let creator = item.creator {
            parts.append("作者 \(creator)")
        }
        if let released = item.released { parts.append("發行 \(released)") }
        if let domain = item.domain { parts.append("來自 \(domain)") }
        let days = Calendar.current.dateComponents([.day], from: item.dateAdded, to: now).day ?? 0
        parts.append(days == 0 ? "今天收藏" : "\(days) 天前收藏")
        if let text = item.text, item.kind == .text || item.kind == .web {
            parts.append("內容：\(text.prefix(140))")
        }
        if let ocr = item.ocrText, !ocr.isEmpty { parts.append("圖中文字：\(ocr.prefix(100))") }
        if let labels = item.labels, !labels.isEmpty { parts.append("看起來是：\(labels.prefix(4).joined(separator: ", "))") }
        return parts.joined(separator: "；").replacingOccurrences(of: "\n", with: " ")
    }
}
