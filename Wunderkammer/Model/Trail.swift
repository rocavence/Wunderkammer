import Foundation

/// The path through the cabinet: what was looked at, and how you got there
/// (a search, something similar, a name, chance). Feeds "足跡" and lets the
/// Inspector say how you arrived. Kept beside the library, last 5,000 steps.
@MainActor
final class Trail {
    enum Via: Codable, Equatable, Sendable {
        case browse
        case search(String)
        case similar(UUID)
        case related(UUID)
        case random
        case mentions(String)
        case site(String)
        case theme(String)
        /// Followed a relation from another curiosity ("Wong Kar-Wai", "提到 Ole Worm", "New York").
        case relation(UUID, String)
        /// What an answer to a question was about.
        case ask(String)
    }

    struct Step: Codable, Equatable, Sendable {
        var date: Date
        var item: UUID
        var via: Via
    }

    private let url: URL
    private(set) var steps: [Step] = []
    private var saveWork: DispatchWorkItem?

    init(root: URL) {
        url = root.appendingPathComponent("trail.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([Step].self, from: data) { steps = s }
    }

    func record(_ item: UUID, via: Via, at date: Date = Date()) {
        // Opening the same thing twice in a row is one visit.
        if let last = steps.last, last.item == item, date.timeIntervalSince(last.date) < 60 { return }
        steps.append(Step(date: date, item: item, via: via))
        if steps.count > 5000 { steps.removeFirst(steps.count - 5000) }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func save() {
        if let data = try? JSONEncoder().encode(steps) { try? data.write(to: url, options: .atomic) }
    }

    /// Most recently looked at first, each once.
    func recentItems(existing: Set<UUID>) -> [UUID] {
        var seen = Set<UUID>()
        return steps.reversed().compactMap { step in
            guard existing.contains(step.item), seen.insert(step.item).inserted else { return nil }
            return step.item
        }
    }

    func lastArrival(at item: UUID) -> Step? { steps.last { $0.item == item } }

    /// Sittings: steps closer than `gap` belong together. Newest sitting
    /// first, each in the order it happened; removed curiosities left out.
    func visits(existing: Set<UUID>, gap: TimeInterval = 30 * 60) -> [[Step]] {
        var out: [[Step]] = []
        for step in steps where existing.contains(step.item) {
            if let last = out.last?.last, step.date.timeIntervalSince(last.date) <= gap {
                out[out.count - 1].append(step)
            } else {
                out.append([step])
            }
        }
        return out.reversed()
    }

    /// How you got to `item` last time: that sitting, from its start up to it.
    func path(to item: UUID, existing: Set<UUID>, limit: Int = 6) -> [Step] {
        for visit in visits(existing: existing) {
            if let i = visit.lastIndex(where: { $0.item == item }) {
                return Array(visit[...i].suffix(limit))
            }
        }
        return []
    }

    /// A few words for the arrow into a step: "相似", "搜尋「receive」", "Wong Kar-Wai".
    static func short(_ via: Via) -> String {
        switch via {
        case .browse: "瀏覽"
        case .search(let q): "搜尋「\(q)」"
        case .similar: "相似"
        case .related: "相關"
        case .random: "隨機"
        case .mentions(let name): "提到 \(name)"
        case .site(let domain): domain
        case .theme(let t): "主題 \(t)"
        case .relation(_, let label): label
        case .ask(let q): "問「\(q.prefix(16))」"
        }
    }

    /// "上次是從搜尋「receive」來的".
    static func describe(_ via: Via, title: (UUID) -> String?) -> String {
        switch via {
        case .browse: "上次是瀏覽時看到的"
        case .search(let q): "上次是從搜尋「\(q)」來的"
        case .similar(let id): "上次是從「\(title(id) ?? "另一件收藏")」的相似收藏來的"
        case .related(let id): "上次是從「\(title(id) ?? "另一件收藏")」的相關收藏來的"
        case .random: "上次是隨機遇到的"
        case .mentions(let name): "上次是從提到「\(name)」的收藏來的"
        case .site(let domain): "上次是從 \(domain) 的收藏來的"
        case .theme(let t): "上次是從主題「\(t)」來的"
        case .relation(let id, let label): "上次是從「\(title(id) ?? "另一件收藏")」經由 \(label) 來的"
        case .ask(let q): "上次是從問題「\(q)」來的"
        }
    }
}
