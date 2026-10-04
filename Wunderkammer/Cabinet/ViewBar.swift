import AppKit

/// The floating bar at the foot of the view, in the middle: the layouts this
/// space has, then what can be done to the view in front of you.
@MainActor
final class ViewBar: NSVisualEffectView {
    struct Tool {
        var icon: Reicon
        var tip: String
        var enabled = true
        var destructive = false
        var action: () -> Void
    }

    var onLayout: ((ViewMode) -> Void)?

    private let stack = NSStackView()
    private var layouts: [ViewMode] = []
    private(set) var tips: [String] = []

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 42),
        ])
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderColor = resolved(.separatorColor)
    }

    /// The space's layouts (a switch only when there's more than one), then
    /// the tools in groups, a hairline between groups.
    func show(layouts: [ViewMode], current: ViewMode, tools: [[Tool]]) {
        self.layouts = layouts
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tips = []
        var sections: [[NSView]] = []
        if layouts.count > 1 {
            let control = NSSegmentedControl(images: layouts.map { Icon.image($0.icon, size: 15) }, trackingMode: .selectOne,
                                             target: self, action: #selector(layoutPicked(_:)))
            for (i, m) in layouts.enumerated() {
                control.setToolTip(m.title, forSegment: i)
                control.setWidth(34, forSegment: i)
                tips.append(m.title)
            }
            control.selectedSegment = layouts.firstIndex(of: current) ?? 0
            control.segmentStyle = .automatic
            control.setAccessibilityLabel("排法")
            sections.append([control])
        }
        for group in tools where !group.isEmpty {
            sections.append(group.map { tool in
                tips.append(tool.tip)
                return BarButton(tool)
            })
        }
        for (i, section) in sections.enumerated() {
            if i > 0 { stack.addArrangedSubview(Self.divider()) }
            section.forEach(stack.addArrangedSubview)
        }
        isHidden = sections.isEmpty
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 9),
            wrap.heightAnchor.constraint(equalToConstant: 18),
            line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    @objc private func layoutPicked(_ sender: NSSegmentedControl) {
        guard layouts.indices.contains(sender.selectedSegment) else { return }
        onLayout?(layouts[sender.selectedSegment])
    }
}

/// A tool in the bar: an icon that shows its ground under the pointer.
@MainActor
private final class BarButton: NSButton {
    private let tool: ViewBar.Tool

    init(_ tool: ViewBar.Tool) {
        self.tool = tool
        super.init(frame: .zero)
        image = Icon.image(tool.icon, size: 16)
        isBordered = false
        toolTip = tool.tip
        setAccessibilityLabel(tool.tip)
        isEnabled = tool.enabled
        alphaValue = tool.enabled ? 1 : 0.35
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 8
        target = self
        action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = resolved((tool.destructive ? NSColor.systemRed : .labelColor).withAlphaComponent(0.1))
        contentTintColor = tool.destructive ? .systemRed : .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        contentTintColor = .secondaryLabelColor
    }

    @objc private func run() { tool.action() }
}
