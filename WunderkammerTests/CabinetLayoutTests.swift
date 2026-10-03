import CoreGraphics
import Foundation
import Testing
@testable import Wunderkammer

struct CabinetLayoutTests {
    @Test func masonryFillsColumnsShortestFirst() {
        let layout = CabinetLayout(style: .masonry, width: 1000, size: 200, spacing: 10, inset: 20)
        let r = layout.layout(aspects: [1, 0.5, 2, 1, 1])
        // (960 + 10) / 210 → 4 columns of (960 - 30) / 4 = 232.5
        let xs = Set(r.frames.map(\.minX))
        #expect(xs.count == 4)
        #expect(r.frames.allSatisfy { abs($0.width - 232.5) < 0.001 })
        // The fifth goes under the shortest of the first four (the wide one, aspect 2).
        #expect(r.frames[4].minX == r.frames[2].minX)
        for (f, a) in zip(r.frames, [1, 0.5, 2, 1, 1] as [CGFloat]) { #expect(abs(f.width / f.height - a) < 0.001) }
        #expect(r.height == r.frames.map(\.maxY).max()! + 20)
    }

    @Test func timelineGroupsByDayWithHeadings() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9))!
        let today = now, yesterday = now.addingTimeInterval(-86400), old = cal.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!
        let layout = CabinetLayout(style: .timeline, width: 1000, size: 200)
        let r = layout.layout(aspects: [1, 1, 1.5, 1], dates: [today, today, yesterday, old], calendar: cal, now: now)
        #expect(r.headers.map(\.title) == ["今天", "昨天", "2025 年 3 月 8 日"])
        // Items sit below their own heading and above the next one.
        #expect(r.frames[0].minY > r.headers[0].frame.maxY)
        #expect(r.frames[2].minY > r.headers[1].frame.maxY && r.frames[1].maxY < r.headers[1].frame.minY)
        #expect(r.frames[3].minY > r.headers[2].frame.maxY)
    }

    @Test func spatialIndexMatchesBruteForce() {
        let r = CabinetLayout(style: .masonry, width: 900, size: 150).layout(aspects: (0..<300).map { CGFloat(1 + ($0 * 7) % 5) / 3 })
        let index = SpatialIndex(r.frames)
        for y in stride(from: 0, to: r.height, by: 137) {
            let rect = CGRect(x: 0, y: y, width: 900, height: 400)
            #expect(index.indices(in: rect) == r.frames.indices.filter { r.frames[$0].intersects(rect) })
        }
    }
}
