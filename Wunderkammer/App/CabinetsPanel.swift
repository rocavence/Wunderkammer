import AppKit
import ImageIO

/// The 珍奇室 on this Mac as a sheet of cards: each wears a cover made of its
/// newest pieces; a click opens it. Names are typed on the card itself. The
/// default one can't be removed. Opened from the 珍奇室 card atop the sidebar.
@MainActor
final class CabinetsPanel: NSObject {
    var onSwitch: ((UUID) -> Void)?
    /// A 珍奇室 was added, renamed or removed.
    var onChange: (() -> Void)?

    private let cabinets: Cabinets
    private let count: (Cabinets.Entry) -> Int
    private let covers: (Cabinets.Entry) -> [URL]
    private let referenced: (Cabinets.Entry) -> Int
    /// The card turned over to its settings.
    private var flipped: UUID?
    private var cardsByID: [UUID: CabinetCard] = [:]
    private let scrim = Scrim()
    private let settings = CabinetSettings()
    private let sheet: NSWindow
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private let done = NSButton(title: String(localized: "完成"), target: nil, action: nil)
    private var cards: [NSView] = []
    /// A new 珍奇室 waiting for its name: a card, not yet a folder.
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
        wireSettings()
    }

    func present(on window: NSWindow) {
        maxHeight = window.contentLayoutRect.height - 24
        layoutCards()
        window.beginSheet(sheet)
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "珍奇室"))
        title.font = Typography.display(26) ?? .systemFont(ofSize: 26)
        let note = NSTextField(labelWithString: String(localized: "每個珍奇室都有自己的收藏。點卡片打開，按編輯翻到背面設定名稱與檔案。"))
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

    /// Cards in rows of three: every 珍奇室, then the one being named or the
    /// card for adding one.
    private func layoutCards() {
        cards.forEach { $0.removeFromSuperview() }
        cardsByID = [:]
        cards = cabinets.entries.map { entry in
            let watched = cabinets.watched(entry.id), vault = cabinets.vault(entry.id)
            let card = CabinetCard(name: entry.name, count: count(entry), isCurrent: entry.id == cabinets.currentID,
                                   isDefault: entry.folder.isEmpty, canDelete: cabinets.canDelete(entry.id),
                                   cover: cover(of: entry),
                                   watching: watched.count, vault: vault)
            card.onOpen = { [weak self] in self?.open(entry.id) }
            card.onEdit = { [weak self] in self?.openSettings(entry.id) }
            card.onDelete = { [weak self] in self?.delete(entry) }
            // The card being edited is turned away while its settings are out.
            if entry.id == flipped { card.turnAway(animated: false) }
            cardsByID[entry.id] = card
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
        // Tall enough for the settings when they're out.
        let needed = flipped == nil ? 0 : settings.fittingSize.height + 48
        sheet.setContentSize(NSSize(width: sheet.frame.width,
                                    height: max(min(chrome + gridHeight(visibleRows), max(maxHeight, 320)), needed)))
        refreshSettings()
    }

    // MARK: Settings: the card turned over, grown into a panel

    private func openSettings(_ id: UUID) {
        guard flipped == nil, let card = cardsByID[id] else { return }
        flipped = id
        refreshSettings()
        // Room for the panel, even on a short sheet.
        let needed = settings.fittingSize.height + 48
        if let content = sheet.contentView, content.bounds.height < needed {
            sheet.setContentSize(NSSize(width: content.bounds.width, height: needed))
        }
        guard let content = sheet.contentView else { return }
        card.turnAway(animated: true) { [weak self] in
            guard let self else { return }
            self.scrim.frame = content.bounds
            content.addSubview(self.scrim)
            let size = self.settings.fittingSize
            let target = NSRect(x: (content.bounds.width - size.width) / 2, y: (content.bounds.height - size.height) / 2,
                                width: size.width, height: size.height).integral
            self.settings.frame = target
            content.addSubview(self.settings)
            let from = content.convert(card.bounds, from: card)
            self.scrim.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.scrim.animator().alphaValue = 1
            }
            self.settings.swing(from: from, angle: -.pi / 2, toRest: true) { [weak self] in self?.settings.focusName() }
        }
    }

    private func closeSettings() {
        guard let id = flipped, settings.superview != nil else { return }
        settings.commitName()
        let card = cardsByID[id]
        let to = card.map { settings.superview!.convert($0.bounds, from: $0) } ?? settings.frame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.scrim.animator().alphaValue = 0
        }
        settings.swing(from: to, angle: .pi / 2, toRest: false) { [weak self] in
            guard let self else { return }
            self.settings.removeFromSuperview()
            self.scrim.removeFromSuperview()
            self.flipped = nil
            self.cardsByID[id]?.turnBack()
        }
    }

    private func layoutCardsKeepingScroll() {
        let y = scroll.contentView.bounds.origin
        layoutCards()
        scroll.contentView.scroll(to: y)
    }

    private func refreshSettings() {
        guard let id = flipped, let entry = cabinets.entries.first(where: { $0.id == id }) else { return }
        settings.show(name: entry.name, count: count(entry), cover: cover(of: entry, size: CGSize(width: 152, height: 152)), customCover: cabinets.coverURL(id) != nil,
                      folders: cabinets.watched(id), vault: cabinets.vault(id), maxFolders: Cabinets.maxWatched)
    }

    /// The chosen picture (filling the frame), else the newest pieces.
    private func cover(of entry: Cabinets.Entry, size: CGSize = CGSize(width: 408, height: 312)) -> CGImage? {
        CabinetCover.mosaic(cabinets.coverURL(entry.id).map { [$0] } ?? covers(entry), seed: entry.id, size: size)
    }

    private func chooseCover(for id: UUID) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = false
        open.prompt = String(localized: "用這張當封面")
        open.beginSheetModal(for: sheet) { [weak self] response in
            guard let self, response == .OK, let url = open.url else { return }
            if self.cabinets.setCover(from: url, for: id) {
                self.layoutCardsKeepingScroll()
                self.onChange?()
            }
        }
    }

    private func wireSettings() {
        settings.onChooseCover = { [weak self] in
            guard let self, let id = self.flipped else { return }
            self.chooseCover(for: id)
        }
        settings.onResetCover = { [weak self] in
            guard let self, let id = self.flipped else { return }
            self.cabinets.clearCover(for: id)
            self.layoutCardsKeepingScroll()
            self.onChange?()
        }
        scrim.onClick = { [weak self] in self?.closeSettings() }
        settings.onDone = { [weak self] in self?.closeSettings() }
        settings.onRename = { [weak self] name in
            guard let self, let id = self.flipped else { return }
            self.cabinets.rename(id, to: name)
            self.onChange?()
            self.layoutCardsKeepingScroll()
        }
        settings.onAddFolder = { [weak self] in
            guard let self, let id = self.flipped else { return }
            self.addFolder(to: id)
        }
        settings.onRemoveFolder = { [weak self] folder in
            guard let self, let id = self.flipped else { return }
            self.cabinets.unwatch(folder, in: id)
            self.layoutCardsKeepingScroll()
            self.onChange?()
        }
        settings.onKeepFiles = { [weak self] keep in
            guard let self, let id = self.flipped, let entry = self.cabinets.entries.first(where: { $0.id == id }) else { return }
            if keep { self.chooseVault(for: entry) } else {
                self.cabinets.clearVault(for: id)
                self.layoutCardsKeepingScroll()
                self.onChange?()
            }
        }
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        close()
        if id != cabinets.currentID { onSwitch?(id) }
    }

    /// A blank card takes the place of 新增, its name already being typed.
    /// Return makes the 珍奇室; Esc or an empty name leaves nothing behind.
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

    /// Keeping files means a folder of the 珍奇室's own. Chosen first, then
    /// asked: what gets copied, what stops being watched. No means nothing changes.
    private func chooseVault(for entry: Cabinets.Entry) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = String(localized: "用這個資料夾收檔案")
        open.message = String(localized: "「\(entry.name)」收進來的檔案，都會複製一份到這個資料夾，用原本的檔名存。")
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
        if files > 0 { lines.append(String(localized: "\(files) 件收藏的檔案會複製一份到「\(folder.lastPathComponent)」。")) }
        if watched > 0 { lines.append(String(localized: "連結的 \(watched) 個資料夾會停止監看，裡面的檔案不會被動到。")) }
        lines.append(String(localized: "之後收進來的檔案也都會存在這裡。"))
        let alert = NSAlert()
        alert.messageText = String(localized: "改成把檔案收進珍奇室？")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: files > 0 ? String(localized: "複製並改用") : String(localized: "改用"))
        alert.addButton(withTitle: String(localized: "取消"))
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
        open.prompt = String(localized: "監看這個資料夾")
        open.message = String(localized: "放進這個資料夾的檔案會自動收進來，從資料夾拿走就跟著移除。裡面現有的檔案也會一起收進來。")
        open.beginSheetModal(for: sheet) { [weak self] response in
            guard let self, response == .OK, let folder = open.url else { return }
            if self.cabinets.watch(folder, in: id) {
                self.layoutCards()
                self.onChange?()
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "不能監看這個資料夾")
                alert.informativeText = String(localized: "它已經在監看清單裡，或和清單裡的資料夾重疊，或是珍奇室自己存放資料的地方。")
                alert.beginSheetModal(for: self.sheet)
            }
        }
    }

    private func delete(_ entry: Cabinets.Entry) {
        guard cabinets.canDelete(entry.id) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "刪除「\(entry.name)」？")
        alert.informativeText = String(localized: "裡面的 \(count(entry)) 件收藏會一起移到垃圾桶，清空垃圾桶前都還能找回來。")
        alert.addButton(withTitle: String(localized: "刪除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.cabinets.delete(entry.id)
            self.layoutCards()
            self.onChange?()
        }
    }

    @objc private func close() {
        if flipped != nil { return closeSettings() }
        sheet.sheetParent?.endSheet(sheet)
    }

    // Tests.
    var isShown: Bool { sheet.isVisible }
    var windowNumber: Int { sheet.windowNumber }
    func closeForTest() { close() }
    /// A card turned over to its settings, without the turn.
    func flipForTest(_ id: UUID) {
        openSettings(id)
    }
    /// The 新增 card clicked: the blank card waiting for a name.
    func beginAddForTest() { add() }
    /// Typing a name into the card being edited and pressing Return.
    func typeNameForTest(_ name: String) {
        guard let card = cards.compactMap({ $0 as? CabinetCard }).first(where: \.isEditing) else { return }
        card.commitForTest(name)
    }
}

/// One 珍奇室: its cover, its name, how much it holds, and buttons for
/// renaming and removing it. Lifts under the pointer.
@MainActor
private final class CabinetCard: NSView, NSTextFieldDelegate {
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    private var turning = false
    private var turnedAway = false

    private let nameField = NSTextField()
    private let detail: NSTextField
    private let originalName: String
    private(set) var isEditing = false
    private var finish: ((String?) -> Void)?

    init(name: String, count: Int, isCurrent: Bool, isDefault: Bool, canDelete: Bool, cover: CGImage?,
         watching: Int = 0, vault: URL? = nil, isDraft: Bool = false) {
        self.originalName = name
        let held = count == 0 ? String(localized: "還沒有收藏") : String(localized: "\(count) 件收藏")
        let files = vault.map { String(localized: " · 收進「\($0.lastPathComponent)」") } ?? (watching > 0 ? String(localized: " · 連結 \(watching) 個資料夾") : "")
        detail = NSTextField(labelWithString: isDraft ? String(localized: "按 Return 建立，Esc 取消") : held + files)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = isCurrent || isDraft ? 2 : 0.5
        layer?.borderColor = (isCurrent || isDraft ? NSColor.accent : NSColor.separatorColor).cgColor
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
        nameField.placeholderString = String(localized: "替它取個名字")
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
        if isCurrent { badges.append(Self.pill(String(localized: "目前"), fill: .accent, text: .white)) }
        if isDefault { badges.append(Self.pill(String(localized: "預設"), fill: NSColor.black.withAlphaComponent(0.5), text: .white)) }
        let badgeRow = NSStackView(views: badges)
        badgeRow.spacing = 6
        views.append(badgeRow)

        // Rename and remove, always in view beside the name. The default
        // 珍奇室 has no remove; the open one can't be removed while open.
        var tools: [NSView] = []
        if !isDraft {
            tools.append(CardTool(icon: .edit, tip: String(localized: "編輯：名稱與檔案"), destructive: false) { [weak self] in self?.onEdit?() })
            if !isDefault {
                let trash = CardTool(icon: .trash, tip: canDelete ? String(localized: "刪除") : String(localized: "要先打開別的珍奇室，才能刪除這個"),
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
            setAccessibilityLabel(String(localized: "\(name)，\(count) 件收藏") + (isCurrent ? String(localized: "，目前開著") : ""))
            menu = NSMenu()
            menu?.addItem(ClosureMenuItem(String(localized: "打開")) { [weak self] in self?.onOpen?() })
            menu?.addItem(ClosureMenuItem(String(localized: "編輯…")) { [weak self] in self?.onEdit?() })
            if !isDefault {
                let delete = ClosureMenuItem(String(localized: "刪除…")) { [weak self] in self?.onDelete?() }
                delete.isEnabled = canDelete
                menu?.addItem(delete)
            }
            menu?.autoenablesItems = false
        }
    }

    // MARK: Turning over

    /// A quarter turn away, edge on: its settings take over from there.
    func turnAway(animated: Bool, then: (() -> Void)? = nil) {
        guard let layer else { return }
        turnedAway = true
        layer.removeAnimation(forKey: "grow")
        let away = Self.rotation(.pi / 2, size: bounds.size)
        guard animated else { layer.transform = away; then?(); return }
        turning = true
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
        a.toValue = away
        a.duration = 0.16
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.turning = false
            then?()
        }
        layer.transform = away
        layer.add(a, forKey: "turn")
        CATransaction.commit()
    }

    /// The last quarter turn home, when the settings fold back into it.
    func turnBack() {
        guard let layer else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = Self.rotation(-.pi / 2, size: bounds.size)
        a.toValue = CATransform3DIdentity
        a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = CATransform3DIdentity
        layer.add(a, forKey: "turn")
        turnedAway = false
    }

    /// A turn about the card's vertical middle, with a little depth.
    static func rotation(_ angle: CGFloat, size: CGSize) -> CATransform3D {
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

    override func mouseEntered(with event: NSEvent) { if !isEditing, !turnedAway, !turning { lift(true) } }
    override func mouseExited(with event: NSEvent) { if !turning, !turnedAway { lift(false) } }

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
        guard !isEditing, !turnedAway, !turning, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
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

/// The newest pieces of a 珍奇室 as one picture, for its card and the sidebar.
enum CabinetCover {

    /// One fills it, two side by side, three as one large and two small, four
    /// as a square of four. None: a gradient of the 珍奇室's own colour.
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

/// The last card: a dashed outline inviting a new 珍奇室.
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
        let label = NSTextField(labelWithString: String(localized: "新增珍奇室"))
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
        setAccessibilityLabel(String(localized: "新增珍奇室"))
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
        layer?.backgroundColor = NSColor.accent.withAlphaComponent(0.08).cgColor
        outline.strokeColor = resolved(.accent)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        outline.strokeColor = resolved(.tertiaryLabelColor)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onAdd?() }
    }
}

/// Dims the cards behind the settings; a click on it puts them away.
@MainActor
private final class Scrim: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// A 珍奇室's settings: the back of its card, grown to a panel with room to
/// breathe. Its name, and what happens to the files it collects: they stay
/// where they are (and up to three folders are linked), or the 珍奇室 keeps a
/// copy of each in a folder of its own. One or the other.
@MainActor
final class CabinetSettings: NSView, NSTextFieldDelegate {
    var onDone: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onAddFolder: (() -> Void)?
    var onRemoveFolder: ((URL) -> Void)?
    /// true: keep files (choose a vault); false: back to linking.
    var onKeepFiles: ((Bool) -> Void)?
    var onChooseCover: (() -> Void)?
    var onResetCover: (() -> Void)?

    static let width: CGFloat = 480
    private static let pad: CGFloat = 28

    private let coverView = CoverWell()
    private let heading = NSTextField(labelWithString: "")
    private let subheading = NSTextField(labelWithString: "")
    private let coverActions = NSStackView()
    private let nameField = NSTextField()
    private let linkTile = ChoiceTile(icon: .link, title: String(localized: "連結資料夾"), detail: String(localized: "檔案留在原處。連結的資料夾裡有新檔案，會自動收進來。"))
    private let keepTile = ChoiceTile(icon: .box, title: String(localized: "收進櫃子"), detail: String(localized: "每個收進來的檔案，都複製一份到你選的資料夾。"))
    private let detail = NSStackView()
    private var currentName = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.borderWidth = 0.5
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -10)

        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 14
        coverView.layer?.masksToBounds = true
        coverView.imageScaling = .scaleAxesIndependently
        heading.font = Typography.display(22, weight: .medium) ?? .systemFont(ofSize: 22, weight: .medium)
        heading.lineBreakMode = .byTruncatingTail
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor
        coverView.onClick = { [weak self] in self?.onChooseCover?() }
        coverActions.spacing = 12
        let titles = NSStackView(views: [heading, subheading, coverActions])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [coverView, titles])
        header.spacing = 14
        header.alignment = .centerY

        nameField.font = .systemFont(ofSize: 15)
        nameField.bezelStyle = .roundedBezel
        nameField.controlSize = .large
        nameField.placeholderString = String(localized: "珍奇室的名字")
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingTail
        nameField.cell?.isScrollable = true

        linkTile.onPick = { [weak self] in self?.pick(keep: false) }
        keepTile.onPick = { [weak self] in self?.pick(keep: true) }
        let tiles = NSStackView(views: [linkTile, keepTile])
        tiles.distribution = .fillEqually
        tiles.spacing = 12

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6

        let done = NSButton(title: String(localized: "完成"), target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.distribution = .fill

        let body = NSStackView(views: [header, Self.caption(String(localized: "名稱")), nameField, Self.caption(String(localized: "收藏的檔案")), tiles, detail, footer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.setCustomSpacing(24, after: header)
        body.setCustomSpacing(22, after: nameField)
        body.setCustomSpacing(14, after: tiles)
        body.setCustomSpacing(24, after: detail)
        body.edgeInsets = NSEdgeInsets(top: Self.pad, left: Self.pad, bottom: 22, right: Self.pad)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        let inner = Self.width - Self.pad * 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 76),
            coverView.heightAnchor.constraint(equalToConstant: 76),
            nameField.widthAnchor.constraint(equalToConstant: inner),
            tiles.widthAnchor.constraint(equalToConstant: inner),
            detail.widthAnchor.constraint(equalToConstant: inner),
            footer.widthAnchor.constraint(equalToConstant: inner),
            heading.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 70),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        layer?.borderColor = resolved(.separatorColor)
    }

    // Clicks inside stay inside (the dimmed cards behind would close it).
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    private static func caption(_ text: String) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
    }

    func show(name: String, count: Int, cover: CGImage?, customCover: Bool, folders: [URL], vault: URL?, maxFolders: Int) {
        coverActions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        coverActions.addArrangedSubview(Self.link(String(localized: "更換封面…")) { [weak self] in self?.onChooseCover?() })
        if customCover { coverActions.addArrangedSubview(Self.link(String(localized: "恢復自動")) { [weak self] in self?.onResetCover?() }) }
        currentName = name
        heading.stringValue = name
        subheading.stringValue = count == 0 ? String(localized: "還沒有收藏") : String(localized: "\(count) 件收藏")
        coverView.image = cover.map { NSImage(cgImage: $0, size: .zero) }
        if nameField.currentEditor() == nil { nameField.stringValue = name }
        linkTile.isChosen = vault == nil
        keepTile.isChosen = vault != nil
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let vault {
            detail.addArrangedSubview(row(vault, removable: false))
            detail.addArrangedSubview(Self.button(String(localized: "在 Finder 中顯示"), icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([vault]) })
        } else {
            if folders.isEmpty { detail.addArrangedSubview(Self.note(String(localized: "還沒有連結資料夾。"))) }
            for f in folders { detail.addArrangedSubview(row(f, removable: true)) }
            let add = Self.button(folders.count < maxFolders ? String(localized: "加入資料夾…") : String(localized: "最多 \(maxFolders) 個資料夾"), icon: .folderAdd) { [weak self] in
                self?.onAddFolder?()
            }
            add.isEnabled = folders.count < maxFolders
            detail.addArrangedSubview(add)
        }
    }

    func focusName() {
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    /// A folder: its name, where it is, and a way to unlink it.
    private func row(_ folder: URL, removable: Bool) -> NSView {
        let icon = NSImageView(image: Icon.image(.folder, size: 16))
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: FileManager.default.displayName(atPath: folder.path))
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let path = NSTextField(labelWithString: (folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 11.5)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingHead
        for t in [name, path] { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let texts = NSStackView(views: [name, path])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        var views: [NSView] = [icon, texts]
        if removable {
            let x = ClosureButton(image: Icon.image(.x, size: 12)) { [weak self] in self?.onRemoveFolder?(folder) }
            x.isBordered = false
            x.contentTintColor = .tertiaryLabelColor
            x.toolTip = String(localized: "不再連結這個資料夾")
            views.append(NSView())
            views.append(x)
        }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.05))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.width - Self.pad * 2).isActive = true
        return row
    }

    private static func link(_ title: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.isBordered = false
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = .accent
        return b
    }

    private static func note(_ text: String) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .tertiaryLabelColor
        return t
    }

    private static func button(_ title: String, icon: Reicon, action: @escaping @MainActor () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.image = Icon.image(icon, size: 14)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        return b
    }

    private func pick(keep: Bool) {
        guard keepTile.isChosen != keep else { return }
        onKeepFiles?(keep)
    }

    @objc private func doneTapped() {
        commitName()
        onDone?()
    }

    func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != currentName else { return }
        currentName = name
        onRename?(name)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitName()
    }

    /// Turns in from (or out to) `rect` in the superview's space while
    /// growing to (or shrinking from) its own frame.
    func swing(from rect: NSRect, angle: CGFloat, toRest: Bool, then: @escaping () -> Void) {
        guard let layer else { return then() }
        let size = frame.size
        let spin = CabinetCard.rotation(angle, size: size)
        let fit = CATransform3DConcat(CATransform3DMakeScale(rect.width / size.width, rect.height / size.height, 1),
                                      CATransform3DMakeTranslation(rect.minX - frame.minX, rect.minY - frame.minY, 0))
        let edge = CATransform3DConcat(spin, fit)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = toRest ? edge : CATransform3DIdentity
        a.toValue = toRest ? CATransform3DIdentity : edge
        a.duration = toRest ? 0.3 : 0.2
        a.timingFunction = CAMediaTimingFunction(name: toRest ? .easeOut : .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock(then)
        layer.transform = toRest ? CATransform3DIdentity : edge
        layer.add(a, forKey: "swing")
        CATransaction.commit()
    }
}

/// One of the two ways to keep files: an icon, a name, a line of what it
/// means. The chosen one is outlined and ticked.
@MainActor
private final class ChoiceTile: NSView {
    var onPick: (() -> Void)?
    var isChosen = false { didSet { updateLook() } }
    private let icon: NSImageView
    private let tick = NSImageView(image: Icon.image(.check, size: 14))

    init(icon: Reicon, title: String, detail: String) {
        self.icon = NSImageView(image: Icon.optical(icon, size: 22))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = .systemFont(ofSize: 11.5)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 170
        for v in [self.icon, name, text, tick] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            self.icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            self.icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tick.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tick.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            name.topAnchor.constraint(equalTo: self.icon.bottomAnchor, constant: 10),
            name.leadingAnchor.constraint(equalTo: self.icon.leadingAnchor),
            text.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            text.leadingAnchor.constraint(equalTo: self.icon.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        layer?.borderWidth = isChosen ? 2 : 1
        layer?.borderColor = resolved(isChosen ? .accent : .separatorColor)
        layer?.backgroundColor = resolved(isChosen ? NSColor.accent.withAlphaComponent(0.08) : .clear)
        icon.contentTintColor = isChosen ? .accent : .secondaryLabelColor
        tick.contentTintColor = .accent
        tick.isHidden = !isChosen
        setAccessibilityValue(isChosen)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
}

/// The cover on the settings: a click changes it, and says so under the pointer.
@MainActor
private final class CoverWell: NSImageView {
    var onClick: (() -> Void)?
    private let veil = CALayer()
    private let word = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        veil.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        veil.opacity = 0
        word.string = NSAttributedString(string: String(localized: "更換"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        word.alignmentMode = .center
        word.contentsScale = 2
        veil.addSublayer(word)
        toolTip = String(localized: "更換封面")
        setAccessibilityLabel(String(localized: "更換封面"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if veil.superlayer == nil { layer?.addSublayer(veil) }
        veil.frame = bounds
        word.frame = CGRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18)
        word.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { veil.opacity = 1 }
    override func mouseExited(with event: NSEvent) { veil.opacity = 0 }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
