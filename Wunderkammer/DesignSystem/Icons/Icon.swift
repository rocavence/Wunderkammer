import AppKit

/// Wunderkammer 唯一的 icon 入口。所有 UI icon 都經過這裡，不直接用 SF Symbols。
enum Icon {
    enum Weight: String {
        /// 一般 UI
        case outline
        /// 選取中、主要動作
        case filled
    }

    /// Template image：顏色跟著控制項（選取、停用、深淺色）走。
    static func image(_ icon: Reicon, weight: Weight = .outline, size: CGFloat = 16) -> NSImage {
        let source = NSImage(named: "Reicon/\(icon.rawValue).\(weight.rawValue)") ?? NSImage()
        let image = source.copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = icon.rawValue
        return image
    }

    /// 視覺上等大的 icon：各 icon 的圖形在畫框裡留白不同，直接用同一個
    /// size 會有的大有的小。這裡量出實際筆畫的範圍，縮放到同樣大小再置中。
    /// `fill` 是筆畫範圍佔畫框的比例。
    @MainActor static func optical(_ icon: Reicon, weight: Weight = .outline, size: CGFloat = 20, fill: CGFloat = 0.8) -> NSImage {
        let key = "\(icon.rawValue).\(weight.rawValue).\(size).\(fill)"
        if let cached = opticalCache[key] { return cached }
        let source = image(icon, weight: weight, size: 96)
        let ink = inkBounds(source, side: 96) ?? CGRect(x: 0, y: 0, width: 96, height: 96)
        // Same footprint: the ink's average side, kept inside the frame.
        let side = (ink.width * ink.height).squareRoot()
        let nudge = opticalNudge[icon] ?? 1
        let scale = min(size * fill * nudge / max(side, 1), size / max(ink.width, ink.height, 1))
        let drawn = CGSize(width: 96 * scale, height: 96 * scale)
        let origin = CGPoint(x: size / 2 - ink.midX * scale, y: size / 2 - ink.midY * scale)
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            source.draw(in: CGRect(origin: origin, size: drawn))
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = icon.rawValue
        opticalCache[key] = result
        return result
    }

    @MainActor private static var opticalCache: [String: NSImage] = [:]

    /// Where equal area still doesn't look equal: a circle reads small, four
    /// corner arrows read big. Adjusted by eye.
    private static let opticalNudge: [Reicon: CGFloat] = [
        .infoCircle: 1.2,
        .search: 1.04,
        .maximize: 0.84,
    ]

    /// Where the drawing actually is, in a `side`-point square, bottom-up.
    private static func inkBounds(_ image: NSImage, side: Int) -> CGRect? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where data[y * side + x] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        // Rows in memory run top-down; flip to the image's bottom-up space.
        return CGRect(x: minX, y: side - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
