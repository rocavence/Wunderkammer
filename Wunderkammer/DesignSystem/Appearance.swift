import AppKit

extension NSView {
    /// A dynamic colour (labelColor, windowBackgroundColor…) as it looks in this
    /// view right now. CALayers take a fixed CGColor, so layer colours have to
    /// be resolved against the view's appearance and redone when it changes.
    func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}
