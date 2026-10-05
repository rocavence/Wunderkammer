import Foundation
import Testing
@testable import Wunderkammer

/// Two Macs sharing a 展室 through iCloud: nothing either did is lost.
struct LibrarySyncTests {
    private func item(_ title: String, added: TimeInterval = 0, modified: TimeInterval? = nil) -> Item {
        var i = Item(kind: .text, dateAdded: Date(timeIntervalSince1970: added), originalFilename: "", pixelWidth: 1, pixelHeight: 1,
                     contentHash: UUID().uuidString)
        i.title = title
        i.modified = modified.map { Date(timeIntervalSince1970: $0) }
        return i
    }

    @Test func whatEitherSideAddedStays() {
        let shared = item("shared", added: 1)
        let mine = item("mine", added: 2), theirs = item("theirs", added: 3)
        let merged = LibrarySync.merge(local: [mine, shared], remote: [theirs, shared], known: [shared.id])
        #expect(Set(merged.map(\.title)) == ["shared", "mine", "theirs"])
        #expect(merged.map(\.title) == ["theirs", "mine", "shared"])
    }

    @Test func whatEitherSideRemovedGoes() {
        let kept = item("kept"), goneThere = item("gone there"), goneHere = item("gone here")
        let known: Set<UUID> = [kept.id, goneThere.id, goneHere.id]
        let merged = LibrarySync.merge(local: [kept, goneThere], remote: [kept, goneHere], known: known)
        #expect(merged.map(\.title) == ["kept"])
    }

    @Test func theLaterEditWinsAndLookingAddsUp() {
        var here = item("old title", modified: 10)
        var there = here
        there.title = "new title"
        there.modified = Date(timeIntervalSince1970: 20)
        here.viewCount = 5
        there.viewCount = 2
        here.lastViewed = Date(timeIntervalSince1970: 30)
        let merged = LibrarySync.merge(local: [here], remote: [there], known: [here.id])
        #expect(merged.first?.title == "new title")
        #expect(merged.first?.viewCount == 5)
        #expect(merged.first?.lastViewed == Date(timeIntervalSince1970: 30))
    }

    @Test func boardsKeepWhatEitherPutIn() {
        let a = UUID(), b = UUID(), c = UUID()
        let here = Board(id: UUID(), name: "Moths", itemIDs: [a, b], dateCreated: Date())
        var there = here
        there.itemIDs = [a, c]
        let merged = LibrarySync.merge(local: [here], remote: [there], known: [here.id])
        #expect(merged.first?.itemIDs == [a, b, c])
    }

    /// The whole round: two libraries on one folder, as two Macs on one iCloud folder.
    @MainActor @Test func twoMacsOnOneFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = Library(root: root, syncs: true)
        first.addForTest(item("from the first Mac", added: 1))
        let second = Library(root: root, syncs: true)
        #expect(second.items.map(\.title) == ["from the first Mac"])
        second.addForTest(item("from the second Mac", added: 2))
        first.addForTest(item("first again", added: 3))
        first.mergeFromDisk()
        #expect(Set(first.items.compactMap(\.title)) == ["from the first Mac", "from the second Mac", "first again"])
        second.mergeFromDisk()
        #expect(second.items.count == 3)
    }
}
