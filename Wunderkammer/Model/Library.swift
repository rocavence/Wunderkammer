import AppKit
import ImageIO

struct Board: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var itemIDs: [UUID]
    var dateCreated: Date
}

/// A pile on the canvas. Its items are packed automatically; only the pile's
/// top-left corner is stored.
struct CanvasGroup: Codable, Identifiable, Hashable {
    var id: UUID
    var x: CGFloat
    var y: CGFloat
    var itemIDs: [UUID]
}

/// The cabinet: every curiosity, the optional boards, canvas layouts. Lives in
/// ~/Library/Application Support/Wunderkammer as library.json plus
/// originals/ (only content with no file of its own) and thumbnails/ (the
/// representations). Referenced files stay where they are.
@MainActor
final class Library {
    static let didChange = Notification.Name("LibraryDidChange")
    nonisolated static let thumbnailSize = Representer.thumbnailSize
    /// Canvas key for the whole cabinet, which isn't a real board.
    nonisolated static let allKey = "all"

    let root: URL
    let originalsDir: URL
    let thumbnailsDir: URL
    private(set) var items: [Item] = []
    private(set) var collections: [Board] = []
    private var canvases: [String: [CanvasGroup]] = [:]
    private var byID: [UUID: Int] = [:]
    /// Set while the app is sending changes in quick succession (enrichment).
    private var saveWork: DispatchWorkItem?

    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wunderkammer")

    init(root: URL = defaultRoot) {
        self.root = root
        originalsDir = root.appendingPathComponent("originals")
        thumbnailsDir = root.appendingPathComponent("thumbnails")
        for dir in [originalsDir, thumbnailsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    private var jsonURL: URL { root.appendingPathComponent("library.json") }

    private struct Stored: Codable {
        var items: [Item]
        var collections: [Board]?
        var canvases: [String: [CanvasGroup]]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        items = stored.items
        collections = stored.collections ?? []
        canvases = stored.canvases ?? [:]
        reindex()
    }

    func save() {
        saveWork?.cancel()
        saveWork = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Stored(items: items, collections: collections, canvases: canvases)) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    /// Coalesces bursts of small updates into one write.
    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func reindex() {
        byID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    func item(_ id: UUID) -> Item? { byID[id].map { items[$0] } }

    /// The content itself, wherever it lives. nil for web pages and text, and
    /// for files that have since disappeared.
    func originalURL(_ item: Item) -> URL? {
        if let stored = item.storedFilename { return originalsDir.appendingPathComponent(stored) }
        guard let path = item.filePath else { return nil }
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        // Moved or renamed: follow the bookmark and remember the new place.
        var stale = false
        if let bookmark = item.fileBookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
           FileManager.default.fileExists(atPath: url.path) {
            update(item.id, notify: false) { $0.filePath = url.path }
            return url
        }
        return nil
    }

    /// Where the item can be opened: its file, or its page.
    func openURL(_ item: Item) -> URL? {
        originalURL(item) ?? item.url.flatMap(URL.init(string:))
    }

    func thumbnailURL(_ item: Item) -> URL {
        Representer.thumbnailURL(thumbnailsDir, id: item.id, version: item.representationVersion)
    }

    /// Changes one item in place. `notify` re-renders the views.
    func update(_ id: UUID, notify: Bool = true, _ change: (inout Item) -> Void) {
        guard let i = byID[id] else { return }
        change(&items[i])
        saveSoon()
        if notify { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    func markViewed(_ id: UUID) {
        update(id, notify: false) {
            $0.viewCount += 1
            $0.lastViewed = Date()
        }
    }

    // MARK: Boards

    func collection(_ id: UUID) -> Board? { collections.first { $0.id == id } }

    /// Items shown for a board, or the whole cabinet for nil.
    func items(in collectionID: UUID?) -> [Item] {
        guard let collectionID else { return items }
        return collection(collectionID)?.itemIDs.compactMap(item) ?? []
    }

    @discardableResult
    func createCollection(named name: String, with ids: [UUID] = []) -> Board {
        let c = Board(id: UUID(), name: name, itemIDs: ids, dateCreated: Date())
        collections.append(c)
        changed()
        return c
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let i = collections.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        collections[i].name = name
        changed()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        canvases[id.uuidString] = nil
        changed()
    }

    /// Adds to the front, keeping the dragged order; already-present items stay put.
    func add(_ ids: [UUID], to collectionID: UUID) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        let existing = Set(collections[i].itemIDs)
        let new = ids.filter { !existing.contains($0) && byID[$0] != nil }
        guard !new.isEmpty else { return }
        collections[i].itemIDs.insert(contentsOf: new, at: 0)
        changed()
    }

    func remove(_ ids: Set<UUID>, from collectionID: UUID) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[i].itemIDs.removeAll { ids.contains($0) }
        changed()
    }

    // MARK: Removing (undoable)

    /// Everything needed to put removed items back exactly as they were.
    struct Removal {
        var items: [(index: Int, item: Item)]
        var collections: [Board]
        var canvases: [String: [CanvasGroup]]
    }

    /// Takes items out of the cabinet. Nothing is deleted from disk: a
    /// referenced file was never ours, and our own copies stay until the next
    /// launch so the removal can be undone.
    @discardableResult
    func delete(_ ids: Set<UUID>) -> Removal? {
        let doomed = items.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, item: $0.element) }
        guard !doomed.isEmpty else { return nil }
        let removal = Removal(items: doomed, collections: collections, canvases: canvases)
        items.removeAll { ids.contains($0.id) }
        for i in collections.indices { collections[i].itemIDs.removeAll { ids.contains($0) } }
        reindex()
        changed()
        return removal
    }

    func restore(_ removal: Removal) {
        for (index, item) in removal.items.sorted(by: { $0.index < $1.index }) where byID[item.id] == nil {
            items.insert(item, at: min(index, items.count))
        }
        collections = removal.collections
        canvases = removal.canvases
        reindex()
        changed()
    }

    /// Our own copies and thumbnails nothing refers to any more (removed in an
    /// earlier session). Run at launch.
    func purgeOrphans() {
        let keep = Set(items.compactMap(\.storedFilename))
        let ids = Set(items.map(\.id.uuidString))
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: originalsDir.path)) ?? [] where !keep.contains(file) {
            try? fm.removeItem(at: originalsDir.appendingPathComponent(file))
        }
        let current = Set(items.map { thumbnailURL($0).lastPathComponent })
        for file in (try? fm.contentsOfDirectory(atPath: thumbnailsDir.path)) ?? [] where !current.contains(file) {
            // Old versions of a current item's representation, or removed items.
            let id = String(file.prefix(36))
            if !ids.contains(id) || !current.contains(file) {
                try? fm.removeItem(at: thumbnailsDir.appendingPathComponent(file))
            }
        }
    }

    // MARK: Canvas

    static func canvasKey(_ collectionID: UUID?) -> String { collectionID?.uuidString ?? allKey }

    /// The stored piles for a view, reconciled with the items it shows now:
    /// missing items are dropped, new ones join the first pile (or a fresh one).
    func canvasGroups(key: String, ids: [UUID]) -> [CanvasGroup] {
        let valid = Set(ids)
        var groups = canvases[key] ?? []
        for g in groups.indices { groups[g].itemIDs.removeAll { !valid.contains($0) } }
        groups.removeAll { $0.itemIDs.isEmpty }
        let placed = Set(groups.flatMap(\.itemIDs))
        let loose = ids.filter { !placed.contains($0) }
        if !loose.isEmpty {
            if groups.isEmpty {
                groups.append(CanvasGroup(id: UUID(), x: 0, y: 0, itemIDs: loose))
            } else {
                groups[0].itemIDs.insert(contentsOf: loose, at: 0)
            }
        }
        return groups
    }

    func canvasGroups(for collectionID: UUID?) -> [CanvasGroup] {
        canvasGroups(key: Self.canvasKey(collectionID), ids: items(in: collectionID).map(\.id))
    }

    /// Canvas edits don't post didChange: the canvas already shows them.
    func setCanvasGroups(_ groups: [CanvasGroup], key: String) {
        canvases[key] = groups
        save()
    }

    // MARK: Capture

    private var context: Representer.Context {
        Representer.Context(originalsDir: originalsDir, thumbnailsDir: thumbnailsDir, sourceApp: nil)
    }

    /// Turns sources into curiosities, newest first. Something already in the
    /// cabinet isn't added twice, but its ID is still returned so it can join
    /// a board. Folders become their contents.
    @discardableResult
    func capture(_ sources: [Source], into collectionID: UUID? = nil, sourceApp: String? = nil) async -> [UUID] {
        var known: [String: UUID] = [:]
        for item in items { known[item.contentHash] = item.id }
        var context = context
        context.sourceApp = sourceApp
        let hashes = Set(known.keys)
        let expanded: [Source] = sources.flatMap { source -> [Source] in
            if case .file(let url) = source { return Representer.expand(url).map { .file($0) } }
            return [source]
        }
        let ctx = context
        let outcomes = await Task.detached(priority: .userInitiated) {
            var results: [Representer.Outcome] = []
            var seen = hashes
            for source in expanded {
                guard let outcome = await Representer.ingest(source, context: ctx, known: seen) else { continue }
                if case .new(let item) = outcome { seen.insert(item.contentHash) }
                results.append(outcome)
            }
            return results
        }.value

        var ids: [UUID] = []
        var added: [Item] = []
        for outcome in outcomes {
            switch outcome {
            case .new(let item):
                added.append(item)
                ids.append(item.id)
            case .duplicate(let hash):
                if let id = known[hash] ?? added.first(where: { $0.contentHash == hash })?.id { ids.append(id) }
            }
        }
        if !added.isEmpty {
            items.insert(contentsOf: added, at: 0)
            reindex()
        }
        if let collectionID, !ids.isEmpty {
            add(ids, to: collectionID) // posts the change
        } else if !added.isEmpty {
            changed()
        }
        for item in added where item.kind == .web { enrichWeb(item.id) }
        if !added.isEmpty { NotificationCenter.default.post(name: Self.didCapture, object: self, userInfo: ["ids": added.map(\.id)]) }
        return ids
    }

    static let didCapture = Notification.Name("LibraryDidCapture")

    @discardableResult
    func importFiles(_ urls: [URL], into collectionID: UUID? = nil) async -> [UUID] {
        await capture(urls.map { .file($0) }, into: collectionID)
    }

    @discardableResult
    func importImageData(_ data: Data, suggestedName: String, into collectionID: UUID? = nil) async -> [UUID] {
        await capture([.imageData(data, name: suggestedName, origin: nil)], into: collectionID)
    }

    // MARK: Enrichment

    /// Fetches the page and replaces the placeholder card with the page's own
    /// preview image, title and description. A link straight to an image
    /// becomes that image.
    func enrichWeb(_ id: UUID) {
        // Only ever fetch web addresses, whatever ended up in the item.
        guard let item = item(id), let url = item.url.flatMap(URL.init(string:)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let context = context
        Task {
            guard let meta = await WebMetadata.fetch(url) else { return }
            if meta.isImage, let data = await WebMetadata.imageData(url) {
                await self.becomeImage(id, data: data, origin: url, context: context)
                return
            }
            let version = item.representationVersion + 1
            var picture: CGImage?
            if let imageURL = meta.imageURL {
                picture = await WebMetadata.image(imageURL, maxPixel: Representer.cardSize)
            }
            if picture == nil {
                var icon: CGImage?
                if let iconURL = meta.iconURL { icon = await WebMetadata.image(iconURL, maxPixel: 64) }
                picture = CardRenderer.web(title: meta.title ?? item.displayTitle, domain: item.domain ?? "",
                                           description: meta.description, favicon: icon)
            }
            let finalPicture = picture
            await Task.detached { Representer.writeThumbnail(finalPicture, id, context, version: version) }.value
            self.update(id) {
                $0.title = $0.title ?? meta.title
                if meta.title != nil, $0.title == $0.domain { $0.title = meta.title }
                $0.text = meta.description ?? $0.text
                $0.creator = meta.author ?? meta.siteName ?? $0.creator
                $0.createdDate = meta.published ?? $0.createdDate
                if let finalPicture {
                    $0.pixelWidth = finalPicture.width
                    $0.pixelHeight = finalPicture.height
                    $0.representationVersion = version
                }
            }
        }
    }

    private func becomeImage(_ id: UUID, data: Data, origin: URL, context: Representer.Context) async {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let current = item(id) else { return }
        let ext = origin.pathExtension.isEmpty ? "jpg" : origin.pathExtension.lowercased()
        let stored = id.uuidString + "." + ext
        let version = current.representationVersion + 1
        await Task.detached {
            try? data.write(to: context.originalsDir.appendingPathComponent(stored))
            Representer.writeThumbnail(Thumbnailer.decode(source: source, maxPixel: Representer.thumbnailSize), id, context, version: version)
        }.value
        update(id) {
            $0.kind = .image
            $0.storedFilename = stored
            $0.originalFilename = origin.lastPathComponent
            $0.pixelWidth = w
            $0.pixelHeight = h
            $0.representationVersion = version
            $0.contentHash = Representer.sha256(data)
        }
    }

    // MARK: Atlas

    static let atlasRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atlas")

    /// Brings in every original from an Atlas library. Returns how many were new.
    func importFromAtlas() async -> Int {
        let originals = Self.atlasRoot.appendingPathComponent("originals")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: originals, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        // Atlas encodes items as a flat [id, item, id, item, …] array.
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: Self.atlasRoot.appendingPathComponent("library.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let flat = json["items"] as? [Any] {
            for case let entry as [String: Any] in flat {
                if let stored = entry["storedFilename"] as? String,
                   let original = entry["originalFilename"] as? String {
                    names[stored] = original
                }
            }
        }
        // Atlas's storage isn't a place the user manages, so keep our own copy.
        let sources: [Source] = files.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return .imageData(data, name: names[file.lastPathComponent] ?? file.lastPathComponent, origin: nil)
        }
        let before = items.count
        await capture(sources)
        return items.count - before
    }
}
