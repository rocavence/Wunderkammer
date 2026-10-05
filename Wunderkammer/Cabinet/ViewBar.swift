import AppKit

/// The floating bar at the foot of the view, in the middle: the layouts this
/// space has, then what can be done to the view in front of you. Each button
/// names itself in a bubble above the bar as soon as the pointer is on it.
@MainActor
final class ViewBar: NSView {
    struct Tool {
        var icon: Reicon
        var tip: String
        var enabled = true
        var destructive = false
        var action: () -> Void
    }

    var onLayout: ((ViewMode) -> Void)?

    private let stack = NSStackView()
    private(set) var tips: [String] = []
    private let bubble = TipBubble()

    init() {
        super.init(frame: .zero)
        let glass = Glass(cornerRadius: 18)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { if isHidden { bubble.hide() } }
    }

    /// The space's layouts (only when there's more than one), then the tools
    /// in groups, a hairline between groups.
    func show(layouts: [ViewMode], current: ViewMode, tools: [[Tool]]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bubble.hide()
        tips = []
        var sections: [[NSView]] = []
        if layouts.count > 1 {
            sections.append(layouts.map { m in
                tips.append(m.title)
                let b = BarButton(Tool(icon: m.icon, tip: m.title) { [weak self] in self?.onLayout?(m) }, bar: self)
                b.isSelected = m == current
                return b
            })
        }
        for group in tools where !group.isEmpty {
            sections.append(group.map { tool in
                tips.append(tool.tip)
                return BarButton(tool, bar: self)
            })
        }
        for (i, section) in sections.enumerated() {
            if i > 0 { stack.addArrangedSubview(Self.divider()) }
            section.forEach(stack.addArrangedSubview)
        }
        isHidden = sections.isEmpty
    }

    func enabledForTest(_ tip: String) -> Bool? {
        stack.arrangedSubviews.compactMap { $0 as? BarButton }.first { $0.tool.tip == tip }?.isEnabled
    }

    /// Points at the bar's first button the way the pointer would; returns
    /// what the bubble says (tests).
    func hoverFirstForTest() -> String? {
        guard let b = stack.arrangedSubviews.compactMap({ $0 as? BarButton }).first else { return nil }
        hover(b)
        return bubble.text
    }

    fileprivate func hover(_ button: BarButton?) {
        guard let button, let host = superview else { return bubble.hide() }
        bubble.show(button.tool.tip, above: button, in: host)
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 22),
            wrap.widthAnchor.constraint(equalToConstant: 11),
            wrap.heightAnchor.constraint(equalToConstant: 22),
            line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }
}

/// A button in the bar: an icon that shows its ground under the pointer and
/// a filled ground when it's the layout in use.
@MainActor
private final class BarButton: NSButton {
    let tool: ViewBar.Tool
    private weak var bar: ViewBar?
    private var hovering = false { didSet { updateLook() } }
    var isSelected = false { didSet { updateLook() } }

    init(_ tool: ViewBar.Tool, bar: ViewBar) {
        self.tool = tool
        self.bar = bar
        super.init(frame: .zero)
        // Optically matched: each icon's drawing comes out the same size.
        image = Icon.optical(tool.icon, size: 20)
        isBordered = false
        setAccessibilityLabel(tool.tip)
        isEnabled = tool.enabled
        alphaValue = tool.enabled ? 1 : 0.35
        wantsLayer = true
        layer?.cornerRadius = 11
        target = self
        action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 42).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        let red = tool.destructive && hovering
        let ground: NSColor? = isSelected ? NSColor.labelColor.withAlphaComponent(0.14)
            : hovering ? (red ? NSColor.systemRed : .labelColor).withAlphaComponent(0.1) : nil
        layer?.backgroundColor = ground.map(resolved)
        contentTintColor = red ? .systemRed : isSelected || hovering ? .labelColor : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    // The name shows even for a tool that can't be used right now.
    override func mouseEntered(with event: NSEvent) {
        hovering = isEnabled
        bar?.hover(self)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        bar?.hover(nil)
    }

    @objc private func run() {
        bar?.hover(nil)
        tool.action()
    }
}

/// The name of the button under the pointer, in a small pill above it.
@MainActor
private final class TipBubble: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, above anchor: NSView, in host: NSView) {
        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
        }
        // The reverse of the window: dark on light, light on dark.
        layer?.backgroundColor = host.resolved(NSColor.labelColor.withAlphaComponent(0.9))
        label.textColor = NSColor(cgColor: host.resolved(.windowBackgroundColor)) ?? .white
        label.stringValue = text
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 18, height: 24)
        let a = host.convert(anchor.bounds, from: anchor)
        // Above the button, inside the view's edges.
        let y = host.isFlipped ? a.minY - size.height - 12 : a.maxY + 12
        var x = a.midX - size.width / 2
        x = min(max(x, 8), host.bounds.width - size.width - 8)
        frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }
    }
}
