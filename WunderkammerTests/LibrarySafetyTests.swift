import AppKit
import Foundation
import Testing
@testable import Wunderkammer

/// Regressions from the code review: nothing may be lost or crash.
@MainActor
struct LibrarySafetyTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wk-safety-\(UUID().uuidString)")
    }

    private func png(_ seed: Int) -> Data {
        // Different sizes, so every seed is different content.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8 + seed, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(NSColor(white: CGFloat(seed % 255) / 255, alpha: 1), atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func unreadableLibraryPurgesNothing() async throws {
        let root = tempRoot()
        let first = Library(root: root)
        await first.capture([.imageData(png(1), name: "a.png", origin: nil)])
        let originals = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path)
        #expect(originals.count == 1)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("library.json"))
        let broken = Library(root: root)
        #expect(broken.loadFailed)
        broken.purgeOrphans()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path) == originals)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("library-unreadable-") })
    }

    @Test func unknownKindStillLoads() throws {
        let json = """
        {"items":[{"id":"5274D7AA-79C2-4FCD-B575-51C23FA7DF5B","kind":"hologram","originalFilename":"x","pixelWidth":1,"pixelHeight":1,"contentHash":"h","dateAdded":800000000}]}
        """
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))
        let library = Library(root: root)
        #expect(!library.loadFailed && library.items.first?.kind == .file)
    }

    @Test func undoOnlyPutsBackWhatWasRemoved() async {
        let library = Library(root: tempRoot())
        let ids = await library.capture([.imageData(png(2), name: "a.png", origin: nil), .imageData(png(3), name: "b.png", origin: nil)])
        let board = library.createCollection(named: "A", with: ids)
        guard let removal = library.delete([ids[0]]) else { Issue.record("nothing removed"); return }
        let later = library.createCollection(named: "Later", with: [ids[1]])
        library.renameCollection(board.id, to: "A renamed")
        library.restore(removal)
        #expect(library.item(ids[0]) != nil)
        #expect(library.collection(later.id) != nil, "a board made after the removal survives the undo")
        #expect(library.collection(board.id)?.name == "A renamed")
        #expect(library.collection(board.id)?.itemIDs == ids, "the item is back in its place in its board")
    }

    @Test func sameItemTwiceNeverDuplicatesABoard() async {
        let library = Library(root: tempRoot())
        let data = png(4)
        let ids = await library.capture([.imageData(data, name: "a.png", origin: nil), .imageData(data, name: "copy.png", origin: nil)])
        #expect(ids.count == 2 && ids[0] == ids[1])
        let board = library.createCollection(named: "B")
        library.add(ids, to: board.id)
        library.add(ids, to: board.id)
        #expect(library.collection(board.id)?.itemIDs.count == 1)
        // Searching inside the board must not trap on duplicates.
        #expect(library.items(for: Scope(base: .board(board.id), search: "a")).count <= 1)
    }

    @Test func concurrentCapturesOfTheSameContentAddItOnce() async {
        let library = Library(root: tempRoot())
        let data = png(5)
        async let a = library.capture([.imageData(data, name: "a.png", origin: nil)])
        async let b = library.capture([.imageData(data, name: "b.png", origin: nil)])
        let (x, y) = await (a, b)
        #expect(library.items.count == 1 && x == y)
    }
}
