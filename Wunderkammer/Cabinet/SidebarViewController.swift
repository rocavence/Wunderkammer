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
    /// The 展室 card at the top: the window for switching, adding and removing 展室.
    var onManageCabinets: (() -> Void)?
    /// Which 展室 is open, shown on the card at the top.
    var cabinetName = String(localized: "展室") { didSet { if cabinetName != oldValue { reload() } } }
    var cabinetID: UUID? { didSet { if cabinetID != oldValue { coverIDs = [] ; reload() } } }
    private let header = CabinetHeader()
    /// A picture chosen as the open 展室's cover; else its newest pieces.
    var coverPicture: URL? { didSet { coverIDs = []; reload() } }
    /// The pieces the card's cover was last drawn from.
    private var coverIDs: [UUID] = []

    /// The sidebar follows the space: filters for 收藏 and 工作台, ways in for 漫遊.
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
        // Overlaid, never taking width: a section opening doesn't nudge the rows.
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        // The card above already clears the title bar.
        scroll.automaticallyAdjustsContentInsets = false

        let add = NSButton(image: Icon.image(.plus), target: self, action: #selector(newBoard(_:)))
        add.isBordered = false
        add.toolTip = String(localized: "新增釘選版")
        add.contentTintColor = .secondaryLabelColor

        header.target = self
        header.action = #selector(manageCabinets)

        let container = NSView()
        for v in [header, scroll, add] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // On the top bar's row, under the traffic lights' own.
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: TopBar.top),
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

    /// A round swatch of a colour, ringed so white shows on white.
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let dot = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 11, height: 11))
            color.setFill()
            dot.fill()
            NSColor.separatorColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            return true
        }
    }

    /// Which group a view belongs to and its icon, for the heading above it:
    /// 格式 (what it is as a file), 分類 (what it's about), 主題…
    static func kicker(for base: Scope.Base) -> (label: String, icon: Reicon)? {
        switch base {
        case .all: nil
        case .kind(let k): (fileKinds.contains(k) ? String(localized: "格式") : String(localized: "分類"), kindIcons[k] ?? .file)
        case .subject(let label): (String(localized: "主題"), themeIcon(label))
        case .color: (String(localized: "顏色"), .palette)
        case .board: (String(localized: "釘選版"), .layers)
        case .onThisDay: (String(localized: "漫遊"), .calendarDay)
        case .forgotten: (String(localized: "漫遊"), .history)
        case .trail: (String(localized: "漫遊"), .routing)
        case .site: (String(localized: "網站"), .globe)
        case .mentions: (String(localized: "名字"), .people)
        case .similar: (String(localized: "相似"), .image)
        case .answer: (String(localized: "回答"), .sparkles)
        }
    }

    /// Kinds of file first; what a page is about (書, 電影…) sits under 網頁.
    private static let fileKinds: [Scope.KindView] = [.images, .web, .text, .media, .documents]
    private static let pageKinds: [Scope.KindView] = [.books, .films, .music, .products, .places]

    /// The card shows the open 展室's name, size and newest pieces.
    private func updateHeader() {
        let newest = library.items.sorted { $0.dateAdded > $1.dateAdded }.prefix(4)
        let ids = newest.map(\.id)
        if ids != coverIDs || header.cover == nil {
            coverIDs = ids
            header.cover = CabinetCover.mosaic(coverPicture.map { [$0] } ?? newest.map(library.thumbnailURL),
                                               seed: cabinetID ?? UUID(), size: CGSize(width: 72, height: 72))
        }
        header.set(name: cabinetName, count: library.items.count)
    }

    private func reload() {
        updateHeader()
        rows = buildRows()
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

    private func buildRows() -> [Row] {
        var r: [Row] = []
        // Every theme two or more pieces share: the more ways in, the better.
        let subjects = Subjects.discover(in: library.items, limit: .max, minimum: 2)
        let themeRows: [Row] = subjects.isEmpty ? [] : [.header("主題")] + (isFolded("主題") ? [] : subjects.map {
            .view(.subject($0.label), title: $0.title, icon: Self.themeIcon($0.label), count: $0.count)
        })
        // The colours the pictures are mostly made of, in spectrum order.
        let colourRows: [Row] = {
            let rows: [Row] = Colours.all.compactMap { c in
                let n = library.items.reduce(0) { $0 + ($1.colors?.contains(c.name) == true ? 1 : 0) }
                return n > 0 ? .view(.color(c.name), title: c.title, icon: .palette, count: n) : nil
            }
            return rows.isEmpty ? [] : [.header("顏色")] + (isFolded("顏色") ? [] : rows)
        }()
        func count(_ k: Scope.KindView) -> Int { library.items.reduce(0) { $0 + (k.contains($1) ? 1 : 0) } }
        switch space {
        case .wander:
            // Ways into the wall: everything, what time brings back, where you've been.
            r = [.view(.all, title: String(localized: "全部"), icon: .grid, count: library.items.count),
                 .view(.onThisDay, title: String(localized: "過去的今天"), icon: .calendarDay, count: nil),
                 .view(.forgotten, title: String(localized: "被遺忘的"), icon: .history, count: nil),
                 .view(.trail, title: String(localized: "足跡"), icon: .routing, count: nil),
                 .random] + themeRows + colourRows
        case .cabinet, .map:
            r = [.view(.all, title: String(localized: "全部"), icon: .grid, count: library.items.count)]
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
            if kinds.count > 1 { r += [.header("格式")] + kinds }
            if !works.isEmpty { r += [.header("分類")] + works }
            r += themeRows + colourRows
            if !library.collections.isEmpty {
                r += [.header("釘選版")] + library.collections.map { .board($0) }
            }
        }
        return r
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

    /// Headers are ordinary rows (not group rows): laid out in the same frame
    /// as the rows under them, so a header's arrow and the counts share one edge.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

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
            let label = NSTextField(labelWithString: Self.sectionTitle(title))
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let row = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(label)
            NSLayoutConstraint.activate([
                // A little left of the icons below, as sidebar headers sit.
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.headerInset),
                label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            ])
            guard Self.foldable.contains(title) else { return row }
            // Long sections fold. The arrow, cropped to its strokes, ends where
            // the counts end, pointing down open and right folded.
            let chevron = NSImageView(image: Self.chevron(folded: isFolded(title)))
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Self.countInset),
                chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
            row.toolTip = isFolded(title) ? String(localized: "展開\(Self.sectionTitle(title))") : String(localized: "收起\(Self.sectionTitle(title))")
            return row
        case .view(let base, let title, let icon, let count):
            let c = cell(title: title, icon: icon, count: count)
            // A colour is shown by itself, not by an icon.
            if case .color(let name) = base {
                c.imageView?.image = Self.swatch(Colours.swatch(name))
                c.imageView?.contentTintColor = nil
            }
            return c
        case .random:
            return cell(title: String(localized: "隨機一件"), icon: .shuffle, count: nil, hint: "R")
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
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.countInset),
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

    @objc private func clicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), case .header(let title) = rows[row], Self.foldable.contains(title) else { return }
        toggleFold(title)
    }

    // MARK: Folding

    /// Headers start this far left of the rows' icons.
    static let headerInset: CGFloat = -7
    /// Counts (and fold arrows) end this far in from the row's right edge.
    static let countInset: CGFloat = 6

    static func chevron(folded: Bool) -> NSImage {
        Icon.optical(folded ? .chevronRight : .chevronDown, size: 11, fill: 0.95)
    }

    /// Sections that can grow long fold away; the rest are short enough to stay open.
    static let foldable: Set<String> = ["顏色", "主題"]

    /// Section ids stay Chinese (fold state is keyed by them); only the shown title is localized.
    static func sectionTitle(_ id: String) -> String {
        switch id {
        case "格式": String(localized: "格式")
        case "分類": String(localized: "分類")
        case "主題": String(localized: "主題")
        case "顏色": String(localized: "顏色")
        case "釘選版": String(localized: "釘選版")
        default: id
        }
    }

    /// Folded until opened: they're long.
    func isFolded(_ section: String) -> Bool {
        UserDefaults.standard.object(forKey: "sidebar.folded.v2.\(section)") as? Bool ?? true
    }

    /// Right edges, in the window, of a fold chevron and of a count (tests).
    var chevronAndCountEdges: (chevron: CGFloat, count: CGFloat)? {
        var chevron: CGFloat?, count: CGFloat?
        for row in 0..<rows.count {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            switch rows[row] {
            case .header(let t) where Self.foldable.contains(t):
                if let c = cell.subviews.compactMap({ $0 as? NSImageView }).first, let img = c.image {
                    // The drawn arrow, not the image view's box.
                    let f = c.convert(c.bounds, to: nil)
                    chevron = f.midX + img.size.width / 2
                }
            case .view(_, _, _, let n) where n != nil:
                if let badge = (cell as? NSTableCellView)?.subviews.compactMap({ $0 as? NSTextField }).last {
                    // Where the digits end: a label keeps 2 points of padding at its edge.
                    count = badge.convert(badge.bounds, to: nil).maxX - 2
                }
            default: break
            }
        }
        guard let chevron, let count else { return nil }
        return (chevron, count)
    }

    /// How many rows the sidebar shows (tests).
    var rowCount: Int { rows.count }

    /// As in Zen: the section's rows slide in under its header or slide away,
    /// the rest stays put; the chevron turns with them.
    func toggleFold(_ section: String) {
        UserDefaults.standard.set(!isFolded(section), forKey: "sidebar.folded.v2.\(section)")
        guard let h = rows.firstIndex(where: { if case .header(section) = $0 { return true }; return false }) else { return reload() }
        let old = rows
        let new = buildRows()
        // The section's own rows: those after its header up to the next header.
        func body(_ list: [Row], from header: Int) -> Int {
            var n = 0
            for row in list.dropFirst(header + 1) {
                if case .header = row { break }
                n += 1
            }
            return n
        }
        let before = body(old, from: h), after = body(new, from: h)
        guard new.count - after == old.count - before else { return reload() }
        if let cell = table.view(atColumn: 0, row: h, makeIfNecessary: false),
           let chevron = cell.subviews.compactMap({ $0 as? NSImageView }).first {
            chevron.image = Self.chevron(folded: after == 0)
            cell.toolTip = after == 0 ? String(localized: "展開\(Self.sectionTitle(section))") : String(localized: "收起\(Self.sectionTitle(section))")
        }
        rows = new
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            table.beginUpdates()
            if before > 0 { table.removeRows(at: IndexSet(h + 1 ..< h + 1 + before), withAnimation: [.slideUp, .effectFade]) }
            if after > 0 { table.insertRows(at: IndexSet(h + 1 ..< h + 1 + after), withAnimation: [.slideDown, .effectFade]) }
            table.endUpdates()
        }
        selectRow(for: selected)
    }

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
        let b = library.createCollection(named: String(localized: "釘選版 \(n)"))
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
            menu.addItem(ClosureMenuItem(String(localized: "新增釘選版")) { [weak self] in self?.newBoard(nil) })
            return
        }
        menu.addItem(ClosureMenuItem(String(localized: "重新命名")) { [weak self] in self?.startRename(row: row) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "刪除釘選版「\(b.name)」")) { [weak self] in
            self?.library.deleteCollection(b.id)
        })
    }
}

/// The open 展室 at the top of the sidebar: its cover, name and size, and a
/// chevron saying there are others. The whole card opens the 展室 window.
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
        toolTip = String(localized: "切換、新增、改名或刪除展室")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(name text: String, count: Int) {
        name.stringValue = text
        detail.stringValue = String(localized: "\(count) 件收藏")
        setAccessibilityLabel(String(localized: "展室：\(text)，\(count) 件收藏。按一下切換或管理"))
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
