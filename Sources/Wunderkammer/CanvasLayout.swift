import CoreGraphics

/// Canvas geometry in world units: how a pile packs its images, how piles
/// push each other apart, and the tidy "arrange" layout.
enum CanvasLayout {
    static let rowHeight: CGFloat = 160
    static let spacing: CGFloat = 8
    /// Minimum empty space kept between piles.
    static let gap: CGFloat = 56

    /// Packs a pile into a roughly 4:3 block. Frames are relative to the pile's top-left.
    static func pack(_ aspects: [CGFloat]) -> (frames: [CGRect], size: CGSize) {
        guard !aspects.isEmpty else { return ([], .zero) }
        let totalAspect = aspects.reduce(0, +)
        let widest = (aspects.max() ?? 1) * rowHeight
        // A block of n rows at rowHeight is ~totalAspect*h wide in one line; fold it to ~4:3.
        let width = max(widest, (totalAspect * rowHeight * rowHeight * 4 / 3).squareRoot())
        let result = JustifiedLayout(width: width, rowHeight: rowHeight, spacing: spacing, inset: 0)
            .layout(aspects: aspects)
        let maxX = result.frames.map(\.maxX).max() ?? 0
        return (result.frames, CGSize(width: maxX, height: result.height))
    }

    /// Pushes overlapping rects apart along the shorter overlap axis. `pinned`
    /// rects never move (the pile just dropped); everything else yields.
    static func separate(_ rects: [CGRect], pinned: Set<Int>) -> [CGRect] {
        var rects = rects
        for _ in 0..<64 {
            var moved = false
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let a = rects[i], b = rects[j]
                    let padded = a.insetBy(dx: -gap / 2, dy: -gap / 2)
                    guard padded.intersects(b.insetBy(dx: -gap / 2, dy: -gap / 2)) else { continue }
                    let iPinned = pinned.contains(i), jPinned = pinned.contains(j)
                    if iPinned && jPinned { continue }
                    // Who moves: the unpinned one; if both free, the later one.
                    let mover = jPinned ? i : j
                    let other = mover == i ? b : a
                    let m = rects[mover]

                    let pushRight = other.maxX + gap - m.minX
                    let pushLeft = m.maxX + gap - other.minX
                    let pushDown = other.maxY + gap - m.minY
                    let pushUp = m.maxY + gap - other.minY
                    let dx = m.midX >= other.midX ? pushRight : -pushLeft
                    let dy = m.midY >= other.midY ? pushDown : -pushUp
                    if abs(dx) <= abs(dy) {
                        rects[mover].origin.x += dx
                    } else {
                        rects[mover].origin.y += dy
                    }
                    moved = true
                }
            }
            if !moved { break }
        }
        return rects
    }

    /// Lays piles out left to right in rows (shelf packing), keeping their order.
    static func arrange(_ sizes: [CGSize], maxWidth: CGFloat) -> [CGPoint] {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return origins
    }
}
