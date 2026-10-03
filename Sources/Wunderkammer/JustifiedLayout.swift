import CoreGraphics

/// Justified rows: every row fills the full width, images keep their aspect
/// ratio, row heights hover around `rowHeight`. The last row isn't stretched.
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

        for i in aspects.indices {
            aspectSum += aspects[i]
            let count = i - rowStart + 1
            let gaps = spacing * CGFloat(count - 1)
            // Height that makes this row exactly fill the width.
            let fitHeight = (usable - gaps) / aspectSum
            if fitHeight <= rowHeight {
                place(rowStart..<(i + 1), height: fitHeight)
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
