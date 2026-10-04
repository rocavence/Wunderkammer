import Foundation

/// The cabinets (珍奇室) on this Mac: each a library of its own, named by its
/// owner and switched in a moment. The first one is the library that was
/// always there, where it always was; new ones get a folder of their own.
@MainActor
final class Cabinets {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        /// Relative to the base folder; "" is the base itself (the original library).
        var folder: String
    }

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
            entries = stored.entries
            currentID = stored.entries.contains { $0.id == stored.current } ? stored.current : stored.entries[0].id
        } else {
            let first = Entry(id: UUID(), name: "珍奇室", folder: "")
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

    func select(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        currentID = id
        save()
    }

    private static func clean(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未命名珍奇室" : String(t.prefix(40))
    }

    private func save() {
        let file = base.appendingPathComponent("cabinets.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(entries: entries, current: currentID)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
