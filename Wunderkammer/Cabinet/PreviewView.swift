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
    var onActivate: ((UUID) -> Void)?
    var onRandom: (() -> Void)?
    /// A line under the image (Random: how long ago it was collected).
    private let caption = CATextLayer()

    var isOpen: Bool { !isHidden }
    var isClosing: Bool { closing }
    var captionText: String? { caption.opacity > 0 ? (caption.string as? NSAttributedString)?.string : nil }
    var currentID: UUID? { isOpen && items.indices.contains(index) ? items[index].id : nil }

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        self.thumbnailer = thumbnailer
        super.init(frame: .zero)
        wantsLayer = true
        dim.opacity = 0
        imageLayer.contentsGravity = .resizeAspect
        // Presented, not pasted: a soft shadow lifts the piece off the stage.
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0.55
        imageLayer.shadowRadius = 28
        imageLayer.shadowOffset = CGSize(width: 0, height: -14)
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(dim)
        layer?.addSublayer(imageLayer)
        caption.alignmentMode = .center
        caption.opacity = 0
        layer?.addSublayer(caption)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func open(_ id: UUID, from surface: ItemSurface, caption text: String? = nil) {
        self.surface = surface
        items = surface.shownItems
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        index = i
        closing = false
        isHidden = false
        dim.backgroundColor = resolved(.windowBackgroundColor)
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
        glideFrame(imageLayer, to: fitRect(for: items[i]), duration: ItemSpring.open)
        loadFull(items[i])
        setCaption(for: items[i], note: text)
    }

    /// Under the picture: its name, then what it is and when it was collected
    /// (or a note, like how long ago a random pick was collected).
    private func setCaption(for item: Item, note: String? = nil) {
        withoutAnimation {
            caption.contentsScale = window?.backingScaleFactor ?? 2
            caption.isWrapped = true
            let size: CGFloat = 17
            let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            style.paragraphSpacing = 4
            let about = [InspectorViewController.kindName(item), item.domain, item.released.map { String($0.prefix(4)) },
                         note ?? Rediscovery.ageLine(item)].compactMap { $0 }.filter { !$0.isEmpty }
            // A note's title is its first words, already on the card.
            let text = NSMutableAttributedString(string: item.kind == .text ? "" : item.displayTitle + "\n", attributes: [
                .font: serif ?? NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(cgColor: resolved(.labelColor)) ?? NSColor.labelColor, .paragraphStyle: style,
            ])
            text.append(NSAttributedString(string: about.joined(separator: " · "), attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor(cgColor: resolved(.secondaryLabelColor)) ?? NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            caption.string = text
            caption.frame = captionFrame
        }
        fade(caption, to: 1, duration: 0.5)
    }

    private var captionFrame: CGRect { CGRect(x: 40, y: bounds.maxY - Self.captionRoom + 14, width: bounds.width - 80, height: 48) }
    /// Space kept under the picture for the caption.
    private static let captionRoom: CGFloat = 76

    /// Gone without the fly-back (another preview is about to open).
    func dismissImmediately() {
        guard isOpen else { return }
        closing = false
        withoutAnimation {
            dim.opacity = 0
            caption.opacity = 0
        }
        isHidden = true
        surface?.previewWillClose(landingOn: items[index].id)
        surface?.previewDidClose()
    }

    private var closing = false

    func close() {
        guard isOpen, !closing else { return }
        closing = true
        let id = items[index].id
        surface?.reveal(id)
        let end = startRect(for: id)
        // The neighbours ride the same spring home as the image.
        surface?.previewWillClose(landingOn: id)
        fade(dim, to: 0, duration: 0.2)
        fade(caption, to: 0, duration: 0.15)
        glideFrame(imageLayer, to: end, duration: ItemSpring.close)
        // Settle pass once the spring is done, like Atlas's collapseDuration + 0.05.
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemSpring.close + 0.05) { [weak self] in
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
        setCaption(for: item)
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
        var area = bounds.insetBy(dx: 40, dy: 40)
        area.size.height -= Self.captionRoom - 40
        let aspect = CGFloat(item.pixelWidth) / max(CGFloat(item.pixelHeight), 1)
        var size = NSSize(width: area.width, height: area.width / aspect)
        if size.height > area.height { size = NSSize(width: area.height * aspect, height: area.height) }
        // Small pictures may grow a little (up to 1.6× their own pixels), so a
        // meme isn't a stamp in the middle of the stage; never more than that.
        let scale = window?.backingScaleFactor ?? 2
        let native = CGFloat(item.pixelWidth) / scale * 1.6
        if size.width > native, native > 0 { size = NSSize(width: native, height: native / aspect) }
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutAnimation { dim.backgroundColor = resolved(.windowBackgroundColor) }
    }

    override func layout() {
        super.layout()
        guard isOpen, items.indices.contains(index) else { return }
        withoutAnimation {
            dim.frame = bounds
            imageLayer.frame = fitRect(for: items[index])
            caption.frame = captionFrame
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: close() // space, esc
        case 36, 76: onActivate?(items[index].id) // return: open it
        case 15 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty: onRandom?()
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
