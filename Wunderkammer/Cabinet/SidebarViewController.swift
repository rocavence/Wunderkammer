import AppKit

/// The cabinet, the views the system keeps by itself (by kind, rediscovery),
/// and optional boards last. Nothing here has to be maintained: kind views
/// only appear once something of that kind exists. Items (ours or files)
/// dropped on a board join it; double-click a board to rename it.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let library: Library
    private let table = NSTableView()
    var onSelect: ((Scope.Base) -> Void)?
    var onRandom: (() -> Void)?
    /// The 珍奇櫃 card at the top: the window for switching, adding and removing 珍奇櫃.
    var onManageCabinets: (() -> Void)?
    /// Which 珍奇櫃 is open, shown on the card at the top.
    var cabinetName = "珍奇櫃" { didSet { if cabinetName != oldValue { reload() } } }
    var cabinetID: UUID? { didSet { if cabinetID != oldValue { coverIDs = [] ; reload() } } }
    private let header = CabinetHeader()
    /// The pieces the card's cover was last drawn from.
    private var coverIDs: [UUID] = []

    /// The sidebar follows the space: filters for 收藏 and 地圖, ways in for 漫遊.
    var space: Space = .cabinet {
        didSet { if space != oldValue { reload() } }
    }

    private enum Row {
        case header(String)
        case view(Scope.Base, title: String, icon: Reicon, count: Int?)
        case random
        case board(Board)
    }

    private var rows: [Row] = []
    private(set) var selected: Scope.Base = .all

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.wunderkammerItem, .fileURL, .URL, .string, .png, .tiff])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = NSMenu()
        table.menu?.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // The card above already clears the title bar.
        scroll.automaticallyAdjustsContentInsets = false

        let add = NSButton(image: Icon.image(.plus), target: self, action: #selector(newBoard(_:)))
        add.isBordered = false
        add.toolTip = "新增 board"
        add.contentTintColor = .secondaryLabelColor

        header.target = self
        header.action = #selector(manageCabinets)

        let container = NSView()
        for v in [header, scroll, add] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -6),
            add.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            add.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container

        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Themes appear as the system understands more of the cabinet.
        NotificationCenter.default.addObserver(forName: Understanding.didProgress, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private static let kindIcons: [Scope.KindView: Reicon] = [
        .images: .image, .web: .globe, .text: .text, .media: .clapperboard, .documents: .fileText,
        .books: .book, .films: .film, .music: .vinyl, .products: .shoppingBag, .places: .mapPoint,
    ]

    /// A theme's icon says what family it belongs to; the rest keep the sparkle.
    static func themeIcon(_ label: String) -> Reicon {
        let families: [(Reicon, Set<String>)] = [
            (.people, ["people", "adult", "teen", "child", "baby", "portrait", "face", "crowd", "people group", "people_group"]),
            (.pet, ["animal", "mammal", "cat", "dog", "bird", "fish", "insect", "horse"]),
            (.palette, ["art", "painting", "drawing", "sculpture"]),
            (.paintbrush, ["illustrations", "cartoon", "comics", "anime", "graphic design", "poster"]),
            (.building, ["building", "structure", "architecture", "house", "skyscraper", "cityscape", "city", "interior", "bridge",
                         "door", "window", "portal", "brick", "tile", "wall", "floor", "ceiling", "stairs"]),
            (.car, ["road", "road other", "street", "car", "automobile", "vehicle", "conveyance", "bicycle", "train", "aircraft", "boat"]),
            (.leaf, ["plant", "tree", "foliage", "grass", "leaf", "flower", "garden", "houseplant", "flowerpot", "nature", "forest"]),
            (.cloud, ["sky", "blue sky", "blue_sky", "cloudy", "cloud", "rain", "snow", "night sky", "night_sky"]),
            (.imageMountain, ["land", "outdoor", "mountain", "sea", "ocean", "beach", "lake", "river", "desert", "waterfall"]),
            (.coffee, ["food", "drink", "coffee", "dessert", "fruit", "cake", "bread", "dining", "cooking"]),
            (.fileText, ["document", "printed page", "text", "book", "screenshot", "sign", "handwriting", "typography"]),
            (.vinyl, ["music", "musical instrument", "guitar", "piano", "concert", "record", "turntable"]),
        ]
        return families.first { $0.1.contains(label) }?.0 ?? .sparkles
    }

    /// Kinds of file first; what a page is about (書, 電影…) sits under 網頁.
    private static let fileKinds: [Scope.KindView] = [.images, .web, .text, .media, .documents]
    private static let pageKinds: [Scope.KindView] = [.books, .films, .music, .products, .places]

    /// The card shows the open 珍奇櫃's name, size and newest pieces.
    private func updateHeader() {
        let newest = library.items.sorted { $0.dateAdded > $1.dateAdded }.prefix(4)
        let ids = newest.map(\.id)
        if ids != coverIDs || header.cover == nil {
            coverIDs = ids
            header.cover = CabinetCover.mosaic(newest.map(library.thumbnailURL), seed: cabinetID ?? UUID(),
                                               size: CGSize(width: 72, height: 72))
        }
        header.set(name: cabinetName, count: library.items.count)
    }

    private func reload() {
        updateHeader()
        var r: [Row] = []
        // Every theme two or more pieces share: the more ways in, the better.
        let subjects = Subjects.discover(in: library.items, limit: .max, minimum: 2)
        let themeRows: [Row] = subjects.isEmpty ? [] : [.header("主題")] + subjects.map {
            .view(.subject($0.label), title: $0.title, icon: Self.themeIcon($0.label), count: $0.count)
        }
        func count(_ k: Scope.KindView) -> Int { library.items.reduce(0) { $0 + (k.contains($1) ? 1 : 0) } }
        switch space {
        case .wander:
            // Ways into the wall: everything, what time brings back, where you've been.
            r = [.view(.all, title: "全部", icon: .grid, count: library.items.count),
                 .view(.onThisDay, title: "過去的今天", icon: .calendarDay, count: nil),
                 .view(.forgotten, title: "被遺忘的", icon: .history, count: nil),
                 .view(.trail, title: "足跡", icon: .routing, count: nil),
                 .random] + themeRows
        case .cabinet, .map:
            r = [.view(.all, title: "全部", icon: .grid, count: library.items.count)]
            // What it is as a file, then what it's about (a book, a film…), side by side.
            let kinds: [Row] = Self.fileKinds.compactMap { k in
                let n = count(k)
                return n > 0 ? .view(.kind(k), title: k.title, icon: Self.kindIcons[k]!, count: n) : nil
            }
            let works: [Row] = Self.pageKinds.compactMap { k in
                let n = count(k)
                return n > 0 ? .view(.kind(k), title: k.title, icon: Self.kindIcons[k]!, count: n) : nil
            }
            // Only worth a section when the cabinet holds more than one kind of thing.
            if kinds.count > 1 { r += [.header("類型")] + kinds }
            if !works.isEmpty { r += [.header("作品")] + works }
            r += themeRows
            if !library.collections.isEmpty {
                r += [.header("Boards")] + library.collections.map { .board($0) }
            }
        }
        rows = r
        table.reloadData()
        if case .board(let id) = selected, library.collection(id) == nil {
            select(.all)
        } else if case .kind(let k) = selected, space != .wander,
                  !rows.contains(where: { if case .view(.kind(k), _, _, _) = $0 { return true }; return false }) {
            select(.all)
        } else {
            selectRow(for: selected)
        }
    }

    func select(_ base: Scope.Base) {
        if case .board(let id) = base, library.collection(id) == nil { return select(.all) }
        selected = base
        selectRow(for: base)
        onSelect?(base)
    }

    /// Board-or-cabinet convenience (tests, restoring the last session).
    func select(board: UUID?) { select(board.map { .board($0) } ?? .all) }

    private func base(at row: Int) -> Scope.Base? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .view(let base, _, _, _): return base
        case .board(let b): return .board(b.id)
        default: return nil
        }
    }

    private func selectRow(for base: Scope.Base) {
        // Views without a row of their own (similar to…) leave nothing highlighted.
        guard let row = rows.indices.first(where: { self.base(at: $0) == base }) else {
            table.deselectAll(nil)
            return
        }
        if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
    }

    private func board(at row: Int) -> Board? {
        guard rows.indices.contains(row), case .board(let b) = rows[row] else { return nil }
        return b
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .header: return false
        case .random:
            onRandom?()
            return false
        default: return true
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .view(let base, let title, let icon, let count):
            return cell(title: title, icon: icon, count: count)
        case .random:
            return cell(title: "隨機一件", icon: .shuffle, count: nil, hint: "R")
        case .board(let b):
            let cell = cell(title: b.name, icon: .layers, count: b.itemIDs.count)
            cell.textField?.delegate = self
            cell.textField?.tag = row
            return cell
        }
    }

    private func cell(title: String, icon: Reicon, count: Int?, hint: String? = nil) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = NSImageView(image: Icon.image(icon))
        image.contentTintColor = .secondaryLabelColor
        let text = NSTextField(labelWithString: title)
        text.lineBreakMode = .byTruncatingTail
        text.isEditable = false
        let badge = NSTextField(labelWithString: count.map(String.init) ?? hint ?? "")
        badge.textColor = .tertiaryLabelColor
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for v in [image, text, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = image
        cell.textField = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, let base = base(at: table.selectedRow), base != selected else { return }
        selected = base
        onSelect?(base)
    }

    @objc private func clicked() {}

    // MARK: Rename

    @objc private func doubleClicked() {
        startRename(row: table.clickedRow)
    }

    private func startRename(row: Int) {
        guard board(at: row) != nil,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let b = board(at: field.tag) else { return }
        field.isEditable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == b.name {
            field.stringValue = b.name
        } else {
            library.renameCollection(b.id, to: name)
        }
    }

    @objc private func manageCabinets() { onManageCabinets?() }

    @objc func newBoard(_ sender: Any?) {
        let n = library.collections.count + 1
        let b = library.createCollection(named: "Board \(n)")
        select(.board(b.id))
        if let row = rows.firstIndex(where: { if case .board(let x) = $0 { return x.id == b.id }; return false }) {
            startRename(row: row)
        }
    }

    // MARK: Drop

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .on, rows.indices.contains(row) else { return [] }
        switch rows[row] {
        case .board: return .copy
        // Our own items are already in the cabinet; anything else gets collected.
        case .view(.all, _, _, _): return ItemActions.ids(from: info.draggingPasteboard).isEmpty ? .copy : []
        default: return []
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        importPasteboard(info.draggingPasteboard, library: library, board: board(at: row)?.id)
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard let b = board(at: row) else {
            menu.addItem(ClosureMenuItem("新增 board") { [weak self] in self?.newBoard(nil) })
            return
        }
        menu.addItem(ClosureMenuItem("重新命名") { [weak self] in self?.startRename(row: row) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("刪除 board「\(b.name)」") { [weak self] in
            self?.library.deleteCollection(b.id)
        })
    }
}

/// The open 珍奇櫃 at the top of the sidebar: its cover, name and size, and a
/// chevron saying there are others. The whole card opens the 珍奇櫃 window.
@MainActor
final class CabinetHeader: NSControl {
    private let coverView = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let chevron = NSImageView(image: Icon.image(.chevronDown, size: 14))
    private var hovering = false { didSet { updateFill() } }
    private var pressed = false { didSet { updateFill() } }

    var cover: CGImage? {
        didSet { coverView.image = cover.map { NSImage(cgImage: $0, size: NSSize(width: 36, height: 36)) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 8
        coverView.layer?.masksToBounds = true
        coverView.imageScaling = .scaleAxesIndependently
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        chevron.contentTintColor = .secondaryLabelColor
        for v in [coverView, name, detail, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            coverView.centerYAnchor.constraint(equalTo: centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 36),
            coverView.heightAnchor.constraint(equalToConstant: 36),
            name.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "切換、新增、改名或刪除珍奇櫃"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(name text: String, count: Int) {
        name.stringValue = text
        detail.stringValue = "\(count) 件收藏"
        setAccessibilityLabel("珍奇櫃：\(text)，\(count) 件收藏。按一下切換或管理")
    }

    private func updateFill() {
        let alpha: CGFloat = pressed ? 0.14 : hovering ? 0.1 : 0.06
        layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(alpha))
        chevron.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }
}
