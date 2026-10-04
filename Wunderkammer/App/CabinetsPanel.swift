import AppKit
import ImageIO

/// The 珍奇室 on this Mac as a sheet of cards: each wears a cover made of its
/// newest pieces; a click opens it. The default one can't be removed.
/// Opened from the button beside the sidebar's first row.
@MainActor
final class CabinetsPanel: NSObject {
    var onSwitch: ((UUID) -> Void)?
    /// A 珍奇室 was added, renamed or removed.
    var onChange: (() -> Void)?

    private let cabinets: Cabinets
    private let count: (Cabinets.Entry) -> Int
    private let covers: (Cabinets.Entry) -> [URL]
    private let sheet: NSWindow
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private var cards: [NSView] = []

    private static let columns = 3
    private static let cardSize = CGSize(width: 216, height: 232)
    private static let gap: CGFloat = 18
    private static let margin: CGFloat = 32

    init(cabinets: Cabinets, count: @escaping (Cabinets.Entry) -> Int, covers: @escaping (Cabinets.Entry) -> [URL]) {
        self.cabinets = cabinets
        self.count = count
        self.covers = covers
        let width = Self.margin * 2 + CGFloat(Self.columns) * Self.cardSize.width + CGFloat(Self.columns - 1) * Self.gap
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520), styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        super.init()
        build()
    }

    func present(on window: NSWindow) {
        layoutCards()
        window.beginSheet(sheet)
    }

    private func build() {
        let title = NSTextField(labelWithString: "珍奇室")
        title.font = Typography.display(26) ?? .systemFont(ofSize: 26)
        let note = NSTextField(labelWithString: "每個珍奇室都有自己的收藏。點一下卡片就打開它。")
        note.font = .systemFont(ofSize: 12.5)
        note.textColor = .secondaryLabelColor
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        done.controlSize = .large

        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let content = NSVisualEffectView()
        content.material = .sheet
        content.blendingMode = .behindWindow
        content.state = .active
        for v in [title, note, scroll, done] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -16),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        sheet.contentView = content
    }

    /// Cards in rows of three: every 珍奇室, then one for a new one.
    private func layoutCards() {
        cards.forEach { $0.removeFromSuperview() }
        cards = cabinets.entries.map { entry in
            let card = CabinetCard(entry: entry, count: count(entry), isCurrent: entry.id == cabinets.currentID,
                                   isDefault: entry.folder.isEmpty, canDelete: cabinets.canDelete(entry.id),
                                   cover: CabinetCard.mosaic(covers(entry), seed: entry.id))
            card.onOpen = { [weak self] in self?.open(entry.id) }
            card.onRename = { [weak self] in self?.rename(entry) }
            card.onDelete = { [weak self] in self?.delete(entry) }
            return card
        }
        let add = AddCabinetCard()
        add.onAdd = { [weak self] in self?.add() }
        cards.append(add)
        let rows = (cards.count + Self.columns - 1) / Self.columns
        let height = CGFloat(rows) * Self.cardSize.height + CGFloat(rows - 1) * Self.gap + 16
        grid.frame = NSRect(x: 0, y: 0, width: sheet.frame.width, height: height)
        for (i, card) in cards.enumerated() {
            let col = i % Self.columns, row = i / Self.columns
            card.frame = NSRect(x: Self.margin + CGFloat(col) * (Self.cardSize.width + Self.gap),
                                y: 8 + CGFloat(row) * (Self.cardSize.height + Self.gap),
                                width: Self.cardSize.width, height: Self.cardSize.height)
            grid.addSubview(card)
        }
        // Two rows show without scrolling; more scroll.
        let visibleRows = min(rows, 2)
        let gridHeight = CGFloat(visibleRows) * Self.cardSize.height + CGFloat(visibleRows - 1) * Self.gap + 16
        sheet.setContentSize(NSSize(width: sheet.frame.width, height: 30 + 34 + 4 + 18 + 20 + gridHeight + 16 + 32 + 24))
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        close()
        if id != cabinets.currentID { onSwitch?(id) }
    }

    private func add() {
        guard let name = ItemActions.promptName(title: "新的珍奇室", initial: "未命名珍奇室", window: nil) else { return }
        cabinets.create(named: name)
        layoutCards()
        onChange?()
    }

    private func rename(_ entry: Cabinets.Entry) {
        guard let name = ItemActions.promptName(title: "重新命名珍奇室", initial: entry.name, window: nil) else { return }
        cabinets.rename(entry.id, to: name)
        layoutCards()
        onChange?()
    }

    private func delete(_ entry: Cabinets.Entry) {
        guard cabinets.canDelete(entry.id) else { return }
        let alert = NSAlert()
        alert.messageText = "刪除「\(entry.name)」？"
        alert.informativeText = "裡面的 \(count(entry)) 件收藏會一起移到垃圾桶，清空垃圾桶前都還能找回來。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cabinets.delete(entry.id)
        layoutCards()
        onChange?()
    }

    @objc private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    // Tests.
    var isShown: Bool { sheet.isVisible }
    var windowNumber: Int { sheet.windowNumber }
    func closeForTest() { close() }
}

/// One 珍奇室: its cover, its name, how much it holds. Lifts under the pointer.
@MainActor
private final class CabinetCard: NSView {
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    private let more = NSButton()
    private let canDelete: Bool
    private let isDefault: Bool
    private let isCurrent: Bool

    init(entry: Cabinets.Entry, count: Int, isCurrent: Bool, isDefault: Bool, canDelete: Bool, cover: CGImage?) {
        self.canDelete = canDelete
        self.isDefault = isDefault
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = isCurrent ? 2 : 0.5
        layer?.borderColor = (isCurrent ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let coverView = NSImageView()
        coverView.image = cover.map { NSImage(cgImage: $0, size: .zero) }
        coverView.imageScaling = .scaleAxesIndependently
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 12
        coverView.layer?.masksToBounds = true
        coverView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        let name = NSTextField(labelWithString: entry.name)
        name.font = Typography.display(18, weight: .medium) ?? .systemFont(ofSize: 18, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: count == 0 ? "還沒有收藏" : "\(count) 件收藏")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        more.image = Icon.image(.moreH, size: 15)
        more.isBordered = false
        more.contentTintColor = .white
        more.wantsLayer = true
        more.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        more.layer?.cornerRadius = 12
        more.target = self
        more.action = #selector(showMenu)
        more.toolTip = "重新命名或刪除"
        more.setAccessibilityLabel("更多")
        more.alphaValue = 0

        var views: [NSView] = [coverView, name, detail, more]
        var badges: [NSView] = []
        if isCurrent { badges.append(Self.pill("目前", fill: .controlAccentColor, text: .white)) }
        if isDefault { badges.append(Self.pill("預設", fill: NSColor.black.withAlphaComponent(0.5), text: .white)) }
        let badgeRow = NSStackView(views: badges)
        badgeRow.spacing = 6
        views.append(badgeRow)
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            coverView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            coverView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            coverView.heightAnchor.constraint(equalToConstant: 156),
            badgeRow.topAnchor.constraint(equalTo: coverView.topAnchor, constant: 10),
            badgeRow.leadingAnchor.constraint(equalTo: coverView.leadingAnchor, constant: 10),
            more.topAnchor.constraint(equalTo: coverView.topAnchor, constant: 8),
            more.trailingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: -8),
            more.widthAnchor.constraint(equalToConstant: 24),
            more.heightAnchor.constraint(equalToConstant: 24),
            name.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(entry.name)，\(count) 件收藏" + (isCurrent ? "，目前開著" : ""))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func pill(_ text: String, fill: NSColor, text color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = fill.cgColor
        box.layer?.cornerRadius = 9
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 18),
        ])
        return box
    }

    // MARK: Hover and click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { lift(true) }
    override func mouseExited(with event: NSEvent) { lift(false) }

    /// Rises a little towards you, its shadow deepening.
    private func lift(_ up: Bool) {
        guard let layer else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            more.animator().alphaValue = up ? 1 : 0
        }
        let spring = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.2)
        spring.keyPath = "shadowRadius"
        spring.fromValue = layer.presentation()?.shadowRadius ?? layer.shadowRadius
        spring.toValue = up ? 22 : 10
        spring.duration = spring.settlingDuration
        layer.shadowRadius = up ? 22 : 10
        layer.shadowOpacity = up ? 0.32 : 0.18
        layer.add(spring, forKey: "lift")
        // Scale about the centre: the layer's anchor is its corner in AppKit.
        let s: CGFloat = up ? 1.025 : 1
        let t = CATransform3DTranslate(CATransform3DMakeScale(s, s, 1),
                                       bounds.width * (1 - s) / 2 / s, bounds.height * (1 - s) / 2 / s, 0)
        let grow = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.25)
        grow.keyPath = "transform"
        grow.fromValue = layer.presentation()?.transform ?? layer.transform
        grow.toValue = t
        grow.duration = grow.settlingDuration
        layer.transform = t
        layer.add(grow, forKey: "grow")
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), !more.frame.contains(p) else { return }
        onOpen?()
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("重新命名…") { [weak self] in self?.onRename?() })
        if !isDefault {
            let delete = ClosureMenuItem(isCurrent ? "刪除…（先打開別的珍奇室）" : "刪除…") { [weak self] in self?.onDelete?() }
            delete.isEnabled = canDelete
            menu.addItem(delete)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    // MARK: Cover

    /// The newest pieces as one picture: one fills it, two side by side,
    /// three as one large and two small, four as a square of four. None: a
    /// gradient of its own colour.
    static func mosaic(_ urls: [URL], seed: UUID) -> CGImage? {
        let size = CGSize(width: 408, height: 312)
        let images = urls.prefix(4).compactMap { url -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: 420] as CFDictionary)
        }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let hue = CGFloat(abs(seed.hashValue % 360)) / 360
        let a = NSColor(hue: hue, saturation: 0.35, brightness: 0.42, alpha: 1).cgColor
        let b = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.22, alpha: 1).cgColor
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        let gap: CGFloat = 3
        let w = size.width, h = size.height
        // Rects in CoreGraphics' bottom-up coordinates.
        let rects: [CGRect]
        switch images.count {
        case 1: rects = [CGRect(x: 0, y: 0, width: w, height: h)]
        case 2: rects = [CGRect(x: 0, y: 0, width: w / 2 - gap / 2, height: h), CGRect(x: w / 2 + gap / 2, y: 0, width: w / 2 - gap / 2, height: h)]
        case 3: rects = [CGRect(x: 0, y: 0, width: w * 0.62 - gap / 2, height: h),
                         CGRect(x: w * 0.62 + gap / 2, y: h / 2 + gap / 2, width: w * 0.38 - gap / 2, height: h / 2 - gap / 2),
                         CGRect(x: w * 0.62 + gap / 2, y: 0, width: w * 0.38 - gap / 2, height: h / 2 - gap / 2)]
        case 4: rects = [CGRect(x: 0, y: h / 2 + gap / 2, width: w / 2 - gap / 2, height: h / 2 - gap / 2),
                         CGRect(x: w / 2 + gap / 2, y: h / 2 + gap / 2, width: w / 2 - gap / 2, height: h / 2 - gap / 2),
                         CGRect(x: 0, y: 0, width: w / 2 - gap / 2, height: h / 2 - gap / 2),
                         CGRect(x: w / 2 + gap / 2, y: 0, width: w / 2 - gap / 2, height: h / 2 - gap / 2)]
        default: rects = []
        }
        for (image, rect) in zip(images, rects) {
            // Fill the rect, cropping the picture's longer side.
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(image, in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            ctx.restoreGState()
        }
        if images.isEmpty, let icon = Icon.image(.cabinet, size: 56).cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // A quiet cabinet mark on its colour.
            ctx.setAlpha(0.5)
            ctx.clip(to: CGRect(x: w / 2 - 28, y: h / 2 - 28, width: 56, height: 56), mask: icon)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: w / 2 - 28, y: h / 2 - 28, width: 56, height: 56))
        }
        return ctx.makeImage()
    }
}

/// The last card: a dashed outline inviting a new 珍奇室.
@MainActor
private final class AddCabinetCard: NSView {
    var onAdd: (() -> Void)?
    private let outline = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 5]
        layer?.addSublayer(outline)
        let plus = NSImageView(image: Icon.image(.plus, size: 28))
        plus.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "新增珍奇室")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [plus, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("新增珍奇室")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 16, cornerHeight: 16, transform: nil)
        outline.strokeColor = resolved(.tertiaryLabelColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        outline.strokeColor = resolved(.controlAccentColor)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        outline.strokeColor = resolved(.tertiaryLabelColor)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onAdd?() }
    }
}
