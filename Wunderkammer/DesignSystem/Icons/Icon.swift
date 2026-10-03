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
}
