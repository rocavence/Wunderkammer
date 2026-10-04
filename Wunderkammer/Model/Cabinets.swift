import Foundation

/// The cabinets (珍奇櫃) on this Mac: each a library of its own, named by its
/// owner and switched in a moment. The first one is the library that was
/// always there, where it always was; new ones get a folder of their own.
@MainActor
final class Cabinets {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        /// Relative to the base folder; "" is the base itself (the original library).
        var folder: String
        /// Folders whose files come in by themselves (and leave with them).
        var watched: [String]? = nil
    }

    static let maxWatched = 3

    private struct Stored: Codable {
        var entries: [Entry]
        var current: UUID
    }

    let base: URL
    private(set) var entries: [Entry]
    private(set) var currentID: UUID

    init(base: URL) {
        self.base = base
        let file = base.appendingPathComponent("cabinets.json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
           !stored.entries.isEmpty {
            // The default name was 珍奇室 before it became 珍奇櫃.
            entries = stored.entries.map { e in
                var e = e
                if e.name == "珍奇室" { e.name = "珍奇櫃" } else if e.name == "未命名珍奇室" { e.name = "未命名珍奇櫃" }
                return e
            }
            currentID = stored.entries.contains { $0.id == stored.current } ? stored.current : stored.entries[0].id
        } else {
            let first = Entry(id: UUID(), name: "珍奇櫃", folder: "")
            entries = [first]
            currentID = first.id
            save()
        }
    }

    var current: Entry { entries.first { $0.id == currentID } ?? entries[0] }

    func root(of entry: Entry) -> URL {
        entry.folder.isEmpty ? base : base.appendingPathComponent(entry.folder, isDirectory: true)
    }

    @discardableResult
    func create(named name: String) -> Entry {
        let id = UUID()
        let entry = Entry(id: id, name: Self.clean(name), folder: "Cabinets/\(id.uuidString)")
        try? FileManager.default.createDirectory(at: root(of: entry), withIntermediateDirectories: true)
        entries.append(entry)
        save()
        return entry
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), !Self.clean(name).isEmpty else { return }
        entries[i].name = Self.clean(name)
        save()
    }

    /// The original library (it holds the others) and the open one stay.
    func canDelete(_ id: UUID) -> Bool {
        guard let e = entries.first(where: { $0.id == id }) else { return false }
        return !e.folder.isEmpty && id != currentID
    }

    /// Out of the list, and its folder to the Trash (recoverable from there).
    func delete(_ id: UUID) {
        guard canDelete(id), let e = entries.first(where: { $0.id == id }) else { return }
        try? FileManager.default.trashItem(at: root(of: e), resultingItemURL: nil)
        entries.removeAll { $0.id == id }
        save()
    }

    func watched(_ id: UUID) -> [URL] {
        (entries.first { $0.id == id }?.watched ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Up to three folders, none twice, none inside another or inside a library.
    func canWatch(_ folder: URL, in id: UUID) -> Bool {
        let path = folder.standardizedFileURL.path
        let mine = watched(id).map(\.path)
        guard mine.count < Self.maxWatched else { return false }
        return !mine.contains { $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            && !base.standardizedFileURL.path.hasPrefix(path + "/") && !path.hasPrefix(base.standardizedFileURL.path)
    }

    @discardableResult
    func watch(_ folder: URL, in id: UUID) -> Bool {
        guard canWatch(folder, in: id), let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[i].watched = (entries[i].watched ?? []) + [folder.standardizedFileURL.path]
        save()
        return true
    }

    func unwatch(_ folder: URL, in id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].watched?.removeAll { $0 == folder.standardizedFileURL.path }
        save()
    }

    func select(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        currentID = id
        save()
    }

    private static func clean(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未命名珍奇櫃" : String(t.prefix(40))
    }

    private func save() {
        let file = base.appendingPathComponent("cabinets.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(entries: entries, current: currentID)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
