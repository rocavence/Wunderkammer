import CoreSpotlight
import UniformTypeIdentifiers

/// Puts the cabinet in Spotlight: title, text, words in pictures, site and
/// thumbnail, so a curiosity can be found from anywhere on the Mac.
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
        schedule()
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
        guard !changed.isEmpty else { return }
        let items = changed.map(searchable)
        index.indexSearchableItems(items)
        indexed = current
    }

    /// Changes when anything Spotlight shows changes.
    private static func signature(_ item: Item) -> Int {
        var h = Hasher()
        h.combine(item.title); h.combine(item.text?.prefix(200)); h.combine(item.ocrText?.prefix(200))
        h.combine(item.labels); h.combine(item.representationVersion); h.combine(item.url)
        return h.finalize()
    }

    private func searchable(_ item: Item) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = item.displayTitle
        attributes.contentDescription = [item.domain, item.text?.prefix(300).description, item.ocrText?.prefix(300).description]
            .compactMap { $0 }.joined(separator: " · ")
        attributes.keywords = (item.labels ?? []).map(Subjects.title) + (item.entities ?? []).map(\.name) + (item.colors ?? [])
        attributes.thumbnailURL = library.thumbnailURL(item)
        attributes.contentCreationDate = item.dateAdded
        attributes.url = item.url.flatMap(URL.init(string:))
        return CSSearchableItem(uniqueIdentifier: item.id.uuidString, domainIdentifier: item.kind.rawValue, attributeSet: attributes)
    }
}
