import CoreGraphics
import Foundation
import Testing
@testable import Wunderkammer

struct CanvasLayoutTests {
    @Test func packKeepsAspectAndStaysCompact() {
        let aspects: [CGFloat] = Array(repeating: 1.5, count: 12)
        let (frames, size) = CanvasLayout.pack(aspects)
        for f in frames { #expect(abs(f.width / f.height - 1.5) < 0.001) }
        // Roughly 4:3, not one long strip.
        #expect(size.width / size.height < 3)
        #expect(size.width / size.height > 0.6)
        #expect(frames.allSatisfy { $0.maxX <= size.width + 0.001 && $0.maxY <= size.height + 0.001 })
    }

    @Test func packSingleImage() {
        let (frames, size) = CanvasLayout.pack([2])
        #expect(frames.count == 1)
        #expect(abs(size.width - 2 * CanvasLayout.rowHeight) < 0.001)
    }

    @Test func separateLeavesNoOverlapAndKeepsPinned() {
        let rects = [
            CGRect(x: 0, y: 0, width: 400, height: 300),
            CGRect(x: 100, y: 50, width: 400, height: 300),
            CGRect(x: 200, y: 100, width: 200, height: 200),
            CGRect(x: 900, y: 0, width: 100, height: 100),
        ]
        let out = CanvasLayout.separate(rects, pinned: [1])
        #expect(out[1] == rects[1])
        for i in out.indices {
            for j in out.indices where j > i {
                #expect(!out[i].insetBy(dx: -CanvasLayout.gap / 2 + 0.5, dy: -CanvasLayout.gap / 2 + 0.5)
                    .intersects(out[j].insetBy(dx: -CanvasLayout.gap / 2 + 0.5, dy: -CanvasLayout.gap / 2 + 0.5)))
            }
        }
        // Sizes never change.
        #expect(zip(out, rects).allSatisfy { $0.size == $1.size })
    }

    @Test func separateDoesNothingWhenApart() {
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 300, y: 0, width: 100, height: 100)]
        #expect(CanvasLayout.separate(rects, pinned: []) == rects)
    }

    @Test func arrangeWrapsRows() {
        let sizes = Array(repeating: CGSize(width: 300, height: 200), count: 5)
        let origins = CanvasLayout.arrange(sizes, maxWidth: 1000)
        #expect(origins[0] == .zero)
        #expect(origins[1].y == 0)
        // 300 + 56 + 300 + 56 + 300 = 1012 > 1000, so the third pile wraps.
        #expect(origins[2].y > 0)
        #expect(origins[2].x == 0)
        #expect(origins[3].y == origins[2].y)
    }
}

struct SelectionTests {
    let order = (0..<6).map { _ in UUID() }

    @Test func clickShiftCommand() {
        var s = Selection()
        s.click(order[1], .none, order: order)
        #expect(s.ids == [order[1]])
        s.click(order[4], .extend, order: order)
        #expect(s.ids == Set(order[1...4]))
        s.click(order[2], .toggle, order: order)
        #expect(!s.ids.contains(order[2]))
        s.click(nil, .none, order: order)
        #expect(s.ids.isEmpty)
    }

    @Test func emptyClickWithModifierKeepsSelection() {
        var s = Selection()
        s.click(order[0], .none, order: order)
        s.click(nil, .toggle, order: order)
        #expect(s.ids == [order[0]])
    }
}

struct CanvasClusterTests {
    @Test func itemsGoToTheirMostSpecificTheme() {
        func item(_ labels: [String], kind: Item.Kind = .image) -> Item {
            var i = Item(kind: kind, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: UUID().uuidString)
            i.labels = labels
            return i
        }
        let cat = item(["people", "cat"]), person = item(["people"]), web = item([], kind: .web), text = item(["sign"], kind: .text)
        let subjects = [Subjects.Subject(label: "people", title: "人物", count: 8), Subjects.Subject(label: "cat", title: "貓", count: 3)]
        let piles = CanvasLayout.clusters([cat, person, web, text], subjects: subjects)
        let byTitle = Dictionary(uniqueKeysWithValues: piles.map { ($0.title, $0.ids) })
        #expect(byTitle["貓"] == [cat.id])          // cat is rarer than people
        #expect(byTitle["人物"] == [person.id])
        #expect(byTitle["網頁"] == [web.id] && byTitle["文字"] == [text.id])
    }
}
