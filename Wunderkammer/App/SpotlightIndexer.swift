import CoreSpotlight
import UniformTypeIdentifiers

/// Puts the cabinet in Spotlight so a curiosity can be found from anywhere on
/// the Mac. Only what identifies it goes in (title, site, themes, thumbnail):
/// never the collected text or the words read from pictures, which may be
/// private. The index is rebuilt at launch, so nothing removed lingers.
@MainActor
final class SpotlightIndexer {
    private let library: Library
    private let index = CSSearchableIndex(name: "Wunderkammer")
    private var indexed: [UUID: Int] = [:]
    private var work: DispatchWorkItem?

    init(library: Library) {
        self.library = library
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        NotificationCenter.default.addObserver(forName: Understanding.didProgress, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        // Start clean: anything removed while the index was stale goes away.
        index.deleteAllSearchableItems { _ in
            Task { @MainActor [weak self] in self?.schedule() }
        }
    }

    /// Batches changes: index a few seconds after things settle.
    private func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sync() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func sync() {
        let current = Dictionary(uniqueKeysWithValues: library.items.map { ($0.id, Self.signature($0)) })
        let removed = indexed.keys.filter { current[$0] == nil }.map(\.uuidString)
        let changed = library.items.filter { indexed[$0.id] != current[$0.id] }
        if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: removed) }
        // Remember removals too, so an undo is seen as new and indexed again.
        indexed = current
        guard !changed.isEmpty else { return }
        index.indexSearchableItems(changed.map(searchable))
    }

    /// Changes when anything Spotlight shows changes.
    private static func signature(_ item: Item) -> Int {
        var h = Hasher()
        h.combine(item.title); h.combine(item.labels); h.combine(item.representationVersion); h.combine(item.url)
        return h.finalize()
    }

    /// Settings turned Spotlight off: take everything out.
    static func clear() {
        CSSearchableIndex(name: "Wunderkammer").deleteAllSearchableItems(completionHandler: nil)
    }

    private func searchable(_ item: Item) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        // Text curiosities are their content: name them by kind and source instead.
        attributes.title = item.kind == .text ? "文字收藏" + (item.domain.map { "（\($0)）" } ?? "") : item.displayTitle
        attributes.contentDescription = item.domain
        attributes.keywords = (item.labels ?? []).map(Subjects.title) + (item.colors ?? [])
        // A text card is a picture of the text itself: no thumbnail for those.
        if item.kind != .text { attributes.thumbnailURL = library.thumbnailURL(item) }
        attributes.contentCreationDate = item.dateAdded
        attributes.url = item.url.flatMap(URL.init(string:))
        return CSSearchableItem(uniqueIdentifier: item.id.uuidString, domainIdentifier: item.kind.rawValue, attributeSet: attributes)
    }
}
