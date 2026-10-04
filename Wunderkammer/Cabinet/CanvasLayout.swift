import CoreGraphics
import Foundation

/// Canvas geometry in world units: how a pile packs its images, how piles
/// push each other apart, and the tidy "arrange" layout.
enum CanvasLayout {
    static let rowHeight: CGFloat = 160
    static let spacing: CGFloat = 8
    /// Minimum empty space kept between piles.
    static let gap: CGFloat = 80

    /// Packs a pile into a roughly 4:3 block. Frames are relative to the pile's top-left.
    static func pack(_ aspects: [CGFloat]) -> (frames: [CGRect], size: CGSize) {
        guard !aspects.isEmpty else { return ([], .zero) }
        let totalAspect = aspects.reduce(0, +)
        let widest = (aspects.max() ?? 1) * rowHeight
        // A block of n rows at rowHeight is ~totalAspect*h wide in one line; fold it to ~4:3.
        let width = max(widest, (totalAspect * rowHeight * rowHeight * 4 / 3).squareRoot())
        let result = JustifiedLayout(width: width, rowHeight: rowHeight, spacing: spacing, inset: 0)
            .layout(aspects: aspects)
        let maxX = result.frames.map(\.maxX).max() ?? 0
        return (result.frames, CGSize(width: maxX, height: result.height))
    }

    /// Pushes overlapping rects apart along the shorter overlap axis. `pinned`
    /// rects never move (the pile just dropped); everything else yields.
    static func separate(_ rects: [CGRect], pinned: Set<Int>) -> [CGRect] {
        var rects = rects
        for _ in 0..<64 {
            var moved = false
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let a = rects[i], b = rects[j]
                    let padded = a.insetBy(dx: -gap / 2, dy: -gap / 2)
                    guard padded.intersects(b.insetBy(dx: -gap / 2, dy: -gap / 2)) else { continue }
                    let iPinned = pinned.contains(i), jPinned = pinned.contains(j)
                    if iPinned && jPinned { continue }
                    // Who moves: the unpinned one; if both free, the later one.
                    let mover = jPinned ? i : j
                    let other = mover == i ? b : a
                    let m = rects[mover]

                    let pushRight = other.maxX + gap - m.minX
                    let pushLeft = m.maxX + gap - other.minX
                    let pushDown = other.maxY + gap - m.minY
                    let pushUp = m.maxY + gap - other.minY
                    let dx = m.midX >= other.midX ? pushRight : -pushLeft
                    let dy = m.midY >= other.midY ? pushDown : -pushUp
                    if abs(dx) <= abs(dy) {
                        rects[mover].origin.x += dx
                    } else {
                        rects[mover].origin.y += dy
                    }
                    moved = true
                }
            }
            if !moved { break }
        }
        return rects
    }

    /// Lays piles out left to right in rows (shelf packing), keeping their order.
    static func arrange(_ sizes: [CGSize], maxWidth: CGFloat) -> [CGPoint] {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return origins
    }

    /// Sorting a canvas by theme: each item goes to its most specific theme
    /// (the least common one it has); the rest by kind. Biggest piles first.
    static func clusters(_ items: [Item], subjects: [Subjects.Subject]) -> [(title: String, ids: [UUID])] {
        let rank = Dictionary(uniqueKeysWithValues: subjects.map { ($0.label, $0.count) })
        var piles: [String: [UUID]] = [:]
        var order: [String] = []
        for item in items {
            let theme = (item.labels ?? []).filter { rank[$0] != nil }.min { rank[$0]! < rank[$1]! }
            let title = theme.map(Subjects.title) ?? Self.kindTitle(item.kind)
            if piles[title] == nil { order.append(title) }
            piles[title, default: []].append(item.id)
        }
        return order.map { ($0, piles[$0]!) }.sorted { $0.ids.count > $1.ids.count }
    }

    /// Sorting a canvas by relation: things connected (the same person, a
    /// mention, the same city) share a pile, named by what connects most of
    /// them; the rest stay together. Biggest piles first.
    static func relationClusters(_ items: [Item], links: [(a: UUID, b: UUID, label: String)]) -> [(title: String, ids: [UUID])] {
        var parent = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.id) })
        func root(_ id: UUID) -> UUID {
            var r = id
            while let p = parent[r], p != r { r = p }
            return r
        }
        for link in links where parent[link.a] != nil && parent[link.b] != nil {
            parent[root(link.a)] = root(link.b)
        }
        var members: [UUID: [UUID]] = [:]
        for item in items { members[root(item.id), default: []].append(item.id) }
        var piles: [(title: String, ids: [UUID])] = []
        var rest: [UUID] = []
        for ids in members.values {
            guard ids.count > 1 else { rest += ids; continue }
            let inside = Set(ids)
            let labels = links.filter { inside.contains($0.a) }.map(\.label)
            // A shared person or city names a pile better than a mention.
            let title = Dictionary(grouping: labels, by: { $0 }).max { a, b in
                (Relation.mentioned(in: a.key) == nil ? 1 : 0, a.value.count) < (Relation.mentioned(in: b.key) == nil ? 1 : 0, b.value.count)
            }.map { Relation.mentioned(in: $0.key) ?? $0.key } ?? String(localized: "相關")
            piles.append((title, ids))
        }
        piles.sort { $0.ids.count > $1.ids.count }
        if !rest.isEmpty { piles.append((otherPile, items.map(\.id).filter(Set(rest).contains))) }
        return piles
    }

    /// The last pile, of what nothing connects.
    static let otherPile = String(localized: "其他")

    static func kindTitle(_ kind: Item.Kind) -> String {
        switch kind {
        case .image: String(localized: "其他圖片")
        case .video, .audio: String(localized: "影片與聲音")
        case .pdf, .file: String(localized: "文件與檔案")
        case .web: String(localized: "網頁")
        case .text: String(localized: "文字")
        }
    }
}
