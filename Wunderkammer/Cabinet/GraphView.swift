import AppKit
import QuartzCore

/// Your culture graph: the themes, names and sites in the cabinet, linked by
/// the curiosities they share. Each node wears its most recent curiosity.
/// Drag or scroll to move, pinch to zoom, click a node to see its curiosities.
@MainActor
final class GraphView: NSView {
    let library: Library
    let thumbnailer: Thumbnailer
    var onOpenView: ((Scope.Base) -> Void)?

    private(set) var graph = CultureGraph(nodes: [], edges: [])
    private var offset = CGPoint.zero
    private var zoom: CGFloat = 1
    private let edgesLayer = CAShapeLayer()
    private var nodeLayers: [String: (circle: CALayer, ring: CAShapeLayer, label: CATextLayer)] = [:]
    private var dirty = true
    private var dragStart: NSPoint?
    private var dragLast: NSPoint?

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        self.thumbnailer = thumbnailer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        edgesLayer.fillColor = nil
        edgesLayer.lineCap = .round
        layer?.addSublayer(edgesLayer)
        let refresh: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(forName: Understanding.didProgress, object: nil, queue: .main, using: refresh)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if dirty { rebuild() } else { render() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        for (_, l) in nodeLayers { l.label.removeFromSuperlayer(); l.circle.removeFromSuperlayer(); l.ring.removeFromSuperlayer() }
        nodeLayers = [:]
        render()
    }

    // MARK: Model

    private var rebuildWork: DispatchWorkItem?

    /// Changes come in bursts (analysis, enrichment): rebuild once they settle,
    /// and only when the graph is on screen.
    private func scheduleRebuild() {
        dirty = true
        guard !isHiddenOrHasHiddenAncestor else { return }
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuild(keepCamera: true) } }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func rebuild(keepCamera: Bool = false) {
        dirty = false
        let hadNodes = !graph.nodes.isEmpty
        var g = CultureGraph.build(from: library.items, subjects: Subjects.discover(in: library.items, limit: 12))
        // Few nodes sit close together; many get room.
        let side = max(520, CGFloat(g.nodes.count).squareRoot() * 360)
        g.layout(size: CGSize(width: side * 1.4, height: side))
        graph = g
        // Nodes that are still there keep their layers (no flicker).
        let ids = Set(g.nodes.map(\.id))
        for (id, l) in nodeLayers where !ids.contains(id) {
            l.label.removeFromSuperlayer(); l.circle.removeFromSuperlayer(); l.ring.removeFromSuperlayer()
            nodeLayers[id] = nil
        }
        if keepCamera, hadNodes { render() } else { fit() }
        needsDisplay = true
    }

    private func radius(_ node: CultureGraph.Node) -> CGFloat {
        24 + CGFloat(node.items.count).squareRoot() * 12
    }

    private func fit() {
        guard !graph.nodes.isEmpty, bounds.width > 0 else { return render() }
        let xs = graph.nodes.map(\.position.x), ys = graph.nodes.map(\.position.y)
        let content = CGRect(x: xs.min()! - 120, y: ys.min()! - 120, width: xs.max()! - xs.min()! + 240, height: ys.max()! - ys.min()! + 240)
        let top = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0
        // Room at the foot for the legend.
        let legendRoom: CGFloat = 44
        zoom = min(1.2, max(0.2, min(bounds.width / content.width, (bounds.height - top - legendRoom) / content.height)))
        offset = CGPoint(x: content.midX - bounds.width / zoom / 2, y: content.midY - (bounds.height + top - legendRoom) / zoom / 2)
        render()
    }

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) * zoom, y: (p.y - offset.y) * zoom)
    }

    // MARK: Drawing

    private func color(_ kind: CultureGraph.Kind) -> NSColor {
        switch kind {
        // Three kinds, three colours that can't be mistaken (the accent may be orange too).
        case .theme: .systemIndigo
        case .name: .systemTeal
        case .site: .systemGray
        }
    }

    /// The dozen biggest nodes keep their names when zoomed out.
    private var labelledWhenFar: Set<String> {
        Set(graph.nodes.sorted { $0.items.count > $1.items.count }.prefix(12).map(\.id))
    }

    private let legend = NSTextField(labelWithString: "")

    /// What the colours mean, and that the map covers the whole cabinet.
    private func renderLegend() {
        if legend.superview == nil {
            legend.translatesAutoresizingMaskIntoConstraints = false
            addSubview(legend)
            NSLayoutConstraint.activate([
                legend.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                legend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            ])
        }
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11.5)
        for (name, kind) in [("主題", CultureGraph.Kind.theme), ("名字", .name), ("網站", .site)] {
            text.append(NSAttributedString(string: "●", attributes: [.font: font, .foregroundColor: color(kind)]))
            text.append(NSAttributedString(string: " \(name)    ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        text.append(NSAttributedString(string: "整個珍奇室的關係，線越粗共有的收藏越多", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        legend.attributedStringValue = text
        legend.isHidden = graph.nodes.isEmpty
    }

    private func render() {
        guard let root = layer, !isHiddenOrHasHiddenAncestor else { return }
        renderLegend()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        // Thicker lines for more shared curiosities: one sublayer per weight.
        edgesLayer.frame = bounds
        edgesLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for weight in Set(graph.edges.map(\.weight)) {
            let path = CGMutablePath()
            for e in graph.edges where e.weight == weight {
                path.move(to: toScreen(graph.nodes[e.a].position))
                path.addLine(to: toScreen(graph.nodes[e.b].position))
            }
            let line = CAShapeLayer()
            line.path = path
            line.fillColor = nil
            line.strokeColor = resolved(NSColor.tertiaryLabelColor)
            line.lineWidth = max(1, (1 + log2(CGFloat(weight))) * 1.2 * zoom)
            edgesLayer.addSublayer(line)
        }

        // Labels go biggest node first; one that would land on another label or
        // circle stays hidden rather than overprint.
        let circles = graph.nodes.map { n -> (String, CGRect) in
            let r = radius(n) * zoom, c = toScreen(n.position)
            return (n.id, CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        var placed: [CGRect] = []
        var clear: Set<String> = []
        let labelSize = min(max(13 * zoom, 10), 18)
        for node in graph.nodes.sorted(by: { $0.items.count > $1.items.count }) {
            let r = radius(node) * zoom, c = toScreen(node.position)
            let text = "\(node.title)  \(node.items.count)" as NSString
            let serif = NSFont.systemFont(ofSize: labelSize).fontDescriptor.withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: labelSize) } ?? .systemFont(ofSize: labelSize)
            let width = text.size(withAttributes: [.font: serif]).width + 12
            let rect = CGRect(x: c.x - width / 2, y: c.y + r + 4, width: width, height: labelSize * 1.5)
            guard !placed.contains(where: { $0.intersects(rect) }),
                  !circles.contains(where: { $0.0 != node.id && $0.1.intersects(rect) }) else { continue }
            placed.append(rect)
            clear.insert(node.id)
        }

        for node in graph.nodes {
            let r = radius(node) * zoom
            let c = toScreen(node.position)
            let layers = nodeLayers[node.id] ?? makeNode(node, in: root)
            layers.circle.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            // Shape tells the kind too, not colour alone: sites are rounded squares.
            let corner = node.kind == .site ? r * 0.32 : r
            layers.circle.cornerRadius = corner
            layers.ring.frame = layers.circle.frame
            layers.ring.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: r * 2, height: r * 2),
                                      cornerWidth: corner, cornerHeight: corner, transform: nil)
            layers.ring.lineWidth = max(2, 3 * zoom)
            let size = min(max(13 * zoom, 10), 18)
            let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
            let text = NSAttributedString(string: "\(node.title)  \(node.items.count)", attributes: [
                .font: serif ?? NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(cgColor: resolved(.labelColor)) ?? NSColor.labelColor,
            ])
            layers.label.string = text
            // A backing just the size of the words, so lines passing under don't cut through them.
            let w = ceil(text.size().width) + 12
            layers.label.frame = CGRect(x: c.x - w / 2, y: c.y + r + 4, width: w, height: size * 1.5)
            layers.label.backgroundColor = resolved(.windowBackgroundColor).copy(alpha: 0.78)
            layers.label.cornerRadius = 4
            // Zoomed out, only the biggest are named; closer in, all of them.
            layers.label.isHidden = zoom < 0.15 || (zoom < 0.6 && !labelledWhenFar.contains(node.id)) || !clear.contains(node.id)
        }
        CATransaction.commit()
    }

    private func makeNode(_ node: CultureGraph.Node, in root: CALayer) -> (circle: CALayer, ring: CAShapeLayer, label: CATextLayer) {
        let circle = CALayer()
        circle.masksToBounds = true
        circle.contentsGravity = .resizeAspectFill
        circle.backgroundColor = resolved(.quaternaryLabelColor)
        circle.zPosition = 2
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = resolved(color(node.kind))
        ring.zPosition = 3
        let label = CATextLayer()
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.zPosition = 4
        for l in [circle, ring, label] as [CALayer] { root.addSublayer(l) }
        let layers = (circle, ring, label)
        nodeLayers[node.id] = layers
        // The most recent curiosity of this node is its face.
        if let face = node.items.compactMap(library.item).max(by: { $0.dateAdded < $1.dateAdded }) {
            thumbnailer.load(library.thumbnailURL(face), maxPixel: 320) { [weak circle] image in
                circle?.contents = image
            }
        }
        return layers
    }

    /// Where a node is on screen (tests).
    func screenPoint(of id: String) -> NSPoint? {
        graph.nodes.first { $0.id == id }.map { toScreen($0.position) }
    }

    // MARK: Input

    private func node(at p: NSPoint) -> CultureGraph.Node? {
        graph.nodes.first { hypot(toScreen($0.position).x - p.x, toScreen($0.position).y - p.y) <= radius($0) * zoom }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragLast = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = dragLast else { return }
        let p = convert(event.locationInWindow, from: nil)
        offset.x -= (p.x - last.x) / zoom
        offset.y -= (p.y - last.y) / zoom
        dragLast = p
        render()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragLast = nil }
        let p = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, hypot(p.x - start.x, p.y - start.y) < 4, let n = node(at: p) else { return }
        onOpenView?(n.base)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY / 200, around: convert(event.locationInWindow, from: nil))
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        offset.x -= event.scrollingDeltaX * k / zoom
        offset.y -= event.scrollingDeltaY * k / zoom
        render()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    func zoom(by factor: CGFloat, around p: NSPoint? = nil) {
        let p = p ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let world = CGPoint(x: p.x / zoom + offset.x, y: p.y / zoom + offset.y)
        zoom = min(max(zoom * factor, 0.15), 3)
        offset = CGPoint(x: world.x - p.x / zoom, y: world.y - p.y / zoom)
        render()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard graph.nodes.isEmpty else { return }
        let text = "收藏還不夠多，系統還看不出關聯\n收得越多，主題、名字與網站之間的線就會慢慢長出來" as NSString
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 6
        text.draw(in: NSRect(x: bounds.midX - 240, y: bounds.midY - 24, width: 480, height: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
    }
}
