import AppKit

/// Sizes for the bars at the foot of the view: regular, or compact when the
/// view is narrow (a small screen, or both side panels open).
struct BarMetrics {
    var button: CGSize
    var icon: CGFloat
    var height: CGFloat
    var spacing: CGFloat
    var inset: CGFloat
    var corner: CGFloat
    var buttonCorner: CGFloat
    var divider: CGFloat

    static let regular = BarMetrics(button: CGSize(width: 42, height: 40), icon: 20, height: 54, spacing: 4, inset: 7, corner: 18, buttonCorner: 11, divider: 22)
    static let compact = BarMetrics(button: CGSize(width: 32, height: 30), icon: 16, height: 42, spacing: 2, inset: 5, corner: 14, buttonCorner: 8, divider: 16)
}

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
        /// When set, the button opens these in a panel above the bar instead of acting.
        var choices: [Tool] = []
        var action: () -> Void = {}
    }

    var onLayout: ((ViewMode) -> Void)?

    private let stack = NSStackView()
    private(set) var tips: [String] = []
    private let bubble = TipBubble()

    /// Smaller buttons when the view is narrow.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            applyMetrics()
            if let last { show(layouts: last.layouts, current: last.current, tools: last.tools) }
        }
    }
    var metrics: BarMetrics { compact ? .compact : .regular }
    private var last: (layouts: [ViewMode], current: ViewMode, tools: [[Tool]])?
    private let glass = Glass(cornerRadius: 18)
    private lazy var height = heightAnchor.constraint(equalToConstant: 54)

    init() {
        super.init(frame: .zero)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        applyMetrics()
    }

    private func applyMetrics() {
        let m = metrics
        stack.spacing = m.spacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: m.inset, bottom: 0, right: m.inset)
        height.constant = m.height
        glass.layer?.cornerRadius = m.corner
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { if isHidden { bubble.hide(); panel?.close() } }
    }

    /// The space's layouts (only when there's more than one), then the tools
    /// in groups, a hairline between groups.
    func show(layouts: [ViewMode], current: ViewMode, tools: [[Tool]]) {
        last = (layouts, current, tools)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bubble.hide()
        panel?.close()
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
            if i > 0 { stack.addArrangedSubview(Self.divider(height: metrics.divider)) }
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

    private var panel: ChoicePanel?

    /// Opens a button's choices above the bar, or closes them if they're open.
    fileprivate func toggleChoices(of button: BarButton) {
        if let open = panel {
            open.close()
            if open.owner === button { return }
        }
        guard let host = superview else { return }
        let next = ChoicePanel(button.tool.choices, owner: button)
        next.onClose = { [weak self, weak next] in if self?.panel === next { self?.panel = nil } }
        next.show(above: self, at: button, in: host)
        panel = next
    }

    func openChoicesForTest(_ tip: String) -> (rows: [String], rowHeight: CGFloat, frame: NSRect, bar: NSRect)? {
        guard let b = stack.arrangedSubviews.compactMap({ $0 as? BarButton }).first(where: { $0.tool.tip == tip }) else { return nil }
        toggleChoices(of: b)
        guard let panel else { return nil }
        return (panel.rowTitles, panel.rowHeight, panel.frame, frame)
    }

    func closeChoicesForTest() { panel?.close() }

    fileprivate func hover(_ button: BarButton?) {
        guard let button, let host = superview else { return bubble.hide() }
        bubble.show(button.tool.tip, above: button, in: host)
    }

    private static func divider(height: CGFloat) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: height),
            wrap.widthAnchor.constraint(equalToConstant: height / 2),
            wrap.heightAnchor.constraint(equalToConstant: height),
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
        let m = bar.metrics
        image = Icon.optical(tool.icon, size: m.icon)
        isBordered = false
        setAccessibilityLabel(tool.tip)
        isEnabled = tool.enabled
        alphaValue = tool.enabled ? 1 : 0.35
        wantsLayer = true
        layer?.cornerRadius = m.buttonCorner
        target = self
        action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: m.button.width).isActive = true
        heightAnchor.constraint(equalToConstant: m.button.height).isActive = true
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
        bar?.toggleChoices(of: self)
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

/// A tool's choices in a glass panel just above the bar, in the bar's own
/// look. Closes on a choice, a click elsewhere, or Esc.
@MainActor
private final class ChoicePanel: NSView {
    let rowHeight: CGFloat = 36
    weak var owner: NSView?
    var onClose: (() -> Void)?
    private(set) var rowTitles: [String] = []
    private var monitor: Any?

    init(_ choices: [ViewBar.Tool], owner: NSView) {
        self.owner = owner
        super.init(frame: .zero)
        let glass = Glass(cornerRadius: 14)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let rows = choices.map { choice in
            ChoiceRow(choice, height: rowHeight) { [weak self] in
                self?.close()
                choice.action()
            }
        }
        rowTitles = choices.map(\.tip)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(above bar: NSView, at button: NSView, in host: NSView) {
        host.addSubview(self)
        let size = fittingSize
        let b = host.convert(button.bounds, from: button)
        let top = host.convert(bar.bounds, from: bar)
        // Its left edge lines up with the button's; it sits just above the bar.
        var x = b.minX - 6
        x = min(max(x, 8), host.bounds.width - size.width - 8)
        let y = host.isFlipped ? top.minY - size.height - 8 : top.maxY + 8
        frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.close()
                return nil
            }
            guard event.window === self.window else { self.close(); return event }
            let p = event.locationInWindow
            let inside = self.bounds.contains(self.convert(p, from: nil))
            let onOwner = self.owner.map { $0.bounds.contains($0.convert(p, from: nil)) } ?? false
            // A click on the owning button is left to it, so it can close the panel itself.
            if !inside && !onOwner { self.close() }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard superview != nil else { return }
        onClose?()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }
}

/// One choice: its icon and name, a ground under the pointer.
@MainActor
private final class ChoiceRow: NSView {
    private let action: () -> Void
    private let icon = NSImageView()
    private let label: NSTextField
    private var hovering = false { didSet { updateLook() } }

    init(_ tool: ViewBar.Tool, height: CGFloat, action: @escaping () -> Void) {
        self.action = action
        label = NSTextField(labelWithString: tool.tip)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        icon.image = Icon.optical(tool.icon, size: 18)
        label.font = .systemFont(ofSize: 13)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tool.tip)
        for v in [icon, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        layer?.backgroundColor = hovering ? resolved(NSColor.labelColor.withAlphaComponent(0.1)) : nil
        icon.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
        label.textColor = .labelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
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

    /// Smaller slots when the view is narrow, like the view bar beside it.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            applyMetrics()
            show(slots)
        }
    }
    var metrics: BarMetrics { compact ? .compact : .regular }
    private let glass = Glass(cornerRadius: 18)
    private lazy var height = heightAnchor.constraint(equalToConstant: 54)

    private func applyMetrics() {
        let m = metrics
        stack.spacing = m.spacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: m.inset, bottom: 0, right: m.inset)
        height.constant = m.height
        glass.layer?.cornerRadius = m.corner
    }

    init() {
        super.init(frame: .zero)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        applyMetrics()
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
        let m = bar.metrics
        wantsLayer = true
        layer?.cornerRadius = m.buttonCorner
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
            widthAnchor.constraint(equalToConstant: m.button.width),
            heightAnchor.constraint(equalToConstant: m.button.height),
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
        let r = bounds.insetBy(dx: bounds.width * 0.19, dy: bounds.height * 0.22)
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
