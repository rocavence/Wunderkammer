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
        /// When set, the button opens these as a menu instead of acting.
        var choices: [Tool] = []
        var action: () -> Void = {}
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

    func choicesForTest(_ tip: String) -> [String] {
        stack.arrangedSubviews.compactMap { $0 as? BarButton }.first { $0.tool.tip == tip }?.tool.choices.map(\.tip) ?? []
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
        guard !tool.choices.isEmpty else { return tool.action() }
        let menu = NSMenu()
        menu.minimumWidth = 200
        for choice in tool.choices {
            let item = ClosureMenuItem(choice.tip) { choice.action() }
            // A menu row is as tall as its image: padding the icon gives roomier rows at the usual text size.
            let icon = Icon.optical(choice.icon, size: 18)
            let padded = NSImage(size: NSSize(width: icon.size.width, height: 32), flipped: false) { rect in
                icon.draw(in: NSRect(x: 0, y: (rect.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                return true
            }
            padded.isTemplate = icon.isTemplate
            item.image = padded
            menu.addItem(item)
        }
        // Opens upward, its bottom just above the button.
        let top = bounds.height + 6 + menu.size.height
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? -6 - menu.size.height : top), in: self)
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

/// Beside the view bar on the 工作台: three slots for arrangements to come
/// back to. An empty slot saves the canvas as it is; a full one, a small
/// picture of its piles, puts the canvas back that way. The one the canvas
/// matches now wears the accent. Right-click a slot to save over it or clear it.
@MainActor
final class SnapshotBar: NSView {
    struct Slot {
        var picture: NSImage?
        var current: Bool
    }

    var onSave: ((Int) -> Void)?
    var onRestore: ((Int) -> Void)?
    var onClear: ((Int) -> Void)?

    private let stack = NSStackView()
    private let bubble = TipBubble()
    private(set) var slots: [Slot] = []

    init() {
        super.init(frame: .zero)
        let glass = Glass(cornerRadius: 18)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "儲存的排列"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { if isHidden { bubble.hide() } }
    }

    func show(_ slots: [Slot]) {
        self.slots = slots
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, slot) in slots.enumerated() {
            let b = SlotButton(index: i, slot: slot, bar: self)
            stack.addArrangedSubview(b)
        }
    }

    fileprivate func tip(for i: Int) -> String {
        slots[safe: i]?.picture == nil
            ? String(localized: "存成排列 \(i + 1)（⌃⇧\(i + 1)）")
            : String(localized: "回到排列 \(i + 1)（⌃\(i + 1)）")
    }

    fileprivate func hover(_ button: SlotButton?) {
        guard let button, let host = superview else { return bubble.hide() }
        bubble.show(tip(for: button.index), above: button, in: host)
    }

    fileprivate func clicked(_ i: Int) {
        bubble.hide()
        if slots[safe: i]?.picture == nil { onSave?(i) } else { onRestore?(i) }
    }

    fileprivate func menu(for i: Int) -> NSMenu? {
        guard slots[safe: i]?.picture != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "回到這個排列")) { [weak self] in self?.onRestore?(i) })
        menu.addItem(ClosureMenuItem(String(localized: "用目前的排列取代")) { [weak self] in self?.onSave?(i) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "清除這一格")) { [weak self] in self?.onClear?(i) })
        return menu
    }

    // Tests.
    func clickForTest(_ i: Int) { clicked(i) }
}

/// One slot: a dashed ＋ when empty; the arrangement's picture when not.
@MainActor
private final class SlotButton: NSView {
    let index: Int
    private let slot: SnapshotBar.Slot
    private weak var bar: SnapshotBar?
    private let well = CAShapeLayer()
    private let picture = CALayer()
    private let plus = NSImageView()
    private var hovering = false { didSet { updateLook() } }

    init(index: Int, slot: SnapshotBar.Slot, bar: SnapshotBar) {
        self.index = index
        self.slot = slot
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        well.fillColor = nil
        well.lineWidth = 1.2
        layer?.addSublayer(well)
        picture.contentsGravity = .resizeAspect
        layer?.addSublayer(picture)
        plus.image = Icon.optical(.plus, size: 14)
        plus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plus)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 42),
            heightAnchor.constraint(equalToConstant: 40),
            plus.centerXAnchor.constraint(equalTo: centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        plus.isHidden = slot.picture != nil
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(bar.tip(for: index))
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: 8, dy: 9)
        well.frame = bounds
        well.path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        picture.frame = r.insetBy(dx: 2, dy: 2)
        updateLook()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        let empty = slot.picture == nil
        let tint: NSColor = slot.current ? .accent : hovering ? .labelColor : .secondaryLabelColor
        well.lineDashPattern = empty ? [3, 2.5] : nil
        well.strokeColor = resolved(empty ? tint.withAlphaComponent(0.7) : tint.withAlphaComponent(slot.current ? 1 : 0.5))
        layer?.backgroundColor = slot.current ? resolved(NSColor.accent.withAlphaComponent(0.16))
            : hovering ? resolved(NSColor.labelColor.withAlphaComponent(0.1)) : nil
        plus.contentTintColor = tint
        if let image = slot.picture {
            picture.contents = tinted(image, resolved(tint))
        }
    }

    /// The miniature drawn in one colour.
    private func tinted(_ image: NSImage, _ color: CGColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            NSColor(cgColor: color)?.set()
            r.fill(using: .sourceIn)
            return true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; bar?.hover(self) }
    override func mouseExited(with event: NSEvent) { hovering = false; bar?.hover(nil) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        bar?.clicked(index)
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: index) }
}
