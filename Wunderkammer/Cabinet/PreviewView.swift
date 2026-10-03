import AppKit
import QuartzCore

/// Full-window preview. The image flies out of its tile and back into it,
/// whichever view (Grid, Canvas, Infinity) it came from.
@MainActor
final class PreviewView: NSView {
    private let library: Library
    private let thumbnailer: Thumbnailer
    private weak var surface: ItemSurface?
    private let dim = CALayer()
    private let imageLayer = CALayer()
    private var items: [Item] = []
    private var index = 0
    private let duration: CFTimeInterval = 0.32
    var onClose: (() -> Void)?

    var isOpen: Bool { !isHidden }
    var isClosing: Bool { closing }
    var currentID: UUID? { isOpen && items.indices.contains(index) ? items[index].id : nil }

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        self.thumbnailer = thumbnailer
        super.init(frame: .zero)
        wantsLayer = true
        dim.backgroundColor = NSColor.windowBackgroundColor.cgColor
        dim.opacity = 0
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(dim)
        layer?.addSublayer(imageLayer)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func open(_ id: UUID, from surface: ItemSurface) {
        self.surface = surface
        items = surface.shownItems
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        index = i
        closing = false
        isHidden = false
        window?.makeFirstResponder(self)
        withoutAnimation {
            dim.frame = bounds
            dim.opacity = 0
            imageLayer.frame = startRect(for: id)
            imageLayer.contents = surface.currentImage(for: id)
        }
        // The neighbours get pushed away while the image grows out of its tile.
        surface.previewWillOpen(id)
        fade(dim, to: 1, duration: 0.35)
        springFrame(imageLayer, to: fitRect(for: items[i]), bounce: 0.1, response: 0.45)
        loadFull(items[i])
    }

    private var closing = false

    func close() {
        guard isOpen, !closing else { return }
        closing = true
        let id = items[index].id
        surface?.reveal(id)
        let end = startRect(for: id)
        // The neighbours spring back from the edges as the image flies home.
        surface?.previewWillClose(landingOn: id)
        fade(dim, to: 0, duration: 0.2)
        springFrame(imageLayer, to: end, bounce: 0.16, response: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.closing = false
                self.isHidden = true
                self.surface?.previewDidClose()
                self.onClose?()
            }
        }
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.opacity = opacity
        CATransaction.commit()
    }

    private func show(_ next: Int) {
        guard items.indices.contains(next) else { return }
        index = next
        let item = items[next]
        withoutAnimation {
            imageLayer.contents = surface?.currentImage(for: item.id)
                ?? thumbnailer.cached(library.thumbnailURL(item), maxPixel: Library.thumbnailSize)
            imageLayer.frame = fitRect(for: item)
        }
        loadFull(item)
    }

    private func loadFull(_ item: Item) {
        let shown = index
        // Pictures at full size; everything else is its representation.
        let url = item.hasFullImage ? (library.originalURL(item) ?? library.thumbnailURL(item)) : library.thumbnailURL(item)
        thumbnailer.load(url, maxPixel: 2400) { [weak self] image in
            guard let self, self.index == shown, self.isOpen else { return }
            withoutAnimation { self.imageLayer.contents = image }
        }
    }

    private func startRect(for id: UUID) -> NSRect {
        guard let r = surface?.rectInWindow(for: id) else {
            return items.first { $0.id == id }.map(fitRect) ?? bounds
        }
        return convert(r, from: nil)
    }

    private func fitRect(for item: Item) -> NSRect {
        let area = bounds.insetBy(dx: 40, dy: 40)
        let aspect = CGFloat(item.pixelWidth) / max(CGFloat(item.pixelHeight), 1)
        var size = NSSize(width: area.width, height: area.width / aspect)
        if size.height > area.height { size = NSSize(width: area.height * aspect, height: area.height) }
        // Never upscale beyond the image's own pixels (in points).
        let scale = window?.backingScaleFactor ?? 2
        let native = CGFloat(item.pixelWidth) / scale
        if size.width > native, native > 0 { size = NSSize(width: native, height: native / aspect) }
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        guard isOpen, items.indices.contains(index) else { return }
        withoutAnimation {
            dim.frame = bounds
            imageLayer.frame = fitRect(for: items[index])
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: close() // space, esc
        case 123, 126: show(index - 1)
        case 124, 125: show(index + 1)
        default: super.keyDown(with: event)
        }
    }

    /// A click anywhere closes the preview, even when the window isn't active,
    /// and none of the click reaches the views underneath.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { close() }
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { close() }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
}
