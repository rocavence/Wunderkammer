import AppKit
import QuartzCore

/// The grid: justified rows drawn as plain CALayers. Only tiles near the
/// viewport exist, so scrolling cost doesn't grow with library size. Zooming
/// changes the row height and every tile animates from where it was to where
/// it now belongs.
@MainActor
final class GridView: NSView, ItemSurface, CabinetSurface, NSDraggingSource {
    static let minRowHeight: CGFloat = 48
    static let maxRowHeight: CGFloat = 1400

    let library: Library
    let pool: TilePool
    var onOpen: ((UUID) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var onRandom: (() -> Void)?
    var onFocus: ((UUID?) -> Void)?
    var onSimilar: ((UUID) -> Void)?

    private(set) var scope = Scope()
    var board: UUID? { scope.board }
    /// Grid, Masonry or Timeline. Changing it flies every tile to its new place.
    var style: CabinetStyle = .grid {
        didSet { if style != oldValue { relayout(animated: true, anchor: nil) } }
    }
    private(set) var headers: [CabinetLayout.Header] = []
    private var headerLayers: [Int: HeadingBand] = [:]
    private var spatial = SpatialIndex()
    private(set) var items: [Item] = []
    private(set) var frames: [CGRect] = []
    /// Atlas sizes its grid around a 156 pt row.
    private(set) var rowHeight: CGFloat = 156
    private(set) var selection = Selection()

    private var layoutWidth: CGFloat = 0
    private var isRelayingOut = false
    private var order: [UUID] { items.map(\.id) }

    // Mouse tracking
    private var downPoint: NSPoint?
    private var downHit: UUID?
    private var marquee: CAShapeLayer?
    private var marqueeBase: Set<UUID> = []

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        pool = TilePool(library: library, thumbnailer: thumbnailer)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        pool.host = layer
        pool.colors = { [unowned self] in self.resolved($0) }
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff, .init("public.jpeg"), .init("public.heic"), .init("com.compuserve.gif")])
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(animated: true) }
        }
        items = library.items(in: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        pool.refreshColors()
        appearanceChanged()
        renderHeading()
    }
    override var acceptsFirstResponder: Bool { true }
    /// Clicking into an inactive window selects/drags right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    /// The heading pinned at the top right now (tests).
    var pinnedHeading: String? {
        headerLayers.values.first(where: \.isPinned)?.title
    }

    private func appearanceChanged() {
        for layer in headerLayers.values { layer.removeFromSuperlayer() }
        headerLayers = [:]
        updateTiles(animated: false)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Our own scroll during a relayout is handled by the relayout itself.
                guard !self.isRelayingOut else { return }
                if self.isLiveZooming { self.applyLiveZoom() } else { self.updateTiles(animated: false) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutIfWidthChanged() }
        }
        relayoutIfWidthChanged()
    }

    override func updateLayer() {
        layer?.backgroundColor = resolved(.windowBackgroundColor)
    }

    // MARK: Layout

    func show(scope: Scope) {
        // Only the search changed: filter in place, tiles fly to their new spots.
        if scope.base == self.scope.base, superview != nil, !items.isEmpty || scope.isSearching {
            self.scope = scope
            reload(animated: true)
            scrollToTop()
            return
        }
        self.scope = scope
        selection = Selection()
        pool.removeAll()
        items = library.items(for: scope)
        relayout(animated: false, anchor: nil)
        scrollToTop()
        needsDisplay = true
    }

    private func scrollToTop() {
        if let clip = superview as? NSClipView {
            clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func reload(animated: Bool) {
        items = library.items(for: scope)
        selection.restrict(to: Set(order))
        relayout(animated: animated, anchor: nil)
        needsDisplay = true
    }

    private func relayoutIfWidthChanged() {
        guard let clip = superview else { return }
        if clip.bounds.width != layoutWidth { relayout(animated: false, anchor: nil) }
    }

    /// `anchor`: a point in this view's coordinates that should stay over the
    /// same spot of the same image after the relayout (cursor during zoom).
    // MARK: Title

    /// The view's name, large, at the top of the cabinet; scrolls away with it.
    var heading: (title: String, detail: String) = ("", "") {
        didSet { if heading != oldValue { renderHeading() } }
    }
    static let headingHeight: CGFloat = 78
    private let titleLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private let tipLayer = CATextLayer()

    /// One quiet suggestion at the right of the title: what else the cabinet can do.
    var tip = "" { didSet { if tip != oldValue { renderHeading() } } }

    /// What can be done right here, in 收藏.
    static let tips = [
        "按 R 隨機重看一件",
        "在搜尋框問問題，例如：我收過哪些書？",
        "選一件，按 ⌘I 看它和什麼有關",
        "捏合或 ⌘ 加捲動來放大縮小",
        "空白鍵預覽，Return 用原本的 app 打開",
    ]

    private func renderHeading() {
        guard let root = layer else { return }
        withoutAnimation {
            for t in [titleLayer, detailLayer, tipLayer] where t.superlayer == nil {
                t.contentsScale = window?.backingScaleFactor ?? 2
                t.truncationMode = .end
                root.addSublayer(t)
            }
            let size: CGFloat = 30
            let serif = Typography.display(size) ?? .systemFont(ofSize: size)
            titleLayer.string = NSAttributedString(string: heading.title, attributes: [
                .font: serif, .foregroundColor: NSColor(cgColor: resolved(.labelColor)) ?? .labelColor, .kern: 0.2,
            ])
            detailLayer.string = NSAttributedString(string: heading.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor(cgColor: resolved(.secondaryLabelColor)) ?? .secondaryLabelColor,
            ])
            let inset = CabinetLayout(style: style, width: 0, size: 0).inset
            titleLayer.frame = CGRect(x: inset + 2, y: 10, width: max(bounds.width - inset * 2, 0), height: 40)
            detailLayer.frame = CGRect(x: inset + 3, y: 50, width: max(bounds.width - inset * 2, 0), height: 18)
            let tipStyle = NSMutableParagraphStyle()
            tipStyle.alignment = .right
            tipLayer.string = NSAttributedString(string: tip, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: tipStyle,
                .foregroundColor: NSColor(cgColor: resolved(.secondaryLabelColor)) ?? .secondaryLabelColor,
            ])
            tipLayer.alignmentMode = .right
            tipLayer.frame = CGRect(x: bounds.width / 2, y: 50, width: max(bounds.width / 2 - inset - 2, 0), height: 18)
        }
    }

    private func relayout(animated: Bool, anchor: NSPoint?) {
        guard let clip = superview as? NSClipView else { return }
        isRelayingOut = true
        defer { isRelayingOut = false }
        layoutWidth = clip.bounds.width

        var anchorIndex: Int?
        var anchorFraction: CGFloat = 0.5
        var anchorOnScreenY: CGFloat = 0
        if let anchor, let i = nearestIndex(to: anchor) {
            let f = frames[i]
            anchorIndex = i
            anchorFraction = (anchor.y - f.minY) / max(f.height, 1)
            anchorOnScreenY = anchor.y - clip.bounds.minY
        }

        let size = style == .masonry ? rowHeight * 1.15 : rowHeight
        let result = CabinetLayout(style: style, width: layoutWidth, size: size)
            .layout(aspects: items.map(\.aspect), dates: items.map(\.dateAdded))
        // Everything sits below the title.
        let top = Self.headingHeight
        frames = result.frames.map { $0.offsetBy(dx: 0, dy: top) }
        headers = result.headers.map { var h = $0; h.frame = h.frame.offsetBy(dx: 0, dy: top); return h }
        spatial = SpatialIndex(frames)
        setFrameSize(NSSize(width: layoutWidth, height: max(result.height + top, clip.bounds.height - clip.contentInsets.top)))
        renderHeading()

        if let i = anchorIndex, frames.indices.contains(i) {
            let f = frames[i]
            let y = f.minY + anchorFraction * f.height - anchorOnScreenY
            // Under a transparent titlebar the top of the scroll range is -inset, not 0.
            let minY = -clip.contentInsets.top
            let maxY = max(bounds.height - clip.bounds.height, minY)
            let newY = min(max(y, minY), maxY)
            // Tiles are in document coordinates, so a scroll jump would move them
            // on screen. Shift them by the same amount first so they start the
            // animation exactly where they appear.
            let oldY = clip.bounds.minY
            clip.scroll(to: NSPoint(x: 0, y: newY))
            enclosingScrollView?.reflectScrolledClipView(clip)
            // The clip view may adjust the requested offset; compensate the real one.
            if animated { pool.rebase(dy: clip.bounds.minY - oldY) }
        }
        updateTiles(animated: animated)
    }

    private func nearestIndex(to p: NSPoint) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let hit = index(at: p) { return hit }
        let range = indices(in: NSRect(x: 0, y: p.y - rowHeight, width: bounds.width, height: rowHeight * 2))
        let pool = range.isEmpty ? Array(frames.indices) : range
        return pool.min { distance(frames[$0], p) < distance(frames[$1], p) }
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(r.midX - p.x, r.midY - p.y)
    }

    func index(at p: NSPoint) -> Int? {
        indices(in: NSRect(x: p.x, y: p.y, width: 1, height: 1)).first { frames[$0].contains(p) }
    }

    private func indices(in rect: NSRect) -> [Int] {
        spatial.indices(in: rect)
    }

    private func updateTiles(animated: Bool) {
        guard let clip = superview else { return }
        hoverVideo.stop()
        showCaption(for: nil)
        guard !isHiddenOrHasHiddenAncestor else {
            pool.removeAll()
            return
        }
        let visible = clip.bounds.insetBy(dx: 0, dy: -clip.bounds.height)
        let placements = indices(in: visible).map { i in
            TilePool.Placement(key: items[i].id.uuidString, item: items[i], frame: frames[i],
                               selected: selection.ids.contains(items[i].id))
        }
        pool.apply(placements, animated: animated, scale: window?.backingScaleFactor ?? 2, spring: animated)
        updateHeaders(in: visible, animated: animated)
    }

    /// Timeline headings: a row per day, the date in serif with how many
    /// beside it. The current day's row stays at the top, on a solid band that
    /// fades into the pictures, until the next day's pushes it up.
    private func updateHeaders(in visible: CGRect, animated: Bool) {
        guard let root = layer else { return }
        var keep = Set<Int>()
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(TilePool.animation)
        let top = (superview?.bounds.minY ?? 0) + ((superview as? NSClipView)?.contentInsets.top ?? 0)
        let colors = HeadingBand.Colors(text: resolved(.labelColor), detail: resolved(.secondaryLabelColor),
                                        band: resolved(.windowBackgroundColor))
        for (i, h) in headers.enumerated() {
            // The band spans the whole width; the words keep the grid's margins.
            var frame = CGRect(x: 0, y: h.frame.minY, width: bounds.width, height: h.frame.height)
            var pinned = false
            if frame.minY < top {
                let next = headers[safe: i + 1]?.frame.minY ?? .greatestFiniteMagnitude
                guard next > top else { continue }
                frame.origin.y = min(top, next - frame.height)
                pinned = true
            }
            guard frame.intersects(visible) else { continue }
            keep.insert(i)
            let band = headerLayers[i] ?? {
                let b = HeadingBand(scale: window?.backingScaleFactor ?? 2)
                root.addSublayer(b)
                headerLayers[i] = b
                return b
            }()
            band.frame = frame
            band.show(title: h.title, detail: h.detail, inset: h.frame.minX, pinned: pinned, colors: colors)
        }
        for (i, layer) in headerLayers where !keep.contains(i) {
            layer.removeFromSuperlayer()
            headerLayers[i] = nil
        }
        CATransaction.commit()
    }

    private func showSelection() {
        pool.setSelected(Set(selection.ids.map(\.uuidString)))
        onFocus?(selection.anchor ?? selection.ordered(order).first)
    }

    /// From the search field into the results.
    func focusFirst() {
        guard let first = items.first else { return }
        selection.set([first.id], anchor: first.id)
        showSelection()
        scrollToVisible(first.id)
    }

    // MARK: ItemSurface

    var shownItems: [Item] { items }

    func rectInWindow(for id: UUID) -> NSRect? {
        guard let i = order.firstIndex(of: id) else { return nil }
        return convert(frames[i], to: nil)
    }

    func currentImage(for id: UUID) -> CGImage? { pool.image(id.uuidString) }

    func reveal(_ id: UUID) {
        selection.set([id], anchor: id)
        showSelection()
        scrollToVisible(id)
    }

    func previewWillOpen(_ id: UUID) {
        guard let i = order.firstIndex(of: id) else { return }
        pool.scatter(from: CGPoint(x: frames[i].midX, y: frames[i].midY), hiding: id.uuidString)
    }

    func previewWillClose(landingOn id: UUID) {
        pool.gather(landing: id.uuidString)
    }

    func previewDidClose() {
        pool.revealHidden()
        updateTiles(animated: false)
    }

    private func scrollToVisible(_ id: UUID) {
        guard let i = order.firstIndex(of: id) else { return }
        scrollToVisible(frames[i].insetBy(dx: 0, dy: -16))
    }

    // MARK: Zoom

    /// Live zoom (pinch, ⌘-scroll on a trackpad): tiles just scale around the
    /// cursor every frame, no reflow and no animation, so it tracks the fingers.
    /// When the gesture ends or pauses, the grid reflows once and animates there.
    private var liveScale: CGFloat = 1
    private var liveAnchor: NSPoint?
    private var commitWork: DispatchWorkItem?

    var isLiveZooming: Bool { liveAnchor != nil }

    /// Discrete step (menu, mouse wheel): one animated reflow.
    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        commitLiveZoom()
        let next = min(max(rowHeight * factor, Self.minRowHeight), Self.maxRowHeight)
        guard next != rowHeight else { return }
        rowHeight = next
        let point = anchor ?? superview.map { NSPoint(x: $0.bounds.midX, y: $0.bounds.midY) }
        relayout(animated: true, anchor: point)
    }

    func liveZoom(by factor: CGFloat, around p: NSPoint) {
        if liveAnchor == nil {
            liveAnchor = p
            liveScale = 1
        }
        let target = min(max(rowHeight * liveScale * factor, Self.minRowHeight), Self.maxRowHeight)
        liveScale = target / rowHeight
        applyLiveZoom()
        // Reflow when the fingers pause, not only when they lift.
        commitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.commitLiveZoom() } }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func commitLiveZoom() {
        commitWork?.cancel()
        commitWork = nil
        guard let anchor = liveAnchor else { return }
        liveAnchor = nil
        let scale = liveScale
        liveScale = 1
        guard abs(scale - 1) > 0.001 else { return updateTiles(animated: false) }
        rowHeight = min(max(rowHeight * scale, Self.minRowHeight), Self.maxRowHeight)
        // The point under the cursor is the scaling center, so it maps to itself:
        // anchoring on it keeps that image under the cursor through the reflow.
        relayout(animated: true, anchor: anchor)
    }

    private func applyLiveZoom() {
        guard let a = liveAnchor, let clip = superview else { return }
        stopHover()
        let s = liveScale
        let visible = clip.bounds.insetBy(dx: 0, dy: -clip.bounds.height / 2)
        // Which laid-out tiles land on screen once scaled around `a`.
        let source = CGRect(x: a.x + (visible.minX - a.x) / s, y: a.y + (visible.minY - a.y) / s,
                            width: visible.width / s, height: visible.height / s)
        let placements = indices(in: source).map { i in
            let f = frames[i]
            return TilePool.Placement(
                key: items[i].id.uuidString, item: items[i],
                frame: CGRect(x: a.x + (f.minX - a.x) * s, y: a.y + (f.minY - a.y) * s,
                              width: f.width * s, height: f.height * s),
                selected: selection.ids.contains(items[i].id))
        }
        pool.apply(placements, animated: false, scale: window?.backingScaleFactor ?? 2)
        withoutAnimation { for h in headerLayers.values { h.opacity = 0 } }
    }

    override func magnify(with event: NSEvent) {
        liveZoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
        if event.phase == .ended || event.phase == .cancelled { commitLiveZoom() }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            if event.hasPreciseScrollingDeltas {
                liveZoom(by: 1 + event.scrollingDeltaY / 200, around: p)
            } else {
                zoom(by: 1 + event.scrollingDeltaY / 20, around: p)
            }
        } else {
            commitLiveZoom()
            super.scrollWheel(with: event)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitLiveZoom()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let hit = index(at: p).map { items[$0].id }
        let modifier = Selection.modifier(event.modifierFlags)
        downPoint = p
        downHit = hit

        if event.clickCount == 2, let hit {
            onOpen?(hit)
            return
        }
        // Clicking an already-selected tile keeps the group, so it can be dragged;
        // mouseUp narrows it to one if no drag happened.
        if let hit, modifier == .none, selection.ids.contains(hit) { return }
        selection.click(hit, modifier, order: order)
        showSelection()
        if hit == nil { marqueeBase = modifier == .none ? [] : selection.ids }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if downHit != nil {
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            downPoint = nil
            beginItemDrag(event)
        } else {
            autoscroll(with: event)
            updateMarquee(from: start, to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let hit = downHit, downPoint != nil, Selection.modifier(event.modifierFlags) == .none, event.clickCount < 2 {
            selection.click(hit, .none, order: order)
            showSelection()
        }
        marquee?.removeFromSuperlayer()
        marquee = nil
        downPoint = nil
        downHit = nil
    }

    private func updateMarquee(from a: NSPoint, to b: NSPoint) {
        let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if marquee == nil {
            let m = CAShapeLayer()
            m.fillColor = resolved(NSColor.controlAccentColor.withAlphaComponent(0.15))
            m.strokeColor = resolved(.controlAccentColor)
            m.lineWidth = 1
            m.zPosition = 100
            layer?.addSublayer(m)
            marquee = m
        }
        withoutAnimation { marquee?.path = CGPath(rect: rect, transform: nil) }
        let hits = indices(in: rect).filter { frames[$0].intersects(rect) }.map { items[$0].id }
        selection.set(marqueeBase.union(hits), anchor: hits.first)
        showSelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { return nil }
        let id = items[i].id
        if !selection.ids.contains(id) {
            selection.click(id, .none, order: order)
            showSelection()
        }
        let ids = selection.ordered(order)
        return ItemActions.menu(for: ids, board: board, library: library, window: window) { [weak self] in
            self?.onOpen?(id)
        } similar: { [weak self] in
            self?.onSimilar?(id)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // space
            if let id = selection.anchor ?? selection.ordered(order).first { onOpen?(id) }
        case 51, 117: // delete, forward delete
            deleteSelection()
        case 36, 76: // return, enter
            if let id = selection.anchor ?? selection.ordered(order).first { onActivate?(id) }
        case 15 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty: // R
            onRandom?()
        case 123: moveSelection(-1, event)
        case 124: moveSelection(1, event)
        case 125: moveSelectionVertically(down: true, event)
        case 126: moveSelectionVertically(down: false, event)
        default: super.keyDown(with: event)
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

    private func moveSelection(_ delta: Int, _ event: NSEvent) {
        guard !items.isEmpty else { return }
        let current = selection.anchor.flatMap(order.firstIndex(of:)) ?? -delta
        select(index: min(max(current + delta, 0), items.count - 1), event)
    }

    private func moveSelectionVertically(down: Bool, _ event: NSEvent) {
        guard let s = selection.anchor.flatMap(order.firstIndex(of:)) else { return moveSelection(1, event) }
        let f = frames[s]
        let probe = NSPoint(x: f.midX, y: down ? f.maxY + rowHeight / 2 + 8 : f.minY - rowHeight / 2 - 8)
        if let n = nearestIndex(to: probe), frames[n].minY != f.minY { select(index: n, event) }
    }

    private func select(index: Int, _ event: NSEvent) {
        let id = items[index].id
        if event.modifierFlags.contains(.shift) {
            selection.ids.insert(id)
            selection.anchor = id
        } else {
            selection.set([id], anchor: id)
        }
        showSelection()
        scrollToVisible(id)
    }

    // MARK: Hover

    private let hoverVideo = HoverVideo()
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // Not under an open preview, not mid-pinch.
        guard let root = layer, !isLiveZooming, window?.firstResponder === self else { return stopHover() }
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        let item = i.map { items[$0] }
        hoverVideo.hover(item, url: item.flatMap(library.originalURL), frame: i.map { frames[$0] } ?? .zero, in: root)
        showCaption(for: i)
    }

    /// Stops the hover video and hides the title (hidden, preview opened, pinch).
    func stopHover() {
        hoverVideo.stop()
        showCaption(for: nil)
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopHover()
    }

    override func mouseExited(with event: NSEvent) {
        hoverVideo.stop()
        showCaption(for: nil)
    }

    private let caption = CALayer()
    private var captionIndex: Int?

    /// The title of what's under the pointer, at the foot of its tile. Only
    /// for things with a real title (a photo's file name says little).
    private func showCaption(for index: Int?) {
        guard index != captionIndex else { return }
        captionIndex = index
        guard let i = index, frames.indices.contains(i), frames[i].width > 120, frames[i].height > 70,
              items[i].kind != .image || items[i].title != nil || scope.isSearching, let root = layer else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            caption.opacity = 0
            CATransaction.commit()
            return
        }
        let f = frames[i]
        withoutAnimation {
            if caption.superlayer == nil {
                caption.zPosition = 4
                caption.cornerRadius = 6
                caption.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                caption.masksToBounds = true
                let shade = CAGradientLayer()
                shade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.82)]
                shade.name = "shade"
                let text = CATextLayer()
                text.name = "text"
                text.truncationMode = .end
                text.isWrapped = false
                caption.addSublayer(shade)
                caption.addSublayer(text)
                caption.opacity = 0
                root.addSublayer(caption)
            }
            let h: CGFloat = 60
            caption.frame = CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
            caption.sublayers?.first { $0.name == "shade" }?.frame = caption.bounds
            if let text = caption.sublayers?.first(where: { $0.name == "text" }) as? CATextLayer {
                text.contentsScale = window?.backingScaleFactor ?? 2
                // The title, then what it is and where it's from: 電影 · letterboxd.com · 1999.
                let item = items[i]
                // Searching, the second line says why it's here.
                let about = scope.isSearching ? [Search.reason(scope.search, item)]
                    : [item.thing?.title, item.domain, item.released.map { String($0.prefix(4)) }].compactMap { $0 }
                let line = NSMutableAttributedString(string: item.displayTitle, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white,
                ])
                if !about.isEmpty {
                    line.append(NSAttributedString(string: "\n" + about.joined(separator: " · "), attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.72),
                    ]))
                }
                text.isWrapped = true
                text.string = line
                text.frame = CGRect(x: 10, y: about.isEmpty ? h - 22 : h - 38, width: f.width - 20, height: about.isEmpty ? 16 : 32)
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        caption.opacity = 1
        CATransaction.commit()
    }

    /// Whatever moves the tiles stops the hover video (tests read this too).
    var hoverPlaying: UUID? { hoverVideo.playing }

    // MARK: Accessibility

    /// The tiles are layers, invisible to VoiceOver: describe the visible ones.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "收藏" }

    override func accessibilityChildren() -> [Any]? {
        guard let clip = superview else { return [] }
        return indices(in: clip.bounds).map { i in
            let item = items[i]
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.image)
            e.setAccessibilityParent(self)
            let kind = InspectorViewController.facts(item, library: library).first?.1 ?? ""
            e.setAccessibilityLabel([item.displayTitle, kind, TilePool.badgeText(item)].compactMap { $0 }.joined(separator: "，"))
            e.setAccessibilityFrameInParentSpace(frames[i])
            e.setAccessibilitySelected(selection.ids.contains(item.id))
            return e
        }
    }

    // MARK: Empty state

    override func draw(_ dirtyRect: NSRect) {
        guard items.isEmpty else { return }
        let text = EmptyState.message(for: scope) as NSString
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let size = text.boundingRect(with: NSSize(width: 460, height: 200), options: .usesLineFragmentOrigin, attributes: attrs).size
        let visible = visibleRect
        text.draw(in: NSRect(x: visible.midX - 230, y: visible.midY - size.height / 2, width: 460, height: size.height), withAttributes: attrs)
    }

    // MARK: Drag out

    private func beginItemDrag(_ event: NSEvent) {
        let ids = selection.ordered(order)
        let scale = window?.backingScaleFactor ?? 2
        let draggingItems: [NSDraggingItem] = ids.prefix(50).enumerated().compactMap { n, id in
            guard let item = library.item(id), let i = order.firstIndex(of: id) else { return nil }
            let d = NSDraggingItem(pasteboardWriter: ItemActions.pasteboardItem(for: item, library: library))
            let image = pool.image(id.uuidString).map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale)) }
            d.setDraggingFrame(frames[i], contents: image)
            return d
        }
        guard !draggingItems.isEmpty else { return }
        beginDraggingSession(with: draggingItems, event: event, source: self).draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: Drop & paste

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? GridView) === self ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        importFrom(sender.draggingPasteboard)
    }

    @objc func paste(_ sender: Any?) {
        _ = importFrom(NSPasteboard.general)
    }

    private func importFrom(_ pasteboard: NSPasteboard) -> Bool {
        importPasteboard(pasteboard, library: library, board: board)
    }
}

/// Our own items join the board; anything else (files, images, links, text)
/// becomes new curiosities, in the board being looked at.
@MainActor
func importPasteboard(_ pasteboard: NSPasteboard, library: Library, board: UUID?) -> Bool {
    let own = ItemActions.ids(from: pasteboard)
    if !own.isEmpty {
        if let board { library.add(own, to: board) }
        return board != nil
    }
    let sources = PasteboardReader.sources(from: pasteboard)
    guard !sources.isEmpty else { return false }
    Task { await library.capture(sources, into: board) }
    return true
}

/// One day's heading row in the timeline.
@MainActor
private final class HeadingBand: CALayer {
    struct Colors {
        var text, detail, band: CGColor
    }

    private let titleLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    /// Under a pinned band: the pictures fade in rather than being cut off.
    private let fade = CAGradientLayer()
    private(set) var title = ""
    private(set) var isPinned = false

    init(scale: CGFloat) {
        super.init()
        zPosition = 20
        for t in [titleLayer, detailLayer] {
            t.contentsScale = scale
            t.truncationMode = .end
            addSublayer(t)
        }
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        addSublayer(fade)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, detail: String, inset: CGFloat, pinned: Bool, colors: Colors) {
        self.title = title
        isPinned = pinned
        let serif = Typography.display(20) ?? .systemFont(ofSize: 20)
        let small = NSFont.systemFont(ofSize: 12.5)
        let titleText = NSAttributedString(string: title, attributes: [.font: serif, .foregroundColor: NSColor(cgColor: colors.text) ?? .labelColor])
        titleLayer.string = titleText
        detailLayer.string = NSAttributedString(string: detail, attributes: [.font: small, .foregroundColor: NSColor(cgColor: colors.detail) ?? .secondaryLabelColor])
        // The serif's line, centred in the row; the detail shares its baseline.
        let lineHeight = ceil(serif.ascender - serif.descender + serif.leading)
        let titleWidth = ceil(titleText.size().width) + 2
        let titleY = (bounds.height - lineHeight) / 2
        titleLayer.frame = CGRect(x: inset + 2, y: titleY, width: min(titleWidth, bounds.width - inset * 2), height: lineHeight)
        let baseline = titleY + serif.ascender
        let detailHeight = ceil(small.ascender - small.descender) + 2
        detailLayer.frame = CGRect(x: titleLayer.frame.maxX + 10, y: baseline - small.ascender - 1,
                                   width: max(bounds.width - inset - titleLayer.frame.maxX - 10, 0), height: detailHeight)
        backgroundColor = pinned ? colors.band : nil
        fade.isHidden = !pinned
        fade.frame = CGRect(x: 0, y: bounds.height, width: bounds.width, height: 18)
        fade.colors = [colors.band, colors.band.copy(alpha: 0)!]
    }
}
