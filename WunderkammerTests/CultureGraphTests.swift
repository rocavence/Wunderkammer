import CoreGraphics
import Foundation
import Testing
@testable import Wunderkammer

struct CultureGraphTests {
    private func item(labels: [String] = [], names: [String] = [], url: String? = nil) -> Item {
        var i = Item(kind: .image, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: UUID().uuidString)
        i.labels = labels
        i.entities = names.map { Item.Entity(kind: .person, name: $0) }
        i.url = url
        return i
    }

    @Test func nodesAndSharedItemEdges() {
        let a = item(labels: ["cat"], names: ["Tony Leung"], url: "https://film.example/a")
        let b = item(labels: ["cat"], names: ["tony leung"], url: "https://film.example/b")
        let c = item(labels: ["cat"], url: "https://other.example/c")
        let lonely = item(names: ["Nobody"])
        let subjects = [Subjects.Subject(label: "cat", title: "貓", count: 3)]
        let g = CultureGraph.build(from: [a, b, c, lonely], subjects: subjects)
        #expect(Set(g.nodes.map(\.id)) == ["theme:cat", "name:tony leung", "site:film.example"])
        // theme–name share a and b; theme–site share a and b; name–site share a and b.
        #expect(g.edges.count == 3 && g.edges.allSatisfy { $0.weight == 2 })
        #expect(g.nodes.first { $0.kind == .theme }?.base == .subject("cat"))
        #expect(g.nodes.first { $0.kind == .name }?.base == .mentions("Tony Leung"))
    }

    @Test func layoutIsDeterministicAndSpreadOut() {
        let items = (0..<12).map { i in item(labels: ["l\(i % 4)", "l\((i + 1) % 4)"]) }
        let subjects = (0..<4).map { Subjects.Subject(label: "l\($0)", title: "L\($0)", count: 6) }
        var g1 = CultureGraph.build(from: items, subjects: subjects)
        var g2 = g1
        g1.layout(); g2.layout()
        #expect(g1.nodes.map(\.position) == g2.nodes.map(\.position))
        let p = g1.nodes.map(\.position)
        for i in p.indices { for j in p.indices where j > i { #expect(hypot(p[i].x - p[j].x, p[i].y - p[j].y) > 80) } }
    }
}
