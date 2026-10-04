import AppKit
import QuartzCore

/// No edges: the board's images, packed into one block, repeat forever in
/// every direction. Each row of blocks is shifted so the repeat doesn't line
/// up. Drag or scroll to move; left alone, it drifts.
@MainActor
final class InfinityView: NSView, ItemSurface {
    private static let rowHeight: CGFloat = 220
    private static let spacing: CGFloat = 10
    private static let minZoom: CGFloat = 0.3
    private static let maxZoom: CGFloat = 3
    /// Points per second, in world units.
    private static let drift = CGVector(dx: 9, dy: 14)
    private static let idleBeforeDrift: TimeInterval = 2.5
    /// Velocity kept per millisecond while coasting.
    private static let deceleration = 0.998

    let library: Library
    let pool: TilePool
    var onOpen: ((UUID) -> Void)?
    var onRandom: (() -> Void)?

    private(set) var scope = Scope()
    private var items: [Item] = []
    private var block: [CGRect] = []
    private var blockSize = CGSize.zero

    private var offset = CGPoint.zero
    private var zoom: CGFloat = 1
    private var velocity = CGVector.zero
    private var lastInteraction = Date.distantPast
    private var timer: CADisplayLink?
    private var lastTick = CACurrentMediaTime()

    /// What's on screen now: tile key → item and world frame. Lets the preview
    /// fly from the exact copy that was clicked.
    private var visibleTiles: [String: (id: UUID, world: CGRect)] = [:]
    private var openedKey: String?
    private var dragLast: NSPoint?
    private var dragDistance: CGFloat = 0
    private var dragSamples: [(t: CFTimeInterval, p: NSPoint)] = []

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        pool = TilePool(library: library, thumbnailer: thumbnailer)
        pool.cornerRadius = 4
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        pool.host = layer
        pool.colors = { [unowned self] in self.resolved($0) }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func appearanceChanged() {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        renderChrome()
        pool.refreshColors()
        appearanceChanged()
    }
    override var acceptsFirstResponder: Bool { true }
    /// Clicking into an inactive window selects/drags right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Edges and caption

    /// What's being wandered, at the foot of the wall ("被遺忘的").
    var heading = "" { didSet { if heading != oldValue { renderChrome(); showHint() } } }
    private let topShade = CAGradientLayer()
    private let bottomShade = CAGradientLayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "拖曳或捲動來漫遊 · 空白鍵 暫停漂移 · R 隨機一件")

    /// The wall fades out under the toolbar and at the foot, where its name sits.
    private func renderChrome() {
        guard let root = layer else { return }
        if topShade.superlayer == nil {
            for g in [topShade, bottomShade] {
                g.zPosition = 50
                root.addSublayer(g)
            }
            for t in [titleLabel, hintLabel] {
                t.translatesAutoresizingMaskIntoConstraints = false
                addSubview(t)
                // Above the tiles and the shade (tiles join the layer tree later).
                t.wantsLayer = true
                t.layer?.zPosition = 60
            }
            hintLabel.font = .systemFont(ofSize: 11.5)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                titleLabel.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),
                hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
                hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            ])
        }
        let bg = resolved(.windowBackgroundColor)
        withoutAnimation {
            topShade.colors = [bg.copy(alpha: 0.9)!, bg.copy(alpha: 0)!]
            topShade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 120)
            bottomShade.colors = [bg.copy(alpha: 0)!, bg.copy(alpha: 0.7)!, bg.copy(alpha: 0.95)!]
            bottomShade.locations = [0, 0.55, 1]
            bottomShade.frame = CGRect(x: 0, y: bounds.height - 190, width: bounds.width, height: 190)
        }
        let size: CGFloat = 24
        titleLabel.font = Typography.display(size) ?? .systemFont(ofSize: size)
        titleLabel.stringValue = heading
        titleLabel.textColor = .labelColor
        hintLabel.textColor = .secondaryLabelColor
        // Whatever picture is behind them, the words stay readable.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 8
        for t in [titleLabel, hintLabel] { t.shadow = shadow }
    }

    /// The how-to shows when you arrive and fades once you start moving.
    private func showHint() {
        hintLabel.alphaValue = 1
    }

    private func fadeHint() {
        guard hintLabel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.6; hintLabel.animator().alphaValue = 0 }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderChrome()
        render()
    }

    var debugOffset: CGPoint { offset }
    var debugState: String {
        "ticking \(timer != nil), visible \(window?.occlusionState.contains(.visible) ?? false), idle \(String(format: "%.1f", Date().timeIntervalSince(lastInteraction)))s, velocity \(velocity), scattered \(pool.isScattered)"
    }

    // MARK: Model

    func show(scope: Scope) {
        var base = scope
        base.search = ""
        guard base != self.scope || items.isEmpty else { return }
        self.scope = base
        pool.removeAll()
        offset = .zero
        velocity = .zero
        reload()
    }

    private func reload() {
        items = library.items(for: scope)
        let totalAspect = items.map(\.aspect).reduce(0, +)
        // Block about 3:2, but at least two screens wide so repeats sit far apart.
        let width = max((totalAspect * Self.rowHeight * Self.rowHeight * 1.5).squareRoot(),
                        (items.map(\.aspect).max() ?? 1) * Self.rowHeight, 1400)
        let result = JustifiedLayout(width: width, rowHeight: Self.rowHeight, spacing: Self.spacing, inset: 0)
            .layout(aspects: items.map(\.aspect))
        block = result.frames
        blockSize = CGSize(width: width + Self.spacing, height: result.height + Self.spacing)
        pool.removeAll()
        render()
        needsDisplay = true
    }

    /// Visible state follows whether we're on screen, so the drift timer only
    /// runs while Infinity is showing.
    override func viewDidHide() {
        super.viewDidHide()
        timer?.invalidate()
        timer = nil
        pool.removeAll()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        startTimer()
        render()
    }

    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        // Closed, minimised or covered: no reason to animate at 60 Hz.
        occlusionObserver = window.map { w in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if w.occlusionState.contains(.visible), !self.isHiddenOrHasHiddenAncestor { self.startTimer() } else { self.timer?.invalidate(); self.timer = nil }
                }
            }
        }
        if window != nil, !isHiddenOrHasHiddenAncestor { startTimer() } else { timer?.invalidate(); timer = nil }
    }

    private func startTimer() {
        guard timer == nil, window?.occlusionState.contains(.visible) ?? false else { return }
        lastTick = CACurrentMediaTime()
        // In step with the display (120 Hz on ProMotion), not a 60 Hz timer.
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        timer = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        // Frozen while the preview is open, so the neighbours can spring back home.
        guard !items.isEmpty, dragLast == nil, !pool.isScattered else { return }
        if Date().timeIntervalSince(lastInteraction) > Self.idleBeforeDrift {
            // Ease into the drift instead of starting abruptly.
            velocity.dx += (Self.drift.dx - velocity.dx) * 0.02
            velocity.dy += (Self.drift.dy - velocity.dy) * 0.02
        } else {
            // Coast after a flick, slowing the same at any frame rate
            // (like a scroll view's normal deceleration).
            let decay = CGFloat(pow(Self.deceleration, dt * 1000))
            velocity.dx *= decay
            velocity.dy *= decay
        }
        guard abs(velocity.dx) + abs(velocity.dy) > 0.05 else { return }
        offset.x += velocity.dx * dt
        offset.y += velocity.dy * dt
        render()
    }

    // MARK: Rendering

    private func render() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        guard !items.isEmpty, blockSize.width > 0, blockSize.height > 0 else {
            pool.removeAll()
            visibleTiles = [:]
            return
        }
        let visible = CGRect(x: offset.x, y: offset.y, width: bounds.width / zoom, height: bounds.height / zoom)
            .insetBy(dx: -max(bounds.width, bounds.height) * 0.4 / zoom, dy: -max(bounds.width, bounds.height) * 0.4 / zoom)
        let bw = blockSize.width, bh = blockSize.height
        var placements: [TilePool.Placement] = []
        var tiles: [String: (id: UUID, world: CGRect)] = [:]

        let firstRow = Int((visible.minY / bh).rounded(.down))
        let lastRow = Int((visible.maxY / bh).rounded(.down))
        for row in firstRow...lastRow {
            // Golden-ratio shift per row keeps repeats from stacking in columns.
            let phase = (Double(row) * 0.618034).truncatingRemainder(dividingBy: 1)
            let shift = CGFloat(phase < 0 ? phase + 1 : phase) * bw
            let firstCol = Int(((visible.minX - shift) / bw).rounded(.down))
            let lastCol = Int(((visible.maxX - shift) / bw).rounded(.down))
            for col in firstCol...lastCol {
                let origin = CGPoint(x: CGFloat(col) * bw + shift, y: CGFloat(row) * bh)
                for (i, f) in block.enumerated() {
                    let world = f.offsetBy(dx: origin.x, dy: origin.y)
                    guard world.intersects(visible) else { continue }
                    let key = "\(row):\(col):\(i)"
                    tiles[key] = (items[i].id, world)
                    let screen = CGRect(x: (world.minX - offset.x) * zoom, y: (world.minY - offset.y) * zoom,
                                        width: world.width * zoom, height: world.height * zoom)
                    placements.append(.init(key: key, item: items[i], frame: screen))
                }
            }
        }
        visibleTiles = tiles
        pool.apply(placements, animated: false, scale: window?.backingScaleFactor ?? 2)
    }

    private func key(at p: NSPoint) -> String? {
        let w = CGPoint(x: p.x / zoom + offset.x, y: p.y / zoom + offset.y)
        return visibleTiles.first { $0.value.world.contains(w) }?.key
    }

    // MARK: ItemSurface

    var shownItems: [Item] { items }

    func rectInWindow(for id: UUID) -> NSRect? {
        let key = openedKey.flatMap { visibleTiles[$0]?.id == id ? $0 : nil }
            ?? visibleTiles.first { $0.value.id == id && bounds.intersects(screenRect($0.value.world)) }?.key
        guard let key, let tile = visibleTiles[key] else { return nil }
        return convert(screenRect(tile.world), to: nil)
    }

    private func screenRect(_ world: CGRect) -> CGRect {
        CGRect(x: (world.minX - offset.x) * zoom, y: (world.minY - offset.y) * zoom,
               width: world.width * zoom, height: world.height * zoom)
    }

    func currentImage(for id: UUID) -> CGImage? {
        if let key = openedKey, visibleTiles[key]?.id == id, let image = pool.image(key) { return image }
        return visibleTiles.first { $0.value.id == id }.flatMap { pool.image($0.key) }
    }

    func reveal(_ id: UUID) {
        // Browsing to another image in the preview: fly back to any visible copy.
        if visibleTiles[openedKey ?? ""]?.id != id { openedKey = nil }
        lastInteraction = Date()
    }

    func previewWillOpen(_ id: UUID) {
        velocity = .zero
        guard let key = openedKey ?? visibleTiles.first(where: { $0.value.id == id })?.key,
              let world = visibleTiles[key]?.world else { return }
        openedKey = key
        let r = screenRect(world)
        pool.scatter(from: CGPoint(x: r.midX, y: r.midY), hiding: key)
    }

    func previewWillClose(landingOn id: UUID) {
        let key = visibleTiles[openedKey ?? ""]?.id == id ? openedKey
            : visibleTiles.first { $0.value.id == id && bounds.intersects(screenRect($0.value.world)) }?.key
        pool.gather(landing: key)
    }

    func previewDidClose() {
        pool.revealHidden()
        lastInteraction = Date()
        render()
    }

    // MARK: Input

    private func interacted() {
        lastInteraction = Date()
        fadeHint()
    }

    override func scrollWheel(with event: NSEvent) {
        interacted()
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            zoom(by: 1 + delta, around: convert(event.locationInWindow, from: nil))
            return
        }
        velocity = .zero
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        offset.x -= event.scrollingDeltaX * k / zoom
        offset.y -= event.scrollingDeltaY * k / zoom
        render()
    }

    override func magnify(with event: NSEvent) {
        interacted()
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    private func zoom(by factor: CGFloat, around p: NSPoint) {
        let world = CGPoint(x: p.x / zoom + offset.x, y: p.y / zoom + offset.y)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        offset = CGPoint(x: world.x - p.x / zoom, y: world.y - p.y / zoom)
        render()
    }

    func zoom(by factor: CGFloat) {
        interacted()
        zoom(by: factor, around: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        interacted()
        velocity = .zero
        let p = convert(event.locationInWindow, from: nil)
        dragLast = p
        dragDistance = 0
        dragSamples = [(CACurrentMediaTime(), p)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = dragLast else { return }
        interacted()
        let p = convert(event.locationInWindow, from: nil)
        offset.x -= (p.x - last.x) / zoom
        offset.y -= (p.y - last.y) / zoom
        dragDistance += hypot(p.x - last.x, p.y - last.y)
        dragLast = p
        let now = CACurrentMediaTime()
        dragSamples.append((now, p))
        dragSamples.removeAll { now - $0.t > 0.1 }
        render()
    }

    override func mouseUp(with event: NSEvent) {
        // Only a click that started here counts (not one that closed the preview).
        guard dragLast != nil else { return }
        defer { dragLast = nil }
        interacted()
        let p = convert(event.locationInWindow, from: nil)
        if dragDistance < 4 {
            if let key = key(at: p), let id = visibleTiles[key]?.id {
                openedKey = key
                onOpen?(id)
            }
            return
        }
        // Flick: keep moving with the release velocity, then coast down.
        // Only the last 100 ms count: holding still before letting go doesn't fling.
        let now = CACurrentMediaTime()
        dragSamples.removeAll { now - $0.t > 0.1 }
        if let first = dragSamples.first, let last = dragSamples.last, last.t > first.t {
            let dt = CGFloat(last.t - first.t)
            velocity = CGVector(dx: -(last.p.x - first.p.x) / dt / zoom, dy: -(last.p.y - first.p.y) / dt / zoom)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 15 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            onRandom?()
        case 49: // space: pause / resume drift
            if Date().timeIntervalSince(lastInteraction) > Self.idleBeforeDrift {
                lastInteraction = .distantFuture
                velocity = .zero
            } else {
                lastInteraction = .distantPast
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard items.isEmpty else { return }
        let text = "這裡還沒有圖" as NSString
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        text.draw(in: NSRect(x: bounds.midX - 200, y: bounds.midY - 10, width: 400, height: 30), withAttributes: attrs)
    }
}
