import CoreGraphics

/// Justified rows: every row fills the full width, images keep their aspect
/// ratio, rows are `rowHeight` or a little taller. The last row isn't stretched.
struct JustifiedLayout {
    var width: CGFloat
    var rowHeight: CGFloat
    var spacing: CGFloat = 8
    var inset: CGFloat = 16

    struct Result {
        var frames: [CGRect]
        var height: CGFloat
    }

    func layout(aspects: [CGFloat]) -> Result {
        var frames = [CGRect](repeating: .zero, count: aspects.count)
        let usable = max(width - inset * 2, 1)
        var y = inset
        var rowStart = 0
        var aspectSum: CGFloat = 0

        func place(_ range: Range<Int>, height: CGFloat) {
            var x = inset
            for i in range {
                let w = aspects[i] * height
                frames[i] = CGRect(x: x, y: y, width: w, height: height)
                x += w + spacing
            }
            y += height + spacing
        }

        // Height that makes rowStart..<end exactly fill the width.
        func fitHeight(_ end: Int, _ sum: CGFloat) -> CGFloat {
            (usable - spacing * CGFloat(end - rowStart - 1)) / sum
        }
        for i in aspects.indices {
            // Like Atlas, rows only stretch up from the target: when this image
            // would squeeze the row below it, the row ends just before it.
            if i > rowStart, fitHeight(i + 1, aspectSum + aspects[i]) < rowHeight {
                place(rowStart..<i, height: fitHeight(i, aspectSum))
                rowStart = i
                aspectSum = 0
            }
            aspectSum += aspects[i]
            // A lone image wider than the row fills it on its own.
            if i == rowStart, fitHeight(i + 1, aspectSum) < rowHeight {
                place(i..<(i + 1), height: fitHeight(i + 1, aspectSum))
                rowStart = i + 1
                aspectSum = 0
            }
        }
        if rowStart < aspects.count {
            place(rowStart..<aspects.count, height: rowHeight)
        }
        let height = aspects.isEmpty ? 0 : y - spacing + inset
        return Result(frames: frames, height: height)
    }
}
