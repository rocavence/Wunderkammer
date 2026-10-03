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
    }

    /// Auto collections by what things are.
    enum KindView: String, CaseIterable, Sendable {
        case images, web, text, media, documents

        var kinds: Set<Item.Kind> {
            switch self {
            case .images: [.image]
            case .web: [.web]
            case .text: [.text]
            case .media: [.video, .audio]
            case .documents: [.pdf, .file]
            }
        }

        var title: String {
            switch self {
            case .images: "圖片"
            case .web: "網頁"
            case .text: "文字"
            case .media: "影片與聲音"
            case .documents: "文件與檔案"
            }
        }
    }

    var base: Base = .all
    var search = ""

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
        case .kind(let k): result = items.filter { k.kinds.contains($0.kind) }
        case .onThisDay: result = Rediscovery.onThisDay(items, now: now)
        case .forgotten: result = Rediscovery.forgotten(items, now: now)
        case .similar(let id): result = (item(id).map { [$0] } ?? []) + (similarity?(id) ?? [])
        }
        if scope.isSearching { result = Search.run(scope.search, in: result, now: now) }
        return result
    }
}
