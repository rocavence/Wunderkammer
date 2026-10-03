import AppKit
import QuartzCore

/// Free-form board made of piles. Each pile packs its own images; drag a
/// selection out and it becomes a new pile where you drop it (or joins the pile
/// under the cursor), the pile it left closes the gap, and piles that now
/// overlap push each other apart.
@MainActor
final class CanvasView: NSView, ItemSurface {
    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 4

    let library: Library
    let pool: TilePool
    var onOpen: ((UUID) -> Void)?

    private(set) var board: UUID?
    private var groups: [CanvasGroup] = []
    private var itemFrames: [UUID: CGRect] = [:]
    private var groupFrames: [UUID: CGRect] = [:]
    private var selection = Selection()

    /// Camera: world point at the view's top-left, and points per world unit.
    private var offset = CGPoint.zero
    private var zoom: CGFloat = 1

    private struct ItemDrag {
        var ids: [UUID]
        var block: [UUID: CGRect]
        var blockSize: CGSize
        /// Cursor position inside the block, in world units.
        var grab: CGPoint
        var cursor: CGPoint
    }

    private enum Gesture {
        case none
        case pressedItem(start: NSPoint, hit: UUID, narrowOnUp: Bool)
        case movingItems(ItemDrag)
        case marquee(start: NSPoint, base: Set<UUID>)
        case pan(last: NSPoint)
    }

    private var gesture = Gesture.none
    /// While dragging piles the dragged block follows the cursor with a short ease, not a spring.
    private var isMoving: Bool { if case .movingItems = gesture { return true }; return false }
    /// Set when a board is shown before the view has a size to fit it into.
    private var needsFit = false
    private var marqueeLayer: CAShapeLayer?

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        pool = TilePool(library: library, thumbnailer: thumbnailer)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        pool.host = layer
        registerForDraggedTypes([.fileURL, .png, .tiff, .wunderkammerItem])
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Clicking into an inactive window selects/drags right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if needsFit { fit() } else { render(animated: false) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if needsFit { fit() }
    }

    var debugGroupFrames: [CGRect] { Array(groupFrames.values) }

    // MARK: Model

    private var order: [UUID] { groups.flatMap(\.itemIDs) }

    func show(board: UUID?) {
        self.board = board
        selection = Selection()
        pool.removeAll()
        groups = library.canvasGroups(for: board)
        layoutGroups()
        needsFit = true
        fit()
        render(animated: false)
        needsDisplay = true
    }

    private func reload() {
        groups = library.canvasGroups(for: board)
        layoutGroups()
        resolveOverlaps(pinned: [])
        selection.restrict(to: Set(order))
        render(animated: true)
        needsDisplay = true
    }

    private func save() {
        library.setCanvasGroups(groups, for: board)
    }

    /// Packs every pile and records world frames for piles and their images.
    private func layoutGroups() {
        itemFrames = [:]
        groupFrames = [:]
        for g in groups {
            let items = g.itemIDs.compactMap(library.item)
            let (frames, size) = CanvasLayout.pack(items.map(\.aspect))
            groupFrames[g.id] = CGRect(x: g.x, y: g.y, width: size.width, height: size.height)
            for (item, f) in zip(items, frames) {
                itemFrames[item.id] = f.offsetBy(dx: g.x, dy: g.y)
            }
        }
    }

    private func resolveOverlaps(pinned: Set<UUID>) {
        let rects = groups.map { groupFrames[$0.id] ?? .zero }
        let pins = Set(groups.indices.filter { pinned.contains(groups[$0].id) })
        let out = CanvasLayout.separate(rects, pinned: pins)
        for i in groups.indices {
            groups[i].x = out[i].minX
            groups[i].y = out[i].minY
        }
        layoutGroups()
    }

    @objc func arrange(_ sender: Any?) {
        let sizes = groups.map { groupFrames[$0.id]?.size ?? .zero }
        let widest = sizes.map(\.width).max() ?? 0
        let maxWidth = max(widest, bounds.width / zoom * 0.95, 1600)
        for (i, origin) in CanvasLayout.arrange(sizes, maxWidth: maxWidth).enumerated() {
            groups[i].x = origin.x
            groups[i].y = origin.y
        }
        layoutGroups()
        save()
        fit(animated: true)
    }

    // MARK: Camera

    private func toScreen(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - offset.x) * zoom, y: (r.minY - offset.y) * zoom,
               width: r.width * zoom, height: r.height * zoom)
    }

    private func toWorld(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + offset.x, y: p.y / zoom + offset.y)
    }

    /// Frames everything with a margin; never zooms in past 1:1.
    func fit(animated: Bool = false) {
        guard let content = groupFrames.values.reduce(nil, { ($0 as CGRect?)?.union($1) ?? $1 }),
              bounds.width > 0, bounds.height > 0, window != nil else { return }
        needsFit = false
        let margin: CGFloat = 60
        let top = topInset
        let avail = CGSize(width: bounds.width - margin * 2, height: bounds.height - top - margin * 2)
        zoom = min(1, max(Self.minZoom, min(avail.width / content.width, avail.height / content.height)))
        offset = CGPoint(x: content.midX - bounds.width / zoom / 2,
                         y: content.midY - (bounds.height + top) / zoom / 2)
        render(animated: animated)
    }

    /// Space under the transparent titlebar/toolbar.
    private var topInset: CGFloat {
        guard let window else { return 0 }
        return window.frame.height - window.contentLayoutRect.height
    }

    private func zoom(by factor: CGFloat, around p: NSPoint) {
        let world = toWorld(p)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        offset = CGPoint(x: world.x - p.x / zoom, y: world.y - p.y / zoom)
        render(animated: false)
    }

    func zoom(by factor: CGFloat) {
        zoom(by: factor, around: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            zoom(by: 1 + delta, around: convert(event.locationInWindow, from: nil))
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        offset.x -= event.scrollingDeltaX * k / zoom
        offset.y -= event.scrollingDeltaY * k / zoom
        render(animated: false)
    }

    // MARK: Rendering

    private func render(animated: Bool, duration: CFTimeInterval = TilePool.animation) {
        let visible = CGRect(x: offset.x, y: offset.y, width: bounds.width / zoom, height: bounds.height / zoom)
            .insetBy(dx: -200 / zoom, dy: -200 / zoom)
        var placements: [TilePool.Placement] = []
        var dragged: [UUID: CGRect] = [:]
        if case .movingItems(let drag) = gesture {
            let origin = CGPoint(x: drag.cursor.x - drag.grab.x, y: drag.cursor.y - drag.grab.y)
            for (id, f) in drag.block { dragged[id] = f.offsetBy(dx: origin.x, dy: origin.y) }
        }
        for g in groups {
            for id in g.itemIDs {
                guard let world = itemFrames[id], world.intersects(visible), let item = library.item(id) else { continue }
                placements.append(.init(key: id.uuidString, item: item, frame: toScreen(world),
                                        selected: selection.ids.contains(id)))
            }
        }
        for (id, world) in dragged {
            guard let item = library.item(id) else { continue }
            placements.append(.init(key: id.uuidString, item: item, frame: toScreen(world), selected: true, z: 10))
        }
        pool.apply(placements, animated: animated, scale: (window?.backingScaleFactor ?? 2), duration: duration,
                   spring: animated && !isMoving)
    }

    private func showSelection() {
        pool.setSelected(Set(selection.ids.map(\.uuidString)))
    }

    private func hit(_ p: NSPoint) -> UUID? {
        let w = toWorld(p)
        // Last drawn wins; piles don't overlap, so any match is the one.
        return itemFrames.first { $0.value.contains(w) }?.key
    }

    // MARK: ItemSurface

    var shownItems: [Item] { order.compactMap(library.item) }

    func rectInWindow(for id: UUID) -> NSRect? {
        guard let world = itemFrames[id] else { return nil }
        return convert(toScreen(world), to: nil)
    }

    func currentImage(for id: UUID) -> CGImage? { pool.image(id.uuidString) }

    func reveal(_ id: UUID) {
        selection.set([id], anchor: id)
        showSelection()
        guard let world = itemFrames[id] else { return }
        let screen = toScreen(world)
        if !bounds.insetBy(dx: 0, dy: topInset / 2).contains(screen) {
            offset = CGPoint(x: world.midX - bounds.width / zoom / 2, y: world.midY - bounds.height / zoom / 2)
            render(animated: false)
        }
    }

    func previewWillOpen(_ id: UUID) {
        guard let world = itemFrames[id] else { return }
        let r = toScreen(world)
        pool.scatter(from: CGPoint(x: r.midX, y: r.midY), hiding: id.uuidString)
    }

    func previewWillClose(landingOn id: UUID) {
        pool.gather(landing: id.uuidString)
    }

    func previewDidClose() {
        pool.revealHidden()
        render(animated: false)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let id = hit(p)
        let modifier = Selection.modifier(event.modifierFlags)

        if event.clickCount == 2, let id {
            onOpen?(id)
            gesture = .none
            return
        }
        if let id {
            let keepGroup = modifier == .none && selection.ids.contains(id)
            if !keepGroup {
                selection.click(id, modifier, order: order)
                showSelection()
            }
            gesture = .pressedItem(start: p, hit: id, narrowOnUp: keepGroup)
        } else if event.modifierFlags.contains(.option) {
            gesture = .pan(last: p)
        } else {
            let base = modifier == .none ? Set<UUID>() : selection.ids
            selection.click(nil, modifier, order: order)
            showSelection()
            gesture = .marquee(start: p, base: base)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .pressedItem(let start, let hit, _):
            guard hypot(p.x - start.x, p.y - start.y) > 4, selection.ids.contains(hit) else { return }
            beginMove(grabbing: hit, at: start)
            mouseDragged(with: event)
        case .movingItems(var drag):
            drag.cursor = toWorld(p)
            gesture = .movingItems(drag)
            render(animated: true, duration: 0.1)
        case .marquee(let start, let base):
            updateMarquee(from: start, to: p, base: base)
        case .pan(let last):
            offset.x -= (p.x - last.x) / zoom
            offset.y -= (p.y - last.y) / zoom
            gesture = .pan(last: p)
            render(animated: false)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch gesture {
        case .pressedItem(_, let hit, let narrow):
            if narrow {
                selection.click(hit, .none, order: order)
                showSelection()
            }
        case .movingItems(let drag):
            drop(drag)
        case .marquee:
            marqueeLayer?.removeFromSuperlayer()
            marqueeLayer = nil
        default:
            break
        }
        gesture = .none
    }

    override func otherMouseDown(with event: NSEvent) {
        gesture = .pan(last: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { gesture = .none }

    private func updateMarquee(from a: NSPoint, to b: NSPoint, base: Set<UUID>) {
        let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if marqueeLayer == nil {
            let m = CAShapeLayer()
            m.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            m.strokeColor = NSColor.controlAccentColor.cgColor
            m.lineWidth = 1
            m.zPosition = 100
            layer?.addSublayer(m)
            marqueeLayer = m
        }
        withoutAnimation { marqueeLayer?.path = CGPath(rect: rect, transform: nil) }
        let hits = itemFrames.filter { toScreen($0.value).intersects(rect) }.map(\.key)
        selection.set(base.union(hits), anchor: hits.first)
        showSelection()
    }

    // MARK: Moving piles

    /// Lifts the selection out of its piles: the piles close up behind it and
    /// the selection packs into a block that follows the cursor.
    private func beginMove(grabbing hitID: UUID, at start: NSPoint) {
        let ids = selection.ordered(order)
        guard let grabbedWorld = itemFrames[hitID] else { return }
        let startWorld = toWorld(start)
        let fraction = CGPoint(x: (startWorld.x - grabbedWorld.minX) / grabbedWorld.width,
                               y: (startWorld.y - grabbedWorld.minY) / grabbedWorld.height)

        let items = ids.compactMap(library.item)
        let (frames, size) = CanvasLayout.pack(items.map(\.aspect))
        var block: [UUID: CGRect] = [:]
        for (item, f) in zip(items, frames) { block[item.id] = f }
        let g = block[hitID] ?? .zero
        let grab = CGPoint(x: g.minX + fraction.x * g.width, y: g.minY + fraction.y * g.height)

        let lifted = Set(ids)
        for i in groups.indices { groups[i].itemIDs.removeAll { lifted.contains($0) } }
        groups.removeAll { $0.itemIDs.isEmpty }
        layoutGroups()

        gesture = .movingItems(ItemDrag(ids: ids, block: block, blockSize: size, grab: grab, cursor: startWorld))
        render(animated: true)
    }

    /// Drops onto the pile under the cursor, or starts a new pile there.
    private func drop(_ drag: ItemDrag) {
        let target = groups.first { groupFrames[$0.id]?.insetBy(dx: -12, dy: -12).contains(drag.cursor) == true }
        let pinned: UUID
        if let target, let i = groups.firstIndex(where: { $0.id == target.id }) {
            groups[i].itemIDs.append(contentsOf: drag.ids)
            pinned = target.id
        } else {
            let g = CanvasGroup(id: UUID(), x: drag.cursor.x - drag.grab.x, y: drag.cursor.y - drag.grab.y,
                                itemIDs: drag.ids)
            groups.append(g)
            pinned = g.id
        }
        gesture = .none
        layoutGroups()
        resolveOverlaps(pinned: [pinned])
        save()
        render(animated: true)
    }

    // MARK: Menus & keys

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let id = hit(p) else {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("整理成整齊的排列") { [weak self] in self?.arrange(nil) })
            menu.addItem(ClosureMenuItem("顯示全部") { [weak self] in self?.fit(animated: true) })
            return menu
        }
        if !selection.ids.contains(id) {
            selection.click(id, .none, order: order)
            showSelection()
        }
        return ItemActions.menu(for: selection.ordered(order), board: board, library: library, window: window) { [weak self] in
            self?.onOpen?(id)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            if let id = selection.anchor ?? selection.ordered(order).first { onOpen?(id) }
        case 51, 117:
            deleteSelection()
        case 53:
            selection = Selection()
            showSelection()
        default:
            super.keyDown(with: event)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        selection.set(Set(order))
        showSelection()
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    private func deleteSelection() {
        ItemActions.delete(selection.ordered(order), board: board, library: library, window: window)
    }

    // MARK: Drop from outside

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        importPasteboard(sender.draggingPasteboard, library: library, board: board)
    }

    @objc func paste(_ sender: Any?) {
        _ = importPasteboard(NSPasteboard.general, library: library, board: board)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard groups.isEmpty else { return }
        let text = "Canvas 是空的\n先在 Grid 加入圖片，或直接拖檔案進來" as NSString
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        text.draw(in: NSRect(x: bounds.midX - 230, y: bounds.midY - 24, width: 460, height: 60), withAttributes: attrs)
    }
}
