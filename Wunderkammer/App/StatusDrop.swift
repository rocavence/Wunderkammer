import AppKit

/// The menu bar icon: the app's arch, drawn in line. Anything dragged onto it
/// (files, pictures, links, text) is collected; while something is held over
/// it the arch fills in, so you know letting go will take it; whenever
/// something is collected, its doorway lights up Rams orange for a moment.
@MainActor
final class StatusDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    /// Collects what was dropped; false when there was nothing it could use.
    var onDrop: ((NSPasteboard) -> Bool)?

    private weak var button: NSStatusBarButton?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: Library.didCapture, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.glow() }
        }
    }

    /// An arch, ∩, as a menu bar template: outlined, or filled while a drop
    /// hovers. Lit, it's outlined in the menu bar's ink with Rams orange inside.
    /// `side`: drawn smaller elsewhere (the sidebar's foot), the same shape.
    static func arch(filled: Bool, lit: Bool = false, side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let scale = NSAffineTransform()
            scale.scale(by: side / 18)
            scale.concat()
            let w: CGFloat = 11, legs: CGFloat = 4, top: CGFloat = 14.5, inset = (18 - w) / 2
            let r = w / 2
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset, y: legs))
            path.line(to: NSPoint(x: inset, y: top - r))
            path.appendArc(withCenter: NSPoint(x: 9, y: top - r), radius: r, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: 18 - inset, y: legs))
            if lit {
                let inside = path.copy() as! NSBezierPath
                inside.close()
                Accent.orange.color.set()
                inside.fill()
            }
            (lit ? NSColor.labelColor : .black).set()
            if filled {
                path.close()
                path.fill()
            } else {
                path.lineWidth = 3.4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = !lit
        image.accessibilityDescription = "Wunder"
        return image
    }

    /// Something was collected: the doorway lights up orange for a moment.
    func glow() {
        isLit = true
        button?.image = Self.arch(filled: false, lit: true)
        glowEnds?.cancel()
        let end = DispatchWorkItem { [weak self] in
            self?.isLit = false
            self?.button?.image = Self.arch(filled: false)
        }
        glowEnds = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: end)
    }

    private var glowEnds: DispatchWorkItem?
    private(set) var isLit = false

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
