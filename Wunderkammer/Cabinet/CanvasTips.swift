import AppKit

/// Five short lessons for the 工作台, in a card at the bottom right: one at a
/// time, with arrows to step through and a close button. Closed once, it stays
/// away until the app is opened again.
@MainActor
final class CanvasTips: NSView {
    struct Tip {
        var icon: Reicon
        var title: String
        var keys: [String]
        var detail: String
    }

    var onClose: (() -> Void)?

    static let tips: [Tip] = [
        Tip(icon: .link, title: String(localized: "連起來"), keys: ["⌥"],
            detail: String(localized: "按住 ⌥，從一件拖到另一件。")),
        Tip(icon: .hand, title: String(localized: "移動畫布"), keys: ["Space"],
            detail: String(localized: "按住空白鍵拖曳，或按住 ⌥ 拖空白的地方。")),
        Tip(icon: .searchZoomIn, title: String(localized: "放大縮小"), keys: ["⌘+", "⌘−"],
            detail: String(localized: "兩指捏合或捲動滾輪。")),
        Tip(icon: .selection, title: String(localized: "自己分一堆"), keys: [],
            detail: String(localized: "框選幾件，拖到空白處，就成新的一堆。")),
        Tip(icon: .save, title: String(localized: "存下排法"), keys: ["⌃⇧1", "⌃1"],
            detail: String(localized: "點右下的空格存起來，再點一次回到這個排法。")),
    ]

    private(set) var index = 0
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let keys = NSStackView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let back = NSButton()
    private let next = NSButton()

    init() {
        super.init(frame: .zero)
        let glass = Glass(cornerRadius: 16)
        icon.contentTintColor = .accent
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12.5)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 220
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .tertiaryLabelColor
        keys.spacing = 4

        let close = button(.x, tip: String(localized: "關閉提示")) { [weak self] in self?.onClose?() }
        configure(back, icon: .chevronLeft, tip: String(localized: "上一則")) { [weak self] in self?.step(-1) }
        configure(next, icon: .chevronRight, tip: String(localized: "下一則")) { [weak self] in self?.step(1) }

        let head = NSStackView(views: [icon, title, keys, NSView(), close])
        head.spacing = 8
        let foot = NSStackView(views: [counter, NSView(), back, next])
        foot.spacing = 2
        let body = NSStackView(views: [head, detail, foot])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 8)
        for v in [glass, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // The card gives way before the window's columns do.
        let width = widthAnchor.constraint(equalToConstant: 264)
        width.priority = .defaultLow
        NSLayoutConstraint.activate([
            width,
            widthAnchor.constraint(lessThanOrEqualToConstant: 264),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            head.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -22),
            foot.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -22),
            detail.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "工作台提示"))
        show(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    var textForTest: String { title.stringValue }

    func step(_ by: Int) {
        show((index + by + Self.tips.count) % Self.tips.count)
    }

    private func show(_ i: Int) {
        index = i
        let tip = Self.tips[i]
        icon.image = Icon.optical(tip.icon, size: 18)
        title.stringValue = tip.title
        detail.stringValue = tip.detail
        counter.stringValue = "\(i + 1) / \(Self.tips.count)"
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in tip.keys { keys.addArrangedSubview(KeyCap(key)) }
    }

    private func button(_ icon: Reicon, tip: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let b = NSButton()
        configure(b, icon: icon, tip: tip, action: action)
        return b
    }

    private func configure(_ b: NSButton, icon: Reicon, tip: String, action: @escaping @MainActor () -> Void) {
        b.image = Icon.optical(icon, size: 14)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.target = ActionBox.make(b, action)
        b.action = #selector(ActionBox.run)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
}

/// A key on the keyboard, small.
@MainActor
private final class KeyCap: NSTextField {
    init(_ key: String) {
        super.init(frame: .zero)
        stringValue = key
        isEditable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 10.5, weight: .semibold)
        textColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 10, height: 17)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    override func updateLayer() {
        layer?.borderColor = resolved(.separatorColor)
        layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.05))
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 5, dy: 1)
        (stringValue as NSString).draw(in: inset, withAttributes: [.font: font as Any, .foregroundColor: textColor as Any])
    }
}

/// Holds a closure as a button's target (buttons keep targets weakly).
@MainActor
final class ActionBox: NSObject {
    private let action: @MainActor () -> Void
    private init(_ action: @escaping @MainActor () -> Void) { self.action = action }

    static func make(_ owner: NSObject, _ action: @escaping @MainActor () -> Void) -> ActionBox {
        let box = ActionBox(action)
        objc_setAssociatedObject(owner, Unmanaged.passUnretained(box).toOpaque(), box, .OBJC_ASSOCIATION_RETAIN)
        return box
    }

    @objc func run() { action() }
}
