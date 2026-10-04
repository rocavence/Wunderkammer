import AppKit
import ImageIO
import PDFKit
import Quartz

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
    /// Shown above the pile when the system made it (sorted by theme).
    var title: String?
}

/// A line drawn between two curiosities on a canvas.
struct CanvasLink: Codable, Hashable {
    var a: UUID
    var b: UUID
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
    /// Saved copies of web pages.
    let archivesDir: URL
    private(set) var items: [Item] = []
    private(set) var collections: [Board] = []
    private var canvases: [String: [CanvasGroup]] = [:]
    private var canvasLinks: [String: [CanvasLink]] = [:]
    private var byID: [UUID: Int] = [:]
    /// Visually similar items, supplied by the understanding layer.
    var similarity: ((UUID) -> [Item])?
    /// The trail's most recent items, newest first.
    var recentlyViewed: (() -> [UUID])?
    /// Set while the app is sending changes in quick succession (enrichment).
    private var saveWork: DispatchWorkItem?

    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wunderkammer")

    init(root: URL = defaultRoot) {
        self.root = root
        originalsDir = root.appendingPathComponent("originals")
        thumbnailsDir = root.appendingPathComponent("thumbnails")
        archivesDir = root.appendingPathComponent("archives")
        for dir in [originalsDir, thumbnailsDir, archivesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    private var jsonURL: URL { root.appendingPathComponent("library.json") }

    private struct Stored: Codable {
        var items: [Item]
        var collections: [Board]?
        var canvases: [String: [CanvasGroup]]?
        var links: [String: [CanvasLink]]?
    }

    /// Set when library.json exists but couldn't be read: nothing gets purged,
    /// and the unreadable file is kept beside it.
    private(set) var loadFailed = false

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL) else { return }
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            loadFailed = true
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.copyItem(at: jsonURL, to: root.appendingPathComponent("library-unreadable-\(stamp).json"))
            NSLog("Wunderkammer: library.json could not be read (%@); kept a copy, nothing purged", String(describing: error))
            return
        }
        backUp(data)
        items = stored.items
        collections = stored.collections ?? []
        canvases = stored.canvases ?? [:]
        canvasLinks = stored.links ?? [:]
        reindex()
    }

    /// One copy of library.json per day in backups/, the last 7 kept.
    private func backUp(_ data: Data) {
        let dir = root.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let file = dir.appendingPathComponent("library-\(f.string(from: Date())).json")
        if !FileManager.default.fileExists(atPath: file.path) { try? data.write(to: file) }
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("library-") }.sorted()
        for old in all.dropLast(7) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }

    func save() {
        saveWork?.cancel()
        saveWork = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Stored(items: items, collections: collections, canvases: canvases, links: canvasLinks)) {
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
        var seen = Set<UUID>()
        return collection(collectionID)?.itemIDs.filter { seen.insert($0).inserted }.compactMap(item) ?? []
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
        var seen = Set(collections[i].itemIDs)
        // The same item can come back twice (two identical photos in one folder).
        let new = ids.filter { byID[$0] != nil && seen.insert($0).inserted }
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
    /// What a removal took away, to put back exactly that and nothing else.
    struct Removal {
        var items: [(index: Int, item: Item)]
        /// Board → (position, item) the removed items had.
        var memberships: [UUID: [(index: Int, id: UUID)]]
    }

    /// Takes items out of the cabinet. Nothing is deleted from disk: a
    /// referenced file was never ours, and our own copies stay until the next
    /// launch so the removal can be undone. Canvas piles and connections keep
    /// their entries (they're filtered when read), so undo brings those back too.
    @discardableResult
    func delete(_ ids: Set<UUID>) -> Removal? {
        let doomed = items.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, item: $0.element) }
        guard !doomed.isEmpty else { return nil }
        var memberships: [UUID: [(index: Int, id: UUID)]] = [:]
        for board in collections {
            let hits = board.itemIDs.enumerated().filter { ids.contains($0.element) }.map { (index: $0.offset, id: $0.element) }
            if !hits.isEmpty { memberships[board.id] = hits }
        }
        items.removeAll { ids.contains($0.id) }
        for i in collections.indices { collections[i].itemIDs.removeAll { ids.contains($0) } }
        reindex()
        changed()
        return Removal(items: doomed, memberships: memberships)
    }

    /// Puts the removed items back, into the boards that still exist, without
    /// undoing anything else done since.
    func restore(_ removal: Removal) {
        // Something collected again since the removal stands in for the old one.
        var stand: [UUID: UUID] = [:]
        let hashes = Dictionary(items.map { ($0.contentHash, $0.id) }, uniquingKeysWith: { a, _ in a })
        for (index, item) in removal.items.sorted(by: { $0.index < $1.index }) where byID[item.id] == nil {
            if let again = hashes[item.contentHash] {
                stand[item.id] = again
                continue
            }
            items.insert(item, at: min(index, items.count))
        }
        for (boardID, entries) in removal.memberships {
            guard let b = collections.firstIndex(where: { $0.id == boardID }) else { continue }
            for (index, original) in entries.sorted(by: { $0.index < $1.index }) {
                let id = stand[original] ?? original
                guard !collections[b].itemIDs.contains(id) else { continue }
                collections[b].itemIDs.insert(id, at: min(index, collections[b].itemIDs.count))
            }
        }
        reindex()
        changed()
    }

    /// Our own copies and thumbnails nothing refers to any more (removed in an
    /// earlier session). Run at launch.
    func purgeOrphans() {
        // If the library couldn't be read, every file would look orphaned.
        guard !loadFailed else { return }
        // Canvas piles and links kept removed items for undo; a new session can't undo.
        for key in canvases.keys {
            canvases[key] = canvases[key]?.map { var g = $0; g.itemIDs.removeAll { byID[$0] == nil }; return g }.filter { !$0.itemIDs.isEmpty }
        }
        for key in canvasLinks.keys { canvasLinks[key]?.removeAll { byID[$0.a] == nil || byID[$0.b] == nil } }
        let keep = Set(items.compactMap(\.storedFilename))
        let ids = Set(items.map(\.id.uuidString))
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: originalsDir.path)) ?? [] where !keep.contains(file) {
            try? fm.removeItem(at: originalsDir.appendingPathComponent(file))
        }
        let archives = Set(items.compactMap(\.archiveFilename))
        for file in (try? fm.contentsOfDirectory(atPath: archivesDir.path)) ?? [] where !archives.contains(file) {
            try? fm.removeItem(at: archivesDir.appendingPathComponent(file))
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

    /// Lines between items on a canvas, minus any whose ends are gone.
    func links(key: String) -> [CanvasLink] {
        (canvasLinks[key] ?? []).filter { byID[$0.a] != nil && byID[$0.b] != nil }
    }

    /// Saves the visible links, keeping those hidden because one end was
    /// removed (an undo brings them back).
    func setLinks(_ links: [CanvasLink], key: String) {
        let hidden = (canvasLinks[key] ?? []).filter { byID[$0.a] == nil || byID[$0.b] == nil }
        canvasLinks[key] = hidden + links.filter { !hidden.contains($0) }
        save()
    }

    /// Canvas edits don't post didChange: the canvas already shows them.
    /// Removed items stay in the pile they were in (hidden), so ⌘Z puts them
    /// back there even if the canvas was rearranged meanwhile.
    func setCanvasGroups(_ groups: [CanvasGroup], key: String) {
        var groups = groups
        let shown = Set(groups.flatMap(\.itemIDs))
        for old in canvases[key] ?? [] {
            let hidden = old.itemIDs.filter { byID[$0] == nil && !shown.contains($0) }
            guard !hidden.isEmpty else { continue }
            if let i = groups.firstIndex(where: { $0.id == old.id }) {
                groups[i].itemIDs += hidden
            } else if !groups.isEmpty {
                groups[0].itemIDs += hidden
            }
        }
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
        // Another capture may have brought the same content in meanwhile.
        var current: [String: UUID] = [:]
        for item in items { current[item.contentHash] = item.id }
        for outcome in outcomes {
            switch outcome {
            case .new(let item):
                if let existing = current[item.contentHash] {
                    ids.append(existing)
                } else {
                    added.append(item)
                    current[item.contentHash] = item.id
                    ids.append(item.id)
                }
            case .duplicate(let hash):
                if let id = current[hash] { ids.append(id) }
            }
        }
        if !added.isEmpty {
            items.insert(contentsOf: added, at: 0)
            reindex()
            changed()
        }
        // Even if the board went away during a long import, the items are saved above.
        if let collectionID, !ids.isEmpty { add(ids, to: collectionID) }
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
                // No preview image of its own: a picture of the page itself.
                picture = await WebSnapshot.capture(url)
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
                $0.creator = meta.credits.first(where: { $0.role != .brand && $0.role != .actor })?.name ?? meta.author ?? meta.siteName ?? $0.creator
                $0.thing = meta.thing ?? $0.thing
                if !meta.credits.isEmpty { $0.credits = meta.credits }
                $0.released = meta.released ?? $0.released
                $0.locality = meta.locality ?? $0.locality
                $0.webDataVersion = WebMetadata.version
                $0.entities = Item.merging($0.entities ?? [], credits: $0.credits)
                $0.createdDate = meta.published ?? $0.createdDate
                if let finalPicture {
                    $0.pixelWidth = finalPicture.width
                    $0.pixelHeight = finalPicture.height
                    $0.representationVersion = version
                    $0.analysisVersion = 0 // look again at the real picture
                }
            }
            await self.archive(id)
        }
    }

    /// Pages read before WebMetadata learned more: what they are, who made
    /// them, where; the picture stays as it is.
    func refreshWebData() async {
        let ids = items.filter { $0.kind == .web && ($0.webDataVersion ?? 0) < WebMetadata.version }.map(\.id)
        for id in ids {
            guard let url = item(id)?.url.flatMap(URL.init(string:)), let meta = await WebMetadata.fetch(url), !meta.isImage else {
                update(id, notify: false) { $0.webDataVersion = WebMetadata.version }
                continue
            }
            update(id, notify: false) {
                $0.thing = meta.thing ?? $0.thing
                if !meta.credits.isEmpty { $0.credits = meta.credits }
                $0.released = meta.released ?? $0.released
                $0.locality = meta.locality ?? $0.locality
                $0.entities = Item.merging($0.entities ?? [], credits: $0.credits)
                $0.webDataVersion = WebMetadata.version
            }
        }
        if !ids.isEmpty { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    func archiveURL(_ item: Item) -> URL? {
        item.archiveFilename.map { archivesDir.appendingPathComponent($0) }
    }

    /// Keeps the page as it is now (a PDF of all of it, and its words), so the
    /// curiosity outlives the link.
    func archive(_ id: UUID) async {
        guard let item = item(id), item.kind == .web, item.archiveFilename == nil,
              let url = item.url.flatMap(URL.init(string:)) else { return }
        let saved = await WebSnapshot.archive(url)
        let name = id.uuidString + ".pdf"
        let dir = archivesDir
        let written = await Task.detached { () -> Bool in
            guard let saved else { return false }
            let file = dir.appendingPathComponent(name)
            guard (try? saved.pdf.write(to: file, options: .atomic)) != nil else { return false }
            Self.shrink(file)
            return true
        }.value
        update(id, notify: false) {
            $0.archivedAt = Date()
            guard written else { return }
            $0.archiveFilename = name
            $0.pageText = saved?.text.map { String($0.prefix(4000)) }
        }
    }

    /// Pages collected before cookie notices were cleared off their pictures
    /// get their picture and saved copy once more, once.
    func redoWebPictures() {
        let key = "webPictures.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let ids = items.filter { $0.kind == .web }.map(\.id)
        for id in ids {
            update(id, notify: false) { $0.archiveFilename = nil; $0.archivedAt = nil }
            enrichWeb(id)
        }
    }

    /// Pictures in a saved page are kept at screen quality, the text as text:
    /// macOS's own "Reduce File Size" (20 MB → 4 MB on an image-heavy page).
    nonisolated static func shrink(_ file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 1_000_000, let doc = PDFDocument(url: file),
              let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) else { return }
        let smaller = file.deletingLastPathComponent().appendingPathComponent(".shrinking-" + file.lastPathComponent)
        guard doc.write(to: smaller, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]),
              let newSize = try? FileManager.default.attributesOfItem(atPath: smaller.path)[.size] as? Int,
              newSize < size,
              // The words survive (a character or two of whitespace may not).
              Double(PDFDocument(url: smaller)?.string?.count ?? 0) >= Double(doc.string?.count ?? 0) * 0.98 else {
            try? FileManager.default.removeItem(at: smaller)
            return
        }
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: smaller)
    }

    /// Pages saved before they were made smaller, once.
    func shrinkArchives() {
        let key = "archivesShrunk.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let files = items.compactMap(archiveURL)
        Task.detached(priority: .utility) {
            for file in files { Self.shrink(file) }
            await MainActor.run { UserDefaults.standard.set(true, forKey: key) }
        }
    }

    /// Pages not kept yet, one at a time in the background: collected before
    /// pages were kept, or a site that said no (tried again a day later).
    func archiveMissing(now: Date = Date()) {
        let ids = items.filter {
            $0.kind == .web && $0.archiveFilename == nil && ($0.archivedAt.map { now.timeIntervalSince($0) > 86_400 } ?? true)
        }.map(\.id)
        guard !ids.isEmpty else { return }
        Task { for id in ids { await archive(id) } }
    }

    /// Referenced files copied into the library, so they stay even if the
    /// original is moved or deleted. The original's path is kept.
    func copyIntoLibrary(_ ids: [UUID]) async {
        for id in ids {
            guard let item = item(id), item.storedFilename == nil, let source = originalURL(item) else { continue }
            let ext = source.pathExtension
            let name = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
            let target = originalsDir.appendingPathComponent(name)
            let copied = await Task.detached { (try? FileManager.default.copyItem(at: source, to: target)) != nil }.value
            if copied { update(id) { $0.storedFilename = name } }
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
            $0.analysisVersion = 0
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
