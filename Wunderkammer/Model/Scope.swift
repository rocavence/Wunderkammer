import Foundation

/// What the cabinet is showing: everything, a board, one of the system's own
/// views (by kind, rediscovery), narrowed by a search. Views over the
/// collection, never folders the user has to maintain.
struct Scope: Equatable, Sendable {
    enum Base: Equatable, Hashable, Sendable {
        case all
        case board(UUID)
        case kind(KindView)
        case onThisDay
        case forgotten
        /// Looks like this one (visual fingerprint).
        case similar(UUID)
        /// A theme the system found (a Vision label).
        case subject(String)
        /// Everything that mentions a name.
        case mentions(String)
        /// Everything from one website.
        case site(String)
        /// Recently looked at, newest first.
        case trail
        /// What an answer to a question was about, in the answer's order.
        case answer([UUID])
    }

    /// Auto collections by what things are: the kind of file, or what a page
    /// is about (a book, a film…).
    enum KindView: String, CaseIterable, Sendable {
        case images, web, text, media, documents
        case books, films, music, products, places

        var kinds: Set<Item.Kind> {
            switch self {
            case .images: [.image]
            case .web: [.web]
            case .text: [.text]
            case .media: [.video, .audio]
            case .documents: [.pdf, .file]
            case .books, .films, .music, .products, .places: []
            }
        }

        var things: Set<Item.Thing> {
            switch self {
            case .books: [.book]
            case .films: [.movie, .show]
            case .music: [.music]
            case .products: [.product]
            case .places: [.place]
            default: []
            }
        }

        func contains(_ item: Item) -> Bool {
            kinds.contains(item.kind) || item.thing.map(things.contains) == true
        }

        var title: String {
            switch self {
            case .images: "圖片"
            case .web: "網頁"
            case .text: "文字"
            case .media: "影片與聲音"
            case .documents: "文件與檔案"
            case .books: "書"
            case .films: "電影與影集"
            case .music: "音樂"
            case .products: "商品"
            case .places: "地點"
            }
        }
    }

    var base: Base = .all
    var search = ""
    /// Items that match the search by meaning (MobileCLIP), filled in after the words.
    var semantic: [UUID] = []

    var board: UUID? {
        if case .board(let id) = base { return id }
        return nil
    }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Canvas layouts are kept per base view.
    var canvasKey: String {
        switch base {
        case .all: Library.allKey
        case .board(let id): id.uuidString
        case .kind(let k): "kind:\(k.rawValue)"
        case .onThisDay: "onThisDay"
        case .forgotten: "forgotten"
        case .similar(let id): "similar:\(id.uuidString)"
        case .subject(let label): "subject:\(label)"
        case .mentions(let name): "mentions:\(name)"
        case .site(let domain): "site:\(domain)"
        case .trail: "trail"
        case .answer: "answer"
        }
    }
}

extension Library {
    /// The items a scope shows, in display order (newest first; search by relevance).
    func items(for scope: Scope, now: Date = Date()) -> [Item] {
        var result: [Item]
        switch scope.base {
        case .all: result = items
        case .board(let id): result = items(in: id)
        case .kind(let k): result = items.filter(k.contains)
        case .onThisDay: result = Rediscovery.onThisDay(items, now: now)
        case .forgotten: result = Rediscovery.forgotten(items, now: now)
        case .similar(let id): result = (item(id).map { [$0] } ?? []) + (similarity?(id) ?? [])
        case .subject(let label): result = items.filter { $0.labels?.contains(label) == true }
        case .mentions(let name):
            let key = Search.normalize(name)
            result = items.filter { $0.entities?.contains { Search.normalize($0.name) == key } == true }
        case .site(let domain): result = items.filter { $0.domain == domain }
        case .trail: result = (recentlyViewed?() ?? []).compactMap(item)
        case .answer(let ids): result = ids.compactMap(item)
        }
        if scope.isSearching {
            let pool = result
            result = Search.run(scope.search, in: pool, now: now)
            // Then what matches by meaning, if the words didn't already find it.
            let found = Set(result.map(\.id))
            let inScope = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            result += scope.semantic.filter { !found.contains($0) }.compactMap { inScope[$0] }
        }
        return result
    }
}
