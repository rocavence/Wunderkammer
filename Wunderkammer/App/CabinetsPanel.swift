import AppKit
import ImageIO

/// The 珍奇櫃 on this Mac as a sheet of cards: each wears a cover made of its
/// newest pieces; a click opens it. Names are typed on the card itself. The
/// default one can't be removed. Opened from the 珍奇櫃 card atop the sidebar.
@MainActor
final class CabinetsPanel: NSObject {
    var onSwitch: ((UUID) -> Void)?
    /// A 珍奇櫃 was added, renamed or removed.
    var onChange: (() -> Void)?

    private let cabinets: Cabinets
    private let count: (Cabinets.Entry) -> Int
    private let covers: (Cabinets.Entry) -> [URL]
    private let sheet: NSWindow
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private let done = NSButton(title: "完成", target: nil, action: nil)
    private var cards: [NSView] = []
    /// A new 珍奇櫃 waiting for its name: a card, not yet a folder.
    private var drafting = false
    /// The tallest the sheet may be: no taller than the window it hangs from.
    private var maxHeight: CGFloat = .greatestFiniteMagnitude

    private static let columns = 3
    private static let cardSize = CGSize(width: 216, height: 236)
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
        maxHeight = window.contentLayoutRect.height - 24
        layoutCards()
        window.beginSheet(sheet)
    }

    private func build() {
        let title = NSTextField(labelWithString: "珍奇櫃")
        title.font = Typography.display(26) ?? .systemFont(ofSize: 26)
        let note = NSTextField(labelWithString: "每個珍奇櫃都有自己的收藏。點卡片打開，名字旁的按鈕可以改名或刪除。")
        note.font = .systemFont(ofSize: 12.5)
        note.textColor = .secondaryLabelColor
        done.target = self
        done.action = #selector(close)
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

    /// Cards in rows of three: every 珍奇櫃, then the one being named or the
    /// card for adding one.
    private func layoutCards() {
        cards.forEach { $0.removeFromSuperview() }
        cards = cabinets.entries.map { entry in
            let card = CabinetCard(name: entry.name, count: count(entry), isCurrent: entry.id == cabinets.currentID,
                                   isDefault: entry.folder.isEmpty, canDelete: cabinets.canDelete(entry.id),
                                   cover: CabinetCover.mosaic(covers(entry), seed: entry.id))
            card.onOpen = { [weak self] in self?.open(entry.id) }
            card.onRename = { [weak self, weak card] in
                guard let self, let card else { return }
                self.edit(card) { name in
                    self.cabinets.rename(entry.id, to: name)
                    self.onChange?()
                }
            }
            card.onDelete = { [weak self] in self?.delete(entry) }
            return card
        }
        if drafting {
            let draft = CabinetCard(name: "", count: 0, isCurrent: false, isDefault: false, canDelete: false,
                                    cover: CabinetCover.mosaic([], seed: UUID()), isDraft: true)
            cards.append(draft)
        } else {
            let add = AddCabinetCard()
            add.onAdd = { [weak self] in self?.add() }
            cards.append(add)
        }
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
        // Up to two rows show without scrolling, fewer if the window is short;
        // the rest scroll.
        let chrome: CGFloat = 30 + 34 + 4 + 18 + 20 + 16 + 32 + 24
        func gridHeight(_ n: Int) -> CGFloat { CGFloat(n) * Self.cardSize.height + CGFloat(n - 1) * Self.gap + 16 }
        var visibleRows = min(rows, 2)
        while visibleRows > 1, chrome + gridHeight(visibleRows) > maxHeight { visibleRows -= 1 }
        sheet.setContentSize(NSSize(width: sheet.frame.width, height: min(chrome + gridHeight(visibleRows), max(maxHeight, 320))))
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        close()
        if id != cabinets.currentID { onSwitch?(id) }
    }

    /// A blank card takes the place of 新增, its name already being typed.
    /// Return makes the 珍奇櫃; Esc or an empty name leaves nothing behind.
    private func add() {
        drafting = true
        layoutCards()
        guard let draft = cards.last as? CabinetCard else { return }
        draft.scrollToVisible(draft.bounds)
        edit(draft) { [weak self] name in
            guard let self else { return }
            self.cabinets.create(named: name)
            self.onChange?()
        }
    }

    /// Types a name on the card. Commits non-empty names, then redraws.
    private func edit(_ card: CabinetCard, commit: @escaping (String) -> Void) {
        // While typing, Esc belongs to the name, not to 完成.
        done.keyEquivalent = ""
        card.beginEditing(in: sheet) { [weak self] name in
            guard let self else { return }
            self.done.keyEquivalent = "\u{1b}"
            if let name { commit(name) }
            self.drafting = false
            self.layoutCards()
        }
    }

    private func delete(_ entry: Cabinets.Entry) {
        guard cabinets.canDelete(entry.id) else { return }
        let alert = NSAlert()
        alert.messageText = "刪除「\(entry.name)」？"
        alert.informativeText = "裡面的 \(count(entry)) 件收藏會一起移到垃圾桶，清空垃圾桶前都還能找回來。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.cabinets.delete(entry.id)
            self.layoutCards()
            self.onChange?()
        }
    }

    @objc private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    // Tests.
    var isShown: Bool { sheet.isVisible }
    var windowNumber: Int { sheet.windowNumber }
    func closeForTest() { close() }
    /// The 新增 card clicked: the blank card waiting for a name.
    func beginAddForTest() { add() }
    /// Typing a name into the card being edited and pressing Return.
    func typeNameForTest(_ name: String) {
        guard let card = cards.compactMap({ $0 as? CabinetCard }).first(where: \.isEditing) else { return }
        card.commitForTest(name)
    }
}

/// One 珍奇櫃: its cover, its name, how much it holds, and buttons for
/// renaming and removing it. Lifts under the pointer.
@MainActor
private final class CabinetCard: NSView, NSTextFieldDelegate {
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    private let nameField = NSTextField()
    private let detail: NSTextField
    private let originalName: String
    private(set) var isEditing = false
    private var finish: ((String?) -> Void)?

    init(name: String, count: Int, isCurrent: Bool, isDefault: Bool, canDelete: Bool, cover: CGImage?, isDraft: Bool = false) {
        self.originalName = name
        detail = NSTextField(labelWithString: isDraft ? "按 Return 建立，Esc 取消" : count == 0 ? "還沒有收藏" : "\(count) 件收藏")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = isCurrent || isDraft ? 2 : 0.5
        layer?.borderColor = (isCurrent || isDraft ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
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

        nameField.stringValue = name
        nameField.placeholderString = "替它取個名字"
        nameField.font = Typography.display(18, weight: .medium) ?? .systemFont(ofSize: 18, weight: .medium)
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.lineBreakMode = .byTruncatingTail
        nameField.cell?.isScrollable = true
        nameField.delegate = self
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        var views: [NSView] = [coverView, nameField, detail]
        var badges: [NSView] = []
        if isCurrent { badges.append(Self.pill("目前", fill: .controlAccentColor, text: .white)) }
        if isDefault { badges.append(Self.pill("預設", fill: NSColor.black.withAlphaComponent(0.5), text: .white)) }
        let badgeRow = NSStackView(views: badges)
        badgeRow.spacing = 6
        views.append(badgeRow)

        // Rename and remove, always in view beside the name. The default
        // 珍奇櫃 has no remove; the open one can't be removed while open.
        var tools: [NSView] = []
        if !isDraft {
            tools.append(CardTool(icon: .edit, tip: "改名", destructive: false) { [weak self] in self?.onRename?() })
            if !isDefault {
                let trash = CardTool(icon: .trash, tip: canDelete ? "刪除" : "要先打開別的珍奇櫃，才能刪除這個",
                                     destructive: true) { [weak self] in self?.onDelete?() }
                trash.isEnabled = canDelete
                tools.append(trash)
            }
        }
        let toolRow = NSStackView(views: tools)
        toolRow.spacing = 2
        views.append(toolRow)

        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A name typed into an empty field still has room to grow.
        if isDraft { nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true }
        toolRow.setHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            coverView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            coverView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            coverView.heightAnchor.constraint(equalToConstant: 156),
            badgeRow.topAnchor.constraint(equalTo: coverView.topAnchor, constant: 10),
            badgeRow.leadingAnchor.constraint(equalTo: coverView.leadingAnchor, constant: 10),
            nameField.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: toolRow.leadingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            toolRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            toolRow.centerYAnchor.constraint(equalTo: nameField.centerYAnchor, constant: 8),
        ])
        if !isDraft {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(name)，\(count) 件收藏" + (isCurrent ? "，目前開著" : ""))
            menu = NSMenu()
            menu?.addItem(ClosureMenuItem("打開") { [weak self] in self?.onOpen?() })
            menu?.addItem(ClosureMenuItem("改名…") { [weak self] in self?.onRename?() })
            if !isDefault {
                let delete = ClosureMenuItem("刪除…") { [weak self] in self?.onDelete?() }
                delete.isEnabled = canDelete
                menu?.addItem(delete)
            }
            menu?.autoenablesItems = false
        }
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

    // MARK: Naming on the card

    /// The name becomes a field; `done` gets the new name, or nil if
    /// nothing changed or it was cancelled.
    func beginEditing(in window: NSWindow, done: @escaping (String?) -> Void) {
        finish = done
        isEditing = true
        nameField.isEditable = true
        nameField.drawsBackground = true
        nameField.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        window.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    private func end(_ name: String?) {
        guard isEditing else { return }
        isEditing = false
        nameField.isEditable = false
        nameField.drawsBackground = false
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = trimmed.isEmpty || trimmed == originalName ? nil : trimmed
        let f = finish
        finish = nil
        f?(result)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            end(nameField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            end(nil)
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere keeps what was typed.
    func controlTextDidEndEditing(_ obj: Notification) {
        end(nameField.stringValue)
    }

    func commitForTest(_ name: String) {
        nameField.stringValue = name
        end(name)
    }

    // MARK: Hover and click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { if !isEditing { lift(true) } }
    override func mouseExited(with event: NSEvent) { lift(false) }

    /// Rises a little towards you, its shadow deepening.
    private func lift(_ up: Bool) {
        guard let layer else { return }
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
        guard !isEditing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }
}

/// A small icon button on a card that shows its ground under the pointer;
/// the destructive one turns red.
@MainActor
private final class CardTool: NSButton {
    private let handler: () -> Void
    private let destructive: Bool

    init(icon: Reicon, tip: String, destructive: Bool, action: @escaping () -> Void) {
        handler = action
        self.destructive = destructive
        super.init(frame: .zero)
        image = Icon.image(icon, size: 15)
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = tip
        setAccessibilityLabel(tip)
        wantsLayer = true
        layer?.cornerRadius = 7
        target = self
        self.action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = resolved((destructive ? NSColor.systemRed : .labelColor).withAlphaComponent(0.12))
        contentTintColor = destructive ? .systemRed : .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        contentTintColor = .secondaryLabelColor
    }

    @objc private func run() { handler() }
}

/// The newest pieces of a 珍奇櫃 as one picture, for its card and the sidebar.
enum CabinetCover {
    /// One fills it, two side by side, three as one large and two small, four
    /// as a square of four. None: a gradient of the 珍奇櫃's own colour.
    static func mosaic(_ urls: [URL], seed: UUID, size: CGSize = CGSize(width: 408, height: 312)) -> CGImage? {
        let images = urls.prefix(4).compactMap { url -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: 420] as CFDictionary)
        }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The same colour every launch: from the id's bytes, not its hash.
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        let hue = CGFloat(bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360
        let a = NSColor(hue: hue, saturation: 0.35, brightness: 0.42, alpha: 1).cgColor
        let b = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.22, alpha: 1).cgColor
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        let gap = max(1, size.width / 136)
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
            let side = min(56, min(w, h) * 0.5)
            let r = CGRect(x: w / 2 - side / 2, y: h / 2 - side / 2, width: side, height: side)
            ctx.setAlpha(0.5)
            ctx.clip(to: r, mask: icon)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(r)
        }
        return ctx.makeImage()
    }
}

/// The last card: a dashed outline inviting a new 珍奇櫃.
@MainActor
private final class AddCabinetCard: NSView {
    var onAdd: (() -> Void)?
    private let outline = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 5]
        layer?.addSublayer(outline)
        let plus = NSImageView(image: Icon.image(.plus, size: 28))
        plus.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "新增珍奇櫃")
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
        setAccessibilityLabel("新增珍奇櫃")
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
