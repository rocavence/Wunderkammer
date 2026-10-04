import AppKit

/// The menu bar icon: the app's arch, drawn in line. Anything dragged onto it
/// (files, pictures, links, text) is collected; while something is held over
/// it the arch fills in, so you know letting go will take it.
@MainActor
final class StatusDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    /// Collects what was dropped; false when there was nothing it could use.
    var onDrop: ((NSPasteboard) -> Bool)?

    private weak var button: NSStatusBarButton?

    /// An arch, ∩, as a menu bar template: outlined, or filled while a drop hovers.
    static func arch(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let w: CGFloat = 11, legs: CGFloat = 3, top: CGFloat = 15.5, inset = (18 - w) / 2
            let r = w / 2
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset, y: legs))
            path.line(to: NSPoint(x: inset, y: top - r))
            path.appendArc(withCenter: NSPoint(x: 9, y: top - r), radius: r, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: 18 - inset, y: legs))
            NSColor.black.set()
            if filled {
                path.close()
                path.fill()
            } else {
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wunderkammer"
        return image
    }

    /// Takes drops on the status item's button. The status item's window hands
    /// its dragging messages to its delegate, which is this.
    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.image = Self.arch(filled: false)
        button.window?.registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff, .html, .rtf])
        button.window?.delegate = self
    }

    private func hovering(_ on: Bool) {
        button?.image = Self.arch(filled: on)
        button?.highlight(on)
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hovering(true)
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    func draggingExited(_ sender: (any NSDraggingInfo)?) { hovering(false) }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        hovering(false)
        return onDrop?(sender.draggingPasteboard) ?? false
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { hovering(false) }
}
