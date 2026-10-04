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
    private let referenced: (Cabinets.Entry) -> Int
    /// The card turned over to its settings.
    private var flipped: UUID?
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
    private static let cardSize = CGSize(width: 216, height: 256)
    private static let gap: CGFloat = 18
    private static let margin: CGFloat = 32

    init(cabinets: Cabinets, count: @escaping (Cabinets.Entry) -> Int, covers: @escaping (Cabinets.Entry) -> [URL],
         referenced: @escaping (Cabinets.Entry) -> Int) {
        self.cabinets = cabinets
        self.count = count
        self.covers = covers
        self.referenced = referenced
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
        let note = NSTextField(labelWithString: "每個珍奇櫃都有自己的收藏。點卡片打開，按編輯翻到背面設定名稱與檔案。")
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
            let watched = cabinets.watched(entry.id), vault = cabinets.vault(entry.id)
            let card = CabinetCard(name: entry.name, count: count(entry), isCurrent: entry.id == cabinets.currentID,
                                   isDefault: entry.folder.isEmpty, canDelete: cabinets.canDelete(entry.id),
                                   cover: CabinetCover.mosaic(covers(entry), seed: entry.id),
                                   watching: watched.count, vault: vault)
            card.onOpen = { [weak self] in self?.open(entry.id) }
            card.onEdit = { [weak self, weak card] in
                guard let self, let card else { return }
                self.flipped = entry.id
                card.turn(toBack: true, animated: true)
            }
            card.onDelete = { [weak self] in self?.delete(entry) }
            let back = card.back
            back.show(name: entry.name, folders: watched, vault: vault, maxFolders: Cabinets.maxWatched)
            back.onDone = { [weak self, weak card] in
                self?.flipped = nil
                card?.turn(toBack: false, animated: true)
            }
            back.onRename = { [weak self] name in
                guard let self else { return }
                self.cabinets.rename(entry.id, to: name)
                self.onChange?()
                self.layoutCards()
            }
            back.onAddFolder = { [weak self] in self?.addFolder(to: entry.id) }
            back.onRemoveFolder = { [weak self] folder in
                guard let self else { return }
                self.cabinets.unwatch(folder, in: entry.id)
                self.layoutCards()
                self.onChange?()
            }
            back.onKeepFiles = { [weak self] keep in
                guard let self else { return }
                if keep { self.chooseVault(for: entry) } else {
                    self.cabinets.clearVault(for: entry.id)
                    self.layoutCards()
                    self.onChange?()
                }
            }
            if entry.id == flipped { card.turn(toBack: true, animated: false) }
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

    // MARK: Files: linked folders, or a vault

    /// Keeping files means a folder of the 珍奇櫃's own. Chosen first, then
    /// asked: what gets copied, what stops being watched. No means nothing changes.
    private func chooseVault(for entry: Cabinets.Entry) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "用這個資料夾收檔案"
        open.message = "「\(entry.name)」收進來的檔案，都會複製一份到這個資料夾，用原本的檔名存。"
        open.beginSheetModal(for: sheet) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let folder = open.url else { return self.layoutCards() }
            // The open panel has to be gone before the question can show.
            DispatchQueue.main.async { self.confirmVault(folder, for: entry) }
        }
    }

    private func confirmVault(_ folder: URL, for entry: Cabinets.Entry) {
        let files = referenced(entry), watched = cabinets.watched(entry.id).count
        var lines: [String] = []
        if files > 0 { lines.append("\(files) 件收藏的檔案會複製一份到「\(folder.lastPathComponent)」。") }
        if watched > 0 { lines.append("連結的 \(watched) 個資料夾會停止監看，裡面的檔案不會被動到。") }
        lines.append("之後收進來的檔案也都會存在這裡。")
        let alert = NSAlert()
        alert.messageText = "改成把檔案收進珍奇櫃？"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: files > 0 ? "複製並改用" : "改用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.cabinets.setVault(folder, for: entry.id)
                self.onChange?()
            }
            // Either way the card shows what's true now (cancel: as it was).
            self.layoutCards()
        }
    }

    private func addFolder(to id: UUID) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "監看這個資料夾"
        open.message = "放進這個資料夾的檔案會自動收進來，從資料夾拿走就跟著移除。裡面現有的檔案也會一起收進來。"
        open.beginSheetModal(for: sheet) { [weak self] response in
            guard let self, response == .OK, let folder = open.url else { return }
            if self.cabinets.watch(folder, in: id) {
                self.layoutCards()
                self.onChange?()
            } else {
                let alert = NSAlert()
                alert.messageText = "不能監看這個資料夾"
                alert.informativeText = "它已經在監看清單裡，或和清單裡的資料夾重疊，或是珍奇櫃自己存放資料的地方。"
                alert.beginSheetModal(for: self.sheet)
            }
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
    /// A card turned over to its settings, without the turn.
    func flipForTest(_ id: UUID) {
        flipped = id
        layoutCards()
    }
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
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    /// The settings on the other side.
    let back = CabinetBack()
    private var turning = false

    private let nameField = NSTextField()
    private let detail: NSTextField
    private let originalName: String
    private(set) var isEditing = false
    private var finish: ((String?) -> Void)?

    init(name: String, count: Int, isCurrent: Bool, isDefault: Bool, canDelete: Bool, cover: CGImage?,
         watching: Int = 0, vault: URL? = nil, isDraft: Bool = false) {
        self.originalName = name
        let held = count == 0 ? "還沒有收藏" : "\(count) 件收藏"
        let files = vault.map { " · 收進「\($0.lastPathComponent)」" } ?? (watching > 0 ? " · 連結 \(watching) 個資料夾" : "")
        detail = NSTextField(labelWithString: isDraft ? "按 Return 建立，Esc 取消" : held + files)
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
        detail.lineBreakMode = .byTruncatingTail
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
            tools.append(CardTool(icon: .edit, tip: "編輯：名稱與檔案", destructive: false) { [weak self] in self?.onEdit?() })
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
            toolRow.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        if !isDraft {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(name)，\(count) 件收藏" + (isCurrent ? "，目前開著" : ""))
            menu = NSMenu()
            menu?.addItem(ClosureMenuItem("打開") { [weak self] in self?.onOpen?() })
            menu?.addItem(ClosureMenuItem("編輯…") { [weak self] in self?.onEdit?() })
            if !isDefault {
                let delete = ClosureMenuItem("刪除…") { [weak self] in self?.onDelete?() }
                delete.isEnabled = canDelete
                menu?.addItem(delete)
            }
            menu?.autoenablesItems = false
            back.isHidden = true
            back.frame = bounds
            back.autoresizingMask = [.width, .height]
            addSubview(back)
        }
    }

    // MARK: Turning over

    /// Over to the settings and back: a quarter turn away, the other side
    /// swapped in, a quarter turn home.
    func turn(toBack: Bool, animated: Bool) {
        guard back.isHidden == toBack, let layer, !turning else { return }
        guard animated else { back.isHidden = !toBack; return }
        turning = true
        layer.removeAnimation(forKey: "grow")
        let away = Self.rotation(.pi / 2, size: bounds.size), home = CATransform3DIdentity
        let first = CABasicAnimation(keyPath: "transform")
        first.fromValue = home
        first.toValue = away
        first.duration = 0.16
        first.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, let layer = self.layer else { return }
            self.back.isHidden = !toBack
            let second = CABasicAnimation(keyPath: "transform")
            second.fromValue = Self.rotation(-.pi / 2, size: self.bounds.size)
            second.toValue = home
            second.duration = 0.22
            second.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.transform = home
            layer.add(second, forKey: "turn")
            self.turning = false
            if toBack { self.back.focusName() }
        }
        layer.transform = away
        layer.add(first, forKey: "turn")
        CATransaction.commit()
    }

    /// A turn about the card's vertical middle, with a little depth.
    private static func rotation(_ angle: CGFloat, size: CGSize) -> CATransform3D {
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 700
        let toCentre = CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0)
        let turned = CATransform3DConcat(toCentre, CATransform3DMakeRotation(angle, 0, 1, 0))
        return CATransform3DConcat(CATransform3DConcat(turned, perspective),
                                   CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
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

    override func mouseEntered(with event: NSEvent) { if !isEditing, back.isHidden, !turning { lift(true) } }
    override func mouseExited(with event: NSEvent) { if !turning { lift(false) } }

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
        guard !isEditing, back.isHidden, !turning, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }
}

/// A small icon button on a card that shows its ground under the pointer;
/// the destructive one turns red.
@MainActor
private final class CardTool: NSButton {
    var handler: () -> Void
    private let destructive: Bool
    /// Its colour when the pointer isn't on it.
    var restingTint: NSColor = .secondaryLabelColor { didSet { contentTintColor = restingTint } }

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
        contentTintColor = restingTint
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

/// The back of a 珍奇櫃's card: its name, and what happens to the files it
/// collects. Either they stay where they are and up to three folders are
/// linked, or the 珍奇櫃 keeps a copy of each in a folder of its own.
@MainActor
final class CabinetBack: NSView, NSTextFieldDelegate {
    var onDone: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onAddFolder: (() -> Void)?
    var onRemoveFolder: ((URL) -> Void)?
    /// true: keep files (choose a vault); false: back to linking.
    var onKeepFiles: ((Bool) -> Void)?

    private let nameField = NSTextField()
    private let mode = NSSegmentedControl(labels: ["連結資料夾", "收進櫃子"], trackingMode: .selectOne, target: nil, action: nil)
    private let list = NSStackView()
    private var currentName = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16

        let title = NSTextField(labelWithString: "設定")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let done = NSButton(title: "完成", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.keyEquivalent = "\r"

        nameField.font = .systemFont(ofSize: 13)
        nameField.bezelStyle = .roundedBezel
        nameField.placeholderString = "珍奇櫃的名字"
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingTail
        nameField.cell?.isScrollable = true

        mode.controlSize = .small
        mode.segmentDistribution = .fillEqually
        mode.target = self
        mode.action = #selector(modeChanged)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3

        let views: [NSView] = [title, done, Self.caption("名稱"), nameField, Self.caption("收藏的檔案"), mode, list]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let nameCaption = views[2], filesCaption = views[4]
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            done.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            nameCaption.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            nameCaption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            nameField.topAnchor.constraint(equalTo: nameCaption.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            filesCaption.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 14),
            filesCaption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            mode.topAnchor.constraint(equalTo: filesCaption.bottomAnchor, constant: 5),
            mode.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            mode.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            list.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Solid, so nothing of the front shows through.
    private func updateColors() {
        layer?.backgroundColor = resolved(.controlBackgroundColor)
    }

    // Clicks on the back stay on the back (the front would open the 珍奇櫃).
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    private static func caption(_ text: String) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = .secondaryLabelColor
        return t
    }

    func show(name: String, folders: [URL], vault: URL?, maxFolders: Int) {
        currentName = name
        nameField.stringValue = name
        mode.selectedSegment = vault == nil ? 0 : 1
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let vault {
            list.addArrangedSubview(row(vault, removable: false))
            let reveal = Self.link("在 Finder 中顯示", icon: nil) { NSWorkspace.shared.activateFileViewerSelecting([vault]) }
            list.addArrangedSubview(reveal)
        } else {
            if folders.isEmpty { list.addArrangedSubview(Self.note("檔案留在原處；連結的資料夾有新檔案會自動收進來。")) }
            for f in folders { list.addArrangedSubview(row(f, removable: true)) }
            if folders.count < maxFolders {
                list.addArrangedSubview(Self.link("加入資料夾…", icon: .folderAdd) { [weak self] in self?.onAddFolder?() })
            } else {
                list.addArrangedSubview(Self.note("最多 \(maxFolders) 個資料夾"))
            }
        }
    }

    func focusName() {
        window?.makeFirstResponder(nameField)
    }

    private func row(_ folder: URL, removable: Bool) -> NSView {
        let icon = NSImageView(image: Icon.image(.folder, size: 13))
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: FileManager.default.displayName(atPath: folder.path))
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = folder.path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, name]
        if removable {
            let x = ClosureButton(image: Icon.image(.x, size: 11)) { [weak self] in self?.onRemoveFolder?(folder) }
            x.isBordered = false
            x.contentTintColor = .tertiaryLabelColor
            x.toolTip = "不再連結這個資料夾"
            views.append(x)
        }
        let row = NSStackView(views: views)
        row.spacing = 5
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private static func note(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .tertiaryLabelColor
        t.preferredMaxLayoutWidth = 186
        return t
    }

    private static func link(_ title: String, icon: Reicon?, action: @escaping @MainActor () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.isBordered = false
        if let icon { b.image = Icon.image(icon, size: 13); b.imagePosition = .imageLeading }
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = .controlAccentColor
        return b
    }

    @objc private func modeChanged() {
        onKeepFiles?(mode.selectedSegment == 1)
    }

    @objc private func doneTapped() {
        commitName()
        onDone?()
    }

    private func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != currentName else { return }
        currentName = name
        onRename?(name)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitName()
    }
}
