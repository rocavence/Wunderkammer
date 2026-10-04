import AppKit
import QuartzCore

/// Free-form board made of piles. Each pile packs its own images; drag a
/// selection out and it becomes a new pile where you drop it (or joins the pile
/// under the cursor), the pile it left closes the gap, and piles that now
/// overlap push each other apart.
@MainActor
final class CanvasView: NSView, ItemSurface, CabinetSurface {
    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 4

    let library: Library
    let pool: TilePool
    var onOpen: ((UUID) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var onRandom: (() -> Void)?
    var onFocus: ((UUID?) -> Void)?
    var onSimilar: ((UUID) -> Void)?

    private(set) var scope = Scope()
    var board: UUID? { scope.board }
    private var groups: [CanvasGroup] = []
    private var links: [CanvasLink] = []
    private let linesLayer = CAShapeLayer()
    /// Relations the system found (CrossMedia), dashed under the user's own lines.
    private let relationsLayer = CAShapeLayer()
    private var relationLinks: [(a: UUID, b: UUID, label: String)] = []
    private var relationLabels: [CATextLayer] = []
    private var relationsTask: Task<Void, Never>?
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
        /// ⌥-drag from one item towards another to connect them.
        case connecting(from: UUID, to: NSPoint)
    }

    private var gesture = Gesture.none
    /// Space held down: the hand. Dragging then moves the canvas; a tap
    /// without a drag still previews, as it always did.
    private var spaceHeld = false
    private var spacePanned = false
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
        pool.colors = { [unowned self] in self.resolved($0) }
        linesLayer.fillColor = nil
        linesLayer.lineWidth = 2
        linesLayer.lineCap = .round
        // Over the pictures (neighbours would hide it), under anything being dragged.
        linesLayer.zPosition = 6
        linesLayer.shadowOpacity = 0.35
        linesLayer.shadowRadius = 2
        linesLayer.shadowOffset = .zero
        layer?.addSublayer(linesLayer)
        relationsLayer.fillColor = nil
        relationsLayer.lineWidth = 1.5
        relationsLayer.lineDashPattern = [5, 4]
        // Under the pictures: the lines show in the gaps, never across a photo.
        relationsLayer.zPosition = -1
        layer?.addSublayer(relationsLayer)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff, .wunderkammerItem])
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func appearanceChanged() {
        for t in titleLayers.values { t.removeFromSuperlayer() }
        titleLayers = [:]
        render(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        pool.refreshColors()
        appearanceChanged()
    }
    override var acceptsFirstResponder: Bool { true }
    /// Clicking into an inactive window selects/drags right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = resolved(.windowBackgroundColor)
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

    func show(scope: Scope) {
        // The canvas shows the view itself; searching happens in the grid views.
        var base = scope
        base.search = ""
        self.scope = base
        selection = Selection()
        pool.removeAll()
        groups = currentGroups()
        links = library.links(key: scope.canvasKey)
        findRelations()
        layoutGroups()
        needsFit = true
        fit()
        render(animated: false)
        needsDisplay = true
    }

    private func currentGroups() -> [CanvasGroup] {
        library.canvasGroups(key: scope.canvasKey, ids: library.items(for: scope).map(\.id))
    }

    /// A library change that arrived mid-drag; applied after the drop.
    private var reloadAfterDrop = false

    private func reload() {
        // Rebuilding piles mid-drag would put the lifted items back in their old
        // pile as well as the new one.
        if case .movingItems = gesture {
            reloadAfterDrop = true
            return
        }
        groups = currentGroups()
        links = library.links(key: scope.canvasKey)
        findRelations()
        layoutGroups()
        resolveOverlaps(pinned: [])
        selection.restrict(to: Set(order))
        render(animated: true)
        needsDisplay = true
    }

    private func save() {
        library.setCanvasGroups(groups, key: scope.canvasKey)
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
        // Titled piles need room for their name above them.
        let titleRoom: CGFloat = groups.contains { $0.title != nil } ? 44 : 0
        let padded = sizes.map { CGSize(width: $0.width, height: $0.height + titleRoom) }
        for (i, origin) in CanvasLayout.arrange(padded, maxWidth: maxWidth).enumerated() {
            groups[i].x = origin.x
            groups[i].y = origin.y + titleRoom
        }
        layoutGroups()
        save()
        fit(animated: true)
    }

    /// The system sorts the canvas into piles by theme, each with its name.
    /// What the system sees connecting the things on this canvas; worked out
    /// off the main thread (every item's words against every other's names).
    private func findRelations() {
        relationsTask?.cancel()
        let items = order.compactMap(library.item)
        guard items.count <= 1500 else { relationLinks = []; return }
        relationsTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { CrossMedia.links(among: items) }.value
            guard let self, !Task.isCancelled else { return }
            self.relationLinks = found
            self.renderLines()
        }
    }

    var debugPileTitles: [String] { groups.compactMap(\.title) }
    var debugSelectionCount: Int { selection.ids.count }
    var debugGesture: String { "\(gesture)".prefix(60).description }
    var debugRelationCount: Int { relationLinks.count }
    var debugTitleFrames: [String] {
        groups.compactMap { g in titleLayers[g.id].map { "\(g.title ?? "") \($0.frame.integral) hidden \($0.isHidden)" } }
    }

    @objc func clusterByRelation(_ sender: Any?) {
        let items = order.compactMap(library.item)
        var clusters = CanvasLayout.relationClusters(items, links: relationLinks)
        // What nothing connects is still sorted, by theme, rather than one big 其他.
        if let rest = clusters.last, rest.title == "其他" {
            clusters.removeLast()
            let leftover = Set(rest.ids)
            clusters += CanvasLayout.clusters(items.filter { leftover.contains($0.id) },
                                              subjects: Subjects.discover(in: library.items, limit: 24))
        }
        groups = clusters.map { CanvasGroup(id: UUID(), x: 0, y: 0, itemIDs: $0.ids, title: $0.title) }
        layoutGroups()
        arrange(nil)
    }

    @objc func clusterByTheme(_ sender: Any?) {
        let items = order.compactMap(library.item)
        let clusters = CanvasLayout.clusters(items, subjects: Subjects.discover(in: library.items, limit: 24))
        groups = clusters.map { CanvasGroup(id: UUID(), x: 0, y: 0, itemIDs: $0.ids, title: $0.title) }
        layoutGroups()
        arrange(nil)
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

    override func viewDidHide() {
        super.viewDidHide()
        pool.removeAll()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if needsFit { fit() } else { render(animated: false) }
    }

    private func render(animated: Bool, duration: CFTimeInterval = TilePool.animation) {
        // Off screen, nothing to draw (and nothing to decode).
        guard !isHiddenOrHasHiddenAncestor else { return }
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
        renderTitles(visible: visible, animated: animated)
        renderLines(animated: animated)
    }

    /// Where an item sits on screen now (following a drag if it's being moved).
    private func screenCenter(_ id: UUID) -> CGPoint? {
        if case .movingItems(let drag) = gesture, let f = drag.block[id] {
            let origin = CGPoint(x: drag.cursor.x - drag.grab.x, y: drag.cursor.y - drag.grab.y)
            let r = toScreen(f.offsetBy(dx: origin.x, dy: origin.y))
            return CGPoint(x: r.midX, y: r.midY)
        }
        guard let world = itemFrames[id] else { return nil }
        let r = toScreen(world)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// The connections, plus the one being drawn.
    private func renderLines(animated: Bool = false) {
        let path = CGMutablePath()
        for link in links {
            guard let a = screenCenter(link.a), let b = screenCenter(link.b) else { continue }
            path.move(to: a)
            path.addLine(to: b)
            for end in [a, b] { path.addEllipse(in: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)) }
        }
        if case .connecting(let from, let to) = gesture, let a = screenCenter(from) {
            path.move(to: a)
            path.addLine(to: to)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(TilePool.animation)
        linesLayer.strokeColor = resolved(.controlAccentColor)
        linesLayer.fillColor = resolved(.controlAccentColor)
        linesLayer.frame = bounds
        linesLayer.path = path
        renderRelations()
        CATransaction.commit()
    }

    /// The system's relations: dashed, with what connects them written along
    /// the way when there's room (zoomed in, not too many).
    private func renderRelations() {
        let mine = Set(links.map { Set([$0.a, $0.b]) })
        let shown = relationLinks.filter { !mine.contains(Set([$0.a, $0.b])) }
            .compactMap { l -> (CGPoint, CGPoint, String)? in
                guard let a = screenCenter(l.a), let b = screenCenter(l.b) else { return nil }
                return (a, b, l.label)
            }
        let path = CGMutablePath()
        for (a, b, _) in shown {
            path.move(to: a)
            path.addLine(to: b)
        }
        relationsLayer.frame = bounds
        relationsLayer.strokeColor = resolved(.controlAccentColor).copy(alpha: 0.75)
        relationsLayer.path = path
        let labelled = zoom >= 0.45 && shown.count <= 60 ? shown : []
        while relationLabels.count < labelled.count {
            let t = CATextLayer()
            t.fontSize = 11
            t.alignmentMode = .center
            t.cornerRadius = 4
            t.zPosition = 5.6
            t.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(t)
            relationLabels.append(t)
        }
        for (i, t) in relationLabels.enumerated() {
            guard i < labelled.count else { t.isHidden = true; continue }
            let (a, b, text) = labelled[i]
            t.isHidden = false
            t.string = text
            t.foregroundColor = resolved(.secondaryLabelColor)
            t.backgroundColor = resolved(.windowBackgroundColor)
            let width = min(CGFloat(text.count) * 7 + 12, 180)
            t.frame = CGRect(x: (a.x + b.x) / 2 - width / 2, y: (a.y + b.y) / 2 - 8, width: width, height: 16)
        }
    }

    /// A connection under the point (within a few points of the line).
    private func link(at p: NSPoint) -> CanvasLink? {
        links.first { link in
            guard let a = screenCenter(link.a), let b = screenCenter(link.b) else { return false }
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1)))
            return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y) < 6
        }
    }

    private var titleLayers: [UUID: CATextLayer] = [:]

    /// Names above system-made piles, scaled with the canvas; hidden when tiny.
    private func renderTitles(visible: CGRect, animated: Bool) {
        guard let root = layer else { return }
        var keep = Set<UUID>()
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(TilePool.animation)
        for g in groups {
            guard let title = g.title, let frame = groupFrames[g.id], zoom > 0.06,
                  frame.insetBy(dx: 0, dy: -60).intersects(visible) else { continue }
            keep.insert(g.id)
            let t = titleLayers[g.id] ?? {
                let t = CATextLayer()
                t.contentsScale = window?.backingScaleFactor ?? 2
                t.truncationMode = .end
                root.addSublayer(t)
                titleLayers[g.id] = t
                return t
            }()
            let size = min(max(18 * zoom, 11), 28)
            let serif = Typography.display(size)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: serif ?? NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(cgColor: resolved(.secondaryLabelColor)) ?? NSColor.secondaryLabelColor,
            ]
            let screen = toScreen(frame)
            // As wide as it likes up to the next pile on its right, then "…".
            let titleBand = CGRect(x: frame.maxX, y: frame.minY - 60, width: .greatestFiniteMagnitude, height: 60)
            let nextPile = groupFrames.values.filter { $0.minX >= frame.maxX - 1 && $0.insetBy(dx: 0, dy: -60).intersects(titleBand) }
                .map(\.minX).min().map { toScreen(CGRect(x: $0, y: 0, width: 0, height: 0)).minX }
            let width = max(screen.width, min(300, (nextPile ?? .greatestFiniteMagnitude) - screen.minX - 10))
            t.frame = CGRect(x: screen.minX, y: screen.minY - size * 1.9, width: width, height: size * 1.5)
            // Shortened here: a CATextLayer that has to truncate a styled string draws nothing.
            t.string = Self.fitting("\(g.itemIDs.count)", after: title, width: width, attributes: attributes)
            t.zPosition = 5
        }
        for (id, t) in titleLayers where !keep.contains(id) {
            t.removeFromSuperlayer()
            titleLayers[id] = nil
        }
        CATransaction.commit()
    }

    /// "Ursula K. Le Guin  4" or, when it doesn't fit, "Ursula K…  4": the count always shows.
    static func fitting(_ count: String, after title: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var name = title
        func text(_ n: String) -> NSAttributedString { NSAttributedString(string: "\(n)  \(count)", attributes: attributes) }
        while text(name).size().width > width, name.count > 1 {
            name = String(name.dropLast(name.hasSuffix("…") ? 2 : 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text(name)
    }

    private func showSelection() {
        pool.setSelected(Set(selection.ids.map(\.uuidString)))
        onFocus?(selection.anchor ?? selection.ordered(order).first)
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
        if spaceHeld {
            spacePanned = true
            NSCursor.closedHand.set()
            gesture = .pan(last: p)
            return
        }
        let id = hit(p)
        let modifier = Selection.modifier(event.modifierFlags)
        let option = event.modifierFlags.contains(.option)

        if event.clickCount == 2, let id {
            onOpen?(id)
            gesture = .none
            return
        }
        switch (id, option) {
        case (let id?, true):
            // ⌥ on an item: start a connection.
            gesture = .connecting(from: id, to: p)
            renderLines()
        case (let id?, false):
            let keepGroup = modifier == .none && selection.ids.contains(id)
            if !keepGroup {
                selection.click(id, modifier, order: order)
                showSelection()
            }
            gesture = .pressedItem(start: p, hit: id, narrowOnUp: keepGroup)
        case (nil, true):
            gesture = .pan(last: p)
        case (nil, false):
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
        case .connecting(let from, _):
            gesture = .connecting(from: from, to: p)
            renderLines()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if spaceHeld { NSCursor.openHand.set() }
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
        case .connecting(let from, _):
            let p = convert(event.locationInWindow, from: nil)
            if let to = hit(p), to != from,
               !links.contains(where: { Set([$0.a, $0.b]) == Set([from, to]) }) {
                links.append(CanvasLink(a: from, b: to))
                library.setLinks(links, key: scope.canvasKey)
            }
        default:
            break
        }
        gesture = .none
        renderLines()
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
            m.fillColor = resolved(NSColor.controlAccentColor.withAlphaComponent(0.15))
            m.strokeColor = resolved(.controlAccentColor)
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
        if reloadAfterDrop {
            reloadAfterDrop = false
            reload()
        }
    }

    // MARK: Menus & keys

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if hit(p) == nil, let line = link(at: p) {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("刪除這條連線") { [weak self] in
                guard let self else { return }
                self.links.removeAll { $0 == line }
                self.library.setLinks(self.links, key: self.scope.canvasKey)
                self.renderLines()
            })
            return menu
        }
        guard let id = hit(p) else {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("依主題分堆") { [weak self] in self?.clusterByTheme(nil) })
            if !relationLinks.isEmpty {
                menu.addItem(ClosureMenuItem("依關聯分堆") { [weak self] in self?.clusterByRelation(nil) })
            }
            menu.addItem(ClosureMenuItem("整理成整齊的排列") { [weak self] in self?.arrange(nil) })
            menu.addItem(ClosureMenuItem("顯示全部") { [weak self] in self?.fit(animated: true) })
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "按住 ⌥ 從一件拖到另一件，可以連起來", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return menu
        }
        if !selection.ids.contains(id) {
            selection.click(id, .none, order: order)
            showSelection()
        }
        return ItemActions.menu(for: selection.ordered(order), board: board, library: library, window: window) { [weak self] in
            self?.onOpen?(id)
        } similar: { [weak self] in
            self?.onSimilar?(id)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            guard !event.isARepeat, !spaceHeld else { return }
            spaceHeld = true
            spacePanned = false
            NSCursor.openHand.set()
        case 51, 117:
            deleteSelection()
        case 36, 76:
            if let id = selection.anchor ?? selection.ordered(order).first { onActivate?(id) }
        case 15 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            onRandom?()
        case 53:
            selection = Selection()
            showSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49, spaceHeld else { return super.keyUp(with: event) }
        releaseSpace()
        if !spacePanned, let id = selection.anchor ?? selection.ordered(order).first { onOpen?(id) }
    }

    private func releaseSpace() {
        spaceHeld = false
        NSCursor.arrow.set()
    }

    // Focus gone mid-hold: the key-up may never come.
    override func resignFirstResponder() -> Bool {
        if spaceHeld { spacePanned = true; releaseSpace() }
        return super.resignFirstResponder()
    }

    var debugOffset: CGPoint { offset }

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
