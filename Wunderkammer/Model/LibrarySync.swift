import Foundation

/// A 展室 kept in iCloud Drive can change on two Macs at once. When the other
/// Mac's copy arrives, the two are put together instead of one overwriting
/// the other: what either side added stays, what either side removed goes,
/// and for anything changed on both, the later change wins.
enum LibrarySync {
    /// `known`: the ids on disk the last time this Mac read or wrote it. An id
    /// one side lacks was removed there if it was known; otherwise it's new.
    static func merge(local: [Item], remote: [Item], known: Set<UUID>) -> [Item] {
        let theirs = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Set(local.map(\.id))
        var merged: [Item] = []
        for item in local {
            if let other = theirs[item.id] {
                merged.append(later(item, other))
            } else if !known.contains(item.id) {
                merged.append(item)
            }
        }
        merged += remote.filter { !mine.contains($0.id) && !known.contains($0.id) }
        return merged.sorted { $0.dateAdded > $1.dateAdded }
    }

    /// The later edit, keeping the most looking-at from either side.
    static func later(_ a: Item, _ b: Item) -> Item {
        var pick = (a.modified ?? .distantPast) >= (b.modified ?? .distantPast) ? a : b
        pick.viewCount = max(a.viewCount, b.viewCount)
        pick.lastViewed = [a.lastViewed, b.lastViewed].compactMap { $0 }.max()
        return pick
    }

    /// Boards the same way; a board on both sides keeps every item either put in it.
    static func merge(local: [Board], remote: [Board], known: Set<UUID>) -> [Board] {
        let theirs = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Set(local.map(\.id))
        var merged: [Board] = []
        for board in local {
            if var other = theirs[board.id] {
                let extra = other.itemIDs.filter { !board.itemIDs.contains($0) }
                other.name = board.name
                other.itemIDs = board.itemIDs + extra
                merged.append(other)
            } else if !known.contains(board.id) {
                merged.append(board)
            }
        }
        return merged + remote.filter { !mine.contains($0.id) && !known.contains($0.id) }
    }

    /// Canvas layouts by key: this Mac's where both have one.
    static func merge<V>(local: [String: V], remote: [String: V]) -> [String: V] {
        local.merging(remote) { mine, _ in mine }
    }
}

/// Hears about library.json being replaced by iCloud (the other Mac saved).
final class LibraryFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let changed: @MainActor () -> Void

    init(_ url: URL, changed: @escaping @MainActor () -> Void) {
        presentedItemURL = url
        self.changed = changed
        super.init()
    }

    func presentedItemDidChange() {
        MainActor.assumeIsolated { changed() }
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        MainActor.assumeIsolated { changed() }
    }
}
