import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct Item: Codable, Identifiable, Hashable {
    var id: UUID
    var originalFilename: String
    var storedFilename: String
    var pixelWidth: Int
    var pixelHeight: Int
    var contentHash: String
    var dateAdded: Date

    var aspect: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        // Clamp so panoramas and slivers don't wreck a row.
        return min(max(CGFloat(pixelWidth) / CGFloat(pixelHeight), 0.25), 4)
    }
}

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

/// On-disk library: library.json + originals/ + thumbnails/ under
/// ~/Library/Application Support/Wunderkammer.
@MainActor
final class Library {
    static let didChange = Notification.Name("LibraryDidChange")
    nonisolated static let thumbnailSize = 600
    /// Canvas key for "All Images", which isn't a real collection.
    static let allKey = "all"

    let root: URL
    let originalsDir: URL
    let thumbnailsDir: URL
    private(set) var items: [Item] = []
    private(set) var collections: [Board] = []
    private var canvases: [String: [CanvasGroup]] = [:]
    private var byID: [UUID: Int] = [:]

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

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Stored(items: items, collections: collections, canvases: canvases)) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func reindex() {
        byID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    func item(_ id: UUID) -> Item? { byID[id].map { items[$0] } }

    func originalURL(_ item: Item) -> URL { originalsDir.appendingPathComponent(item.storedFilename) }
    func thumbnailURL(_ item: Item) -> URL {
        thumbnailsDir.appendingPathComponent(item.id.uuidString + ".jpg")
    }

    // MARK: Collections

    func collection(_ id: UUID) -> Board? { collections.first { $0.id == id } }

    /// Items shown for a collection, or the whole library for nil.
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

    /// Deletes items everywhere and moves their files to the Trash.
    func delete(_ ids: Set<UUID>) {
        let doomed = items.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        for item in doomed {
            try? FileManager.default.trashItem(at: originalURL(item), resultingItemURL: nil)
            try? FileManager.default.removeItem(at: thumbnailURL(item))
        }
        items.removeAll { ids.contains($0.id) }
        for i in collections.indices { collections[i].itemIDs.removeAll { ids.contains($0) } }
        reindex()
        changed()
    }

    // MARK: Canvas

    static func canvasKey(_ collectionID: UUID?) -> String { collectionID?.uuidString ?? allKey }

    /// The stored piles, reconciled with the collection's current items: missing
    /// items are dropped, new ones join the first pile (or a fresh one).
    func canvasGroups(for collectionID: UUID?) -> [CanvasGroup] {
        let ids = items(in: collectionID).map(\.id)
        let valid = Set(ids)
        var groups = canvases[Self.canvasKey(collectionID)] ?? []
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

    /// Canvas edits don't post didChange: the canvas already shows them.
    func setCanvasGroups(_ groups: [CanvasGroup], for collectionID: UUID?) {
        canvases[Self.canvasKey(collectionID)] = groups
        save()
    }

    // MARK: Import

    /// Imports image files and folders. Duplicates (same content hash) aren't
    /// copied again, but their existing IDs are returned, so the caller can still
    /// add them to a collection. Returned in the order given.
    @discardableResult
    func importFiles(_ urls: [URL], into collectionID: UUID? = nil) async -> [UUID] {
        var known: [String: UUID] = [:]
        for item in items { known[item.contentHash] = item.id }
        let originalsDir = originalsDir, thumbnailsDir = thumbnailsDir
        let hashes = Set(known.keys)
        let results = await Task.detached(priority: .userInitiated) {
            Self.ingestAll(urls, known: hashes, originalsDir: originalsDir, thumbnailsDir: thumbnailsDir)
        }.value

        var ids: [UUID] = []
        var added: [Item] = []
        for result in results {
            switch result {
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
        return ids
    }

    /// Writes raw image data (paste, browser drag) to a temp file and imports it.
    @discardableResult
    func importImageData(_ data: Data, suggestedName: String, into collectionID: UUID? = nil) async -> [UUID] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        guard (try? data.write(to: tmp)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return await importFiles([tmp], into: collectionID)
    }

    nonisolated private enum Ingested: Sendable {
        case new(Item)
        case duplicate(String)
    }

    nonisolated private static func ingestAll(_ urls: [URL], known: Set<String>,
                                              originalsDir: URL, thumbnailsDir: URL) -> [Ingested] {
        var results: [Ingested] = []
        var seen = known
        for url in urls.flatMap(expand) {
            guard let result = ingest(url, originalsDir: originalsDir, thumbnailsDir: thumbnailsDir, skipping: seen)
            else { continue }
            if case .new(let item) = result { seen.insert(item.contentHash) }
            results.append(result)
        }
        return results
    }

    /// Folders become their image contents, recursively.
    nonisolated private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
    }

    nonisolated private static func ingest(_ url: URL, originalsDir: URL, thumbnailsDir: URL,
                                           skipping known: Set<String>) -> Ingested? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url) else { return nil }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !known.contains(hash) else { return .duplicate(hash) }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }

        // EXIF orientations 5–8 are rotated 90°, so the displayed size is swapped.
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }

        let id = UUID()
        let ext = url.pathExtension.lowercased()
        let stored = id.uuidString + "." + ext
        do {
            try data.write(to: originalsDir.appendingPathComponent(stored))
        } catch { return nil }

        if let thumb = Thumbnailer.decode(source: source, maxPixel: Library.thumbnailSize) {
            Thumbnailer.writeJPEG(thumb, to: thumbnailsDir.appendingPathComponent(id.uuidString + ".jpg"))
        }

        return .new(Item(id: id, originalFilename: url.lastPathComponent, storedFilename: stored,
                         pixelWidth: w, pixelHeight: h, contentHash: hash, dateAdded: Date()))
    }

    // MARK: Atlas

    static let atlasRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atlas")

    /// Imports every original from an Atlas library. Returns how many were new.
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
        // Copy under the original filename so it survives into our library.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("wk-atlas-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var staged: [URL] = []
        for (i, file) in files.enumerated() {
            let name = names[file.lastPathComponent] ?? file.lastPathComponent
            let dir = staging.appendingPathComponent(String(format: "%05d", i))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(name)
            if (try? FileManager.default.copyItem(at: file, to: dest)) != nil { staged.append(dest) }
        }
        let before = items.count
        await importFiles(staged)
        return items.count - before
    }
}
