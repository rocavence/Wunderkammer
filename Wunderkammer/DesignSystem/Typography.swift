import AppKit

enum Typography {
    /// The display face for titles: New York for Latin, and for Chinese the
    /// PingFang the rest of the interface uses — left to the system, serif
    /// Chinese falls back to Songti, which titles shouldn't wear.
    static func display(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont? {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return nil }
        let chinese = NSFontDescriptor(name: weight >= .medium ? "PingFangTC-Medium" : "PingFangTC-Regular", size: size)
        return NSFont(descriptor: serif.addingAttributes([.cascadeList: [chinese]]), size: size)
    }
}
