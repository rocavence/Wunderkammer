import CoreGraphics
import Foundation

/// The cabinet as a world of connections: themes, names and sites are nodes;
/// two of them are linked when the same curiosities belong to both.
struct CultureGraph {
    enum Kind: Sendable { case theme, name, site }

    struct Node: Identifiable {
        var id: String
        var title: String
        var kind: Kind
        var items: [UUID]
        var position: CGPoint = .zero

        var base: Scope.Base {
            switch kind {
            case .theme: .subject(String(id.dropFirst(6)))
            case .name: .mentions(title)
            case .site: .site(title)
            }
        }
    }

    struct Edge {
        var a: Int
        var b: Int
        var weight: Int
    }

    var nodes: [Node]
    var edges: [Edge]

    /// Themes (from Subjects), names on ≥ 2 items, sites with ≥ 2 items. The
    /// most connected `limit` nodes are kept.
    static func build(from items: [Item], subjects: [Subjects.Subject], limit: Int = 40) -> CultureGraph {
        var nodes: [Node] = subjects.map { s in
            Node(id: "theme:\(s.label)", title: s.title, kind: .theme,
                 items: items.filter { $0.labels?.contains(s.label) == true }.map(\.id))
        }
        var names: [String: (title: String, items: [UUID])] = [:]
        var sites: [String: [UUID]] = [:]
        for item in items {
            for e in Set((item.entities ?? []).map(\.name)) {
                let key = e.lowercased()
                names[key, default: (e, [])].items.append(item.id)
            }
            if let d = item.domain { sites[d, default: []].append(item.id) }
        }
        nodes += names.filter { $0.value.items.count >= 2 }.map { Node(id: "name:\($0.key)", title: $0.value.title, kind: .name, items: $0.value.items) }
        nodes += sites.filter { $0.value.count >= 2 }.map { Node(id: "site:\($0.key)", title: $0.key, kind: .site, items: $0.value) }

        // Only the biggest candidates are worth pairing up (edges are O(n²)).
        if nodes.count > limit * 2 {
            nodes = Array(nodes.sorted { ($0.items.count, $1.id) > ($1.items.count, $0.id) }.prefix(limit * 2))
        }
        func edges(of nodes: [Node]) -> [Edge] {
            let sets = nodes.map { Set($0.items) }
            var out: [Edge] = []
            for i in nodes.indices {
                for j in nodes.indices where j > i {
                    let w = sets[i].intersection(sets[j]).count
                    if w > 0 { out.append(Edge(a: i, b: j, weight: w)) }
                }
            }
            return out
        }
        // Keep the best-connected nodes (ties: bigger first, then by name for stability).
        if nodes.count > limit {
            let degree = edges(of: nodes).reduce(into: [Int: Int]()) { $0[$1.a, default: 0] += $1.weight; $0[$1.b, default: 0] += $1.weight }
            nodes = nodes.indices.sorted {
                (degree[$0] ?? 0, nodes[$0].items.count, nodes[$1].id) > (degree[$1] ?? 0, nodes[$1].items.count, nodes[$0].id)
            }.prefix(limit).map { nodes[$0] }
        }
        nodes.sort { $0.id < $1.id }
        // A node sharing nothing with any other says nothing on a map of
        // relations (and drifts off to a corner): left out, unless nothing connects.
        let linked = edges(of: nodes).reduce(into: Set<Int>()) { $0.insert($1.a); $0.insert($1.b) }
        if !linked.isEmpty { nodes = nodes.indices.filter(linked.contains).map { nodes[$0] } }
        // A pair talking only to each other, apart from everything else, reads as
        // debris next to the main web: kept only when there's no main web.
        let pieces = Self.components(nodes.count, edges(of: nodes))
        if let biggest = pieces.map(\.count).max(), biggest >= 3 {
            let keep = Set(pieces.filter { $0.count >= 3 }.flatMap { $0 })
            nodes = nodes.indices.filter(keep.contains).map { nodes[$0] }
        }
        return CultureGraph(nodes: nodes, edges: edges(of: nodes))
    }

    private static func components(_ n: Int, _ edges: [Edge]) -> [[Int]] {
        var parent = Array(0..<n)
        func root(_ i: Int) -> Int { var r = i; while parent[r] != r { r = parent[r] }; return r }
        for e in edges { parent[root(e.a)] = root(e.b) }
        return Dictionary(grouping: 0..<n, by: root).values.map { $0 }
    }

    /// Force-directed placement (Fruchterman–Reingold), deterministic: the
    /// same cabinet always draws the same map.
    mutating func layout(size: CGSize = CGSize(width: 1600, height: 1100), iterations: Int = 400) {
        let n = nodes.count
        guard n > 0 else { return }
        let area = size.width * size.height
        let k = (area / CGFloat(n)).squareRoot() * 0.6
        // Start on a circle so the result doesn't depend on randomness.
        for i in nodes.indices {
            let angle = CGFloat(i) / CGFloat(n) * 2 * .pi
            nodes[i].position = CGPoint(x: size.width / 2 + cos(angle) * size.width * 0.35,
                                        y: size.height / 2 + sin(angle) * size.height * 0.35)
        }
        var temperature = size.width / 8
        for _ in 0..<iterations {
            var shift = [CGVector](repeating: .zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<max(n, i + 1) where j < n {
                    var dx = nodes[i].position.x - nodes[j].position.x, dy = nodes[i].position.y - nodes[j].position.y
                    var d = (dx * dx + dy * dy).squareRoot()
                    if d < 0.01 { dx = 0.01; dy = 0; d = 0.01 }
                    let f = k * k / d
                    shift[i].dx += dx / d * f; shift[i].dy += dy / d * f
                    shift[j].dx -= dx / d * f; shift[j].dy -= dy / d * f
                }
            }
            for e in edges {
                let dx = nodes[e.a].position.x - nodes[e.b].position.x, dy = nodes[e.a].position.y - nodes[e.b].position.y
                let d = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let f = d * d / k * (1 + log(CGFloat(e.weight)))
                shift[e.a].dx -= dx / d * f; shift[e.a].dy -= dy / d * f
                shift[e.b].dx += dx / d * f; shift[e.b].dy += dy / d * f
            }
            for i in 0..<n {
                // A gentle pull to the middle keeps loose nodes from drifting off.
                shift[i].dx += (size.width / 2 - nodes[i].position.x) * 0.02
                shift[i].dy += (size.height / 2 - nodes[i].position.y) * 0.02
                let len = max((shift[i].dx * shift[i].dx + shift[i].dy * shift[i].dy).squareRoot(), 0.01)
                nodes[i].position.x += shift[i].dx / len * min(len, temperature)
                nodes[i].position.y += shift[i].dy / len * min(len, temperature)
                nodes[i].position.x = min(max(nodes[i].position.x, 0), size.width)
                nodes[i].position.y = min(max(nodes[i].position.y, 0), size.height)
            }
            temperature = max(temperature * 0.985, 1)
        }
    }
}
