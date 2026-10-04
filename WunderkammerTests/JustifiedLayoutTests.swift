import CoreGraphics
import Testing
@testable import Wunderkammer

struct JustifiedLayoutTests {
    let layout = JustifiedLayout(width: 1000, rowHeight: 200, spacing: 10, inset: 20)

    @Test func fullRowsFillTheWidth() {
        let result = layout.layout(aspects: Array(repeating: 1.5, count: 10))
        let firstRow = result.frames.filter { $0.minY == result.frames[0].minY }
        #expect(firstRow.count > 1)
        #expect(abs(firstRow.last!.maxX - 980) < 0.001)
        #expect(firstRow.allSatisfy { $0.height >= 200 })
    }

    /// Like Atlas: rows only stretch up from the target, never shrink below it,
    /// except a lone image wider than the row.
    @Test func rowsAreNeverShorterThanTheTarget() {
        let aspects = (0..<200).map { CGFloat(1 + ($0 % 7)) / 3 }
        let result = layout.layout(aspects: aspects)
        for (frame, aspect) in zip(result.frames, aspects) where aspect * 200 <= 960 {
            #expect(frame.height >= 200 - 0.001)
        }
        let panorama = layout.layout(aspects: [1, 8, 1])
        #expect(abs(panorama.frames[1].width - 960) < 0.001)
    }

    @Test func keepsAspectRatio() {
        let result = layout.layout(aspects: [0.5, 2, 1, 1.5, 0.75])
        for (frame, aspect) in zip(result.frames, [0.5, 2, 1, 1.5, 0.75] as [CGFloat]) {
            #expect(abs(frame.width / frame.height - aspect) < 0.001)
        }
    }

    @Test func lastRowIsNotStretched() {
        let result = layout.layout(aspects: Array(repeating: 1.5, count: 5))
        // Three items only reach 920 of 960 at height 200; the fourth overflows,
        // so four fill the first row and the fifth sits alone at the target height.
        #expect(result.frames.last!.height == 200)
        #expect(result.frames.last!.width == 300)
    }

    @Test func rowsDoNotOverlap() {
        let result = layout.layout(aspects: (0..<200).map { CGFloat(1 + ($0 % 7)) / 3 })
        for (a, b) in zip(result.frames, result.frames.dropFirst()) {
            #expect(b.minY > a.minY || b.minX >= a.maxX)
        }
        #expect(result.height == result.frames.map(\.maxY).max()! + 20)
    }

    @Test func emptyLibrary() {
        #expect(layout.layout(aspects: []).height == 0)
    }
}
