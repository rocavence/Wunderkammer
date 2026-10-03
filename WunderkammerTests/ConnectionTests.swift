import Foundation
import Testing
@testable import Wunderkammer

@MainActor
struct ConnectionTests {
    @Test func namesAndSitesConnectItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-lib-\(UUID().uuidString)")
        let library = Library(root: root)
        let ids = await library.capture([
            .text("In the Mood for Love, with Tony Leung.", origin: URL(string: "https://www.example.com/a")),
            .text("2046 — Tony Leung again.", origin: URL(string: "https://example.com/b")),
            .text("Chungking Express", origin: URL(string: "https://other.org/c")),
        ])
        #expect(ids.count == 3)
        library.update(ids[0], notify: false) { $0.entities = [Item.Entity(kind: .person, name: "Tony Leung")] }
        library.update(ids[1], notify: false) { $0.entities = [Item.Entity(kind: .person, name: "tony leung")] }
        #expect(Set(library.items(for: Scope(base: .mentions("Tony Leung"))).map(\.id)) == Set(ids.prefix(2)))
        #expect(Set(library.items(for: Scope(base: .site("example.com"))).map(\.id)) == Set(ids.prefix(2)))
        #expect(library.items(for: Scope(base: .site("other.org"))).map(\.id) == [ids[2]])
    }
}
