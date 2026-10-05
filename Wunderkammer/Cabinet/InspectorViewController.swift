import AppKit

/// ⌘I: everything the system knows about the focused curiosity. Read-only:
/// metadata is gathered, never asked for.
@MainActor
final class InspectorViewController: NSViewController {
    private let library: Library
    private let stack = NSStackView()
    private var itemID: UUID?
    var currentID: UUID? { itemID }
    var onSelectRelated: ((UUID) -> Void)?
    /// A relation was followed: the other curiosity, and what connects them.
    var onFollowRelation: ((UUID, String) -> Void)?
    /// A name or a site was clicked: show everything connected to it.
    var onOpenView: ((Scope.Base) -> Void)?
    /// Supplies related items (filled in by the understanding layer).
    var related: ((Item) -> [Item])?
    /// How you last arrived at an item ("上次是從搜尋…來的").
    var arrival: ((Item) -> String?)?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 28, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        // A card of its own, a little apart from the cabinet on every side:
        // nothing runs together with the content, and the title bar's strip
        // above is just more of the window around it.
        let card = InspectorCard()
        let column = InspectorColumn()
        for v in [card, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        column.addSubview(card)
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: column.topAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        view = column
        // The cabinet changes often while it's being understood: redraw only
        // when the piece on show has changed, at most once per moment.
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
        show(nil)
    }

    func show(_ id: UUID?) {
        guard id != itemID || shown == nil else { return }
        itemID = id
        refresh()
    }

    /// What was drawn last: the same piece, unchanged, isn't drawn again.
    private var shown: Item?
    private var refreshPending = false

    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                let now = self.itemID.flatMap(self.library.item)
                if now != self.shown || (now == nil) != (self.shown == nil) { self.refresh() }
            }
        }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        shown = itemID.flatMap(library.item)
        // Nothing in the panel is wider than the panel: text wraps to it.
        defer {
            for v in stack.arrangedSubviews {
                v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                         constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
            }
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let id = itemID, let item = library.item(id) else {
            // Centered and calm, saying what will appear here.
            let icon = NSImageView(image: Icon.image(.infoCircle, size: 28))
            icon.contentTintColor = .tertiaryLabelColor
            let hint = label(String(localized: "選一件收藏\n這裡會顯示系統替它記下的一切：\n它是什麼、從哪來、和什麼有關"), size: 12.5, color: .secondaryLabelColor)
            hint.alignment = .center
            let empty = NSStackView(views: [icon, hint])
            empty.orientation = .vertical
            empty.spacing = 10
            stack.addArrangedSubview(empty)
            stack.setCustomSpacing(0, after: empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
            stack.edgeInsets.top = max(18, (view.bounds.height - 140) / 2)
            return
        }
        stack.edgeInsets.top = 18

        if let image = NSImage(contentsOf: library.thumbnailURL(item)) {
            let picture = NSImageView(image: image)
            picture.imageScaling = .scaleProportionallyUpOrDown
            // Its own pixel size mustn't make the panel wider; it fits the panel.
            picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            picture.wantsLayer = true
            picture.layer?.cornerRadius = 10
            picture.layer?.masksToBounds = true
            picture.layer?.borderWidth = 0.5
            picture.layer?.borderColor = NSColor.separatorColor.cgColor
            picture.translatesAutoresizingMaskIntoConstraints = false
            let ratio = CGFloat(item.pixelHeight) / CGFloat(max(item.pixelWidth, 1))
            stack.addArrangedSubview(picture)
            NSLayoutConstraint.activate([
                picture.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
                // Never taller than wide: a tall page would push everything else out of sight.
                picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: min(max(ratio, 0.3), 1.0)),
            ])
            stack.setCustomSpacing(16, after: picture)
        }

        // What it is, where it's from, when: one quiet line under the name.
        let title = label(item.displayTitle, size: 18, serif: true)
        title.maximumNumberOfLines = 3
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(6, after: title)
        let about = [Self.kindName(item), item.domain, item.released.map { String($0.prefix(4)) }, Rediscovery.ageLine(item)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let line = label(about.joined(separator: " · "), size: 12, color: .secondaryLabelColor)
        line.maximumNumberOfLines = 2
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(14, after: line)

        // What you can do with it, right away: two to a row, sharing the
        // width, so a narrow inspector never has to be wider than its buttons.
        let actions = NSStackView()
        if library.openURL(item) != nil {
            actions.addArrangedSubview(button(String(localized: "打開"), icon: .arrowUpRight) { [weak self] in
                guard let self, let url = self.library.openURL(item) else { return }
                self.library.markViewed(item.id)
                NSWorkspace.shared.open(url)
            })
        }
        if let page = library.archiveURL(item) {
            actions.addArrangedSubview(button(String(localized: "看快照"), icon: .fileText) { NSWorkspace.shared.open(page) })
        }
        if let file = library.originalURL(item), item.storedFilename == nil {
            actions.addArrangedSubview(button(String(localized: "在 Finder 顯示"), icon: .file) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            })
        }
        if item.storedFilename == nil, item.filePath != nil, library.originalURL(item) != nil {
            actions.addArrangedSubview(button(String(localized: "複製到展室"), icon: .copy) { [weak self] in
                guard let self else { return }
                Task {
                    await self.library.copyIntoLibrary([item.id])
                    self.show(item.id)
                }
            })
        }
        if let url = item.url, actions.arrangedSubviews.count < 3 {
            actions.addArrangedSubview(button(String(localized: "拷貝連結"), icon: .link) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        let buttons = actions.arrangedSubviews
        if !buttons.isEmpty {
            buttons.forEach { $0.removeFromSuperview() }
            let grid = NSStackView()
            grid.orientation = .vertical
            grid.alignment = .leading
            grid.spacing = 6
            for start in stride(from: 0, to: buttons.count, by: 2) {
                let row = NSStackView(views: Array(buttons[start..<min(start + 2, buttons.count)]))
                row.spacing = 6
                row.distribution = .fillEqually
                grid.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }

        if let arrived = arrival?(item) {
            // Breaks only between steps, never inside a word.
            let way = label(Self.unbreakable(arrived), size: 11, color: .secondaryLabelColor)
            way.maximumNumberOfLines = 3
            stack.addArrangedSubview(way)
        }

        // How it relates to other kinds of things: the same person, a mention, the same city.
        let relations = CrossMedia.relations(of: item, in: library.items).prefix(8)
        if !relations.isEmpty {
            section(String(localized: "關聯"))
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 4
            for r in relations {
                guard let other = library.item(r.other) else { continue }
                let title = String((CrossMedia.name(of: other) ?? other.displayTitle).prefix(40))
                rows.addArrangedSubview(link(r.sentence(title: title, kindName: Self.kindName(other))) { [weak self] in
                    self?.onFollowRelation?(other.id, r.label)
                })
            }
            stack.addArrangedSubview(rows)
        }

        // The rest of what the system noted (kind and site are in the line above).
        let facts = Self.facts(item, library: library).filter { $0.0 != Self.kindTitle && $0.0 != Self.sourceTitle }
        if !facts.isEmpty {
            section(String(localized: "資訊"))
            for (key, value) in facts {
                // Colours as colours.
                if key == Self.colorTitle, let names = item.colors { stack.addArrangedSubview(swatches(Array(names.prefix(3)))); continue }
                let r = row(key, value)
                // The full path where it's shortened.
                if key == Self.locationTitle || key == Self.originalLocationTitle, let path = item.filePath { r.toolTip = (path as NSString).abbreviatingWithTildeInPath }
                stack.addArrangedSubview(r)
            }
        }

        // Names and the site lead to everything else they appear in.
        var links: [(String, Scope.Base)] = (item.entities ?? []).prefix(8).map { ($0.name, .mentions($0.name)) }
        if let domain = item.domain { links.append((domain, .site(domain))) }
        let connected = links.filter { library.items(for: Scope(base: $0.1)).count > 1 }
        if !connected.isEmpty {
            section(String(localized: "也出現在"))
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 4
            for (title, base) in connected {
                let n = library.items(for: Scope(base: base)).count
                rows.addArrangedSubview(link("\(title)  \(n)") { [weak self] in self?.onOpenView?(base) })
            }
            stack.addArrangedSubview(rows)
        }

        if let text = item.ocrText, !text.isEmpty {
            section(String(localized: "圖中的文字"))
            let body = label(String(text.prefix(600)), size: 12, color: .secondaryLabelColor)
            body.maximumNumberOfLines = 8
            stack.addArrangedSubview(body)
        }
        if let labels = item.labels, !labels.isEmpty {
            section(String(localized: "系統看到的"))
            let tags = label(labels.prefix(8).map(Subjects.title).joined(separator: "  ·  "), size: 12, color: .secondaryLabelColor)
            tags.maximumNumberOfLines = 3
            stack.addArrangedSubview(tags)
        }

        if let related = related?(item), !related.isEmpty {
            section(String(localized: "相關的收藏"))
            let columns = 3
            // Three across fit the narrowest the panel gets (the sidebar's minimum).
            let side: CGFloat = 56
            let grid = NSGridView(numberOfColumns: columns, rows: 0)
            grid.rowSpacing = 6
            grid.columnSpacing = 6
            var row: [NSView] = []
            for r in related.prefix(6) {
                guard let image = NSImage(contentsOf: library.thumbnailURL(r)) else { continue }
                let b = ClosureButton(image: image) { [weak self] in self?.onSelectRelated?(r.id) }
                b.imageScaling = .scaleProportionallyUpOrDown
                b.isBordered = false
                b.toolTip = r.displayTitle
                b.setAccessibilityLabel(r.displayTitle)
                b.wantsLayer = true
                b.layer?.cornerRadius = 6
                b.layer?.masksToBounds = true
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: side).isActive = true
                b.heightAnchor.constraint(equalToConstant: side).isActive = true
                row.append(b)
                if row.count == columns { grid.addRow(with: row); row = [] }
            }
            if !row.isEmpty { grid.addRow(with: row + Array(repeating: NSView(), count: columns - row.count)) }
            stack.addArrangedSubview(grid)
        }
    }

    static let swatchColors: [String: NSColor] = [
        "black": .black, "white": .white, "gray": .systemGray, "red": .systemRed, "orange": .systemOrange,
        "yellow": .systemYellow, "green": .systemGreen, "blue": .systemBlue, "purple": .systemPurple,
        "pink": .systemPink, "brown": .systemBrown,
    ]

    private func swatches(_ names: [String]) -> NSView {
        let k = label(Self.colorTitle, size: 11, color: .secondaryLabelColor)
        k.translatesAutoresizingMaskIntoConstraints = false
        k.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let dots = NSStackView()
        dots.spacing = 6
        for name in names {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = (Self.swatchColors[name] ?? .gray).cgColor
            dot.layer?.cornerRadius = 7
            dot.layer?.borderWidth = 0.5
            dot.layer?.borderColor = NSColor.separatorColor.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 14).isActive = true
            dot.toolTip = Self.colorNames[name] ?? name
            dot.setAccessibilityLabel(Self.colorNames[name] ?? name)
            dots.addArrangedSubview(dot)
        }
        let r = NSStackView(views: [k, dots])
        r.spacing = 10
        return r
    }

    /// A section starts with a little air above its name.
    private func section(_ title: String) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(26, after: last) }
        let header = label(title, size: 11, color: .secondaryLabelColor)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)
    }

    private func link(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.isBordered = false
        // One accent for the whole app: what's selected, and where you can go.
        b.contentTintColor = .accent
        b.font = .systemFont(ofSize: 12.5)
        b.lineBreakMode = .byTruncatingTail
        b.alignment = .left
        return b
    }

    /// Stored as keys; shown in Chinese.
    static let sourceNames = ["Browser": String(localized: "瀏覽器"), "Dock": String(localized: "Dock 圖示"), "Screenshot": String(localized: "截圖")]
    static let colorNames = ["black": String(localized: "黑"), "white": String(localized: "白"), "gray": String(localized: "灰"), "grey": String(localized: "灰"), "red": String(localized: "紅"), "orange": String(localized: "橙"),
                             "yellow": String(localized: "黃"), "green": String(localized: "綠"), "blue": String(localized: "藍"), "purple": String(localized: "紫"), "pink": String(localized: "粉紅"), "brown": String(localized: "棕"),
                             "beige": String(localized: "米"), "teal": String(localized: "青"), "cyan": String(localized: "青"), "gold": String(localized: "金"), "silver": String(localized: "銀")]

    static let kindTitle = String(localized: "類型")
    static let sourceTitle = String(localized: "來源")
    static let colorTitle = String(localized: "顏色")
    static let locationTitle = String(localized: "位置")
    static let originalLocationTitle = String(localized: "原始位置")

    static func kindName(_ item: Item) -> String {
        let names: [Item.Kind: String] = [.image: String(localized: "圖片"), .video: String(localized: "影片"), .audio: String(localized: "聲音"), .pdf: "PDF", .web: String(localized: "網頁"), .text: String(localized: "文字"), .file: String(localized: "檔案")]
        return item.thing?.title ?? names[item.kind] ?? ""
    }

    /// The facts worth showing for this kind, in reading order.
    static func facts(_ item: Item, library: Library) -> [(String, String)] {
        var f: [(String, String)] = []
        let kindName: [Item.Kind: String] = [.image: String(localized: "圖片"), .video: String(localized: "影片"), .audio: String(localized: "聲音"), .pdf: "PDF", .web: String(localized: "網頁"), .text: String(localized: "文字"), .file: String(localized: "檔案")]
        f.append((kindTitle, item.thing?.title ?? kindName[item.kind] ?? item.kind.rawValue))
        if let domain = item.domain { f.append((sourceTitle, domain)) }
        if let credits = item.credits, !credits.isEmpty {
            // One line per role, in the order the page gave them.
            var roles: [Item.Credit.Role] = []
            for c in credits where !roles.contains(c.role) { roles.append(c.role) }
            for role in roles {
                // The leads; the rest counted.
                let names = credits.filter { $0.role == role }.map(\.name)
                let shown = names.prefix(4).joined(separator: String(localized: "、"))
                f.append((role.title, names.count > 4 ? String(localized: "\(shown) 等 \(names.count) 位") : shown))
            }
        } else if let creator = item.creator {
            f.append((item.kind == .audio ? String(localized: "演出者") : String(localized: "作者"), creator))
        }
        if let released = item.released { f.append((String(localized: "發行"), Self.released(released))) }
        if item.kind == .image || item.kind == .video { f.append((String(localized: "尺寸"), "\(item.pixelWidth) × \(item.pixelHeight)")) }
        if let d = item.duration { f.append((String(localized: "長度"), Self.duration(d))) }
        if let p = item.pageCount { f.append((String(localized: "頁數"), String(localized: "\(p) 頁"))) }
        if let size = item.fileSize, size > 0 { f.append((String(localized: "大小"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        if !item.originalFilename.isEmpty, item.kind != .web { f.append((String(localized: "檔名"), item.originalFilename)) }
        if let path = item.filePath {
            if item.storedFilename != nil {
                f.append((locationTitle, String(localized: "展室裡有一份複本")))
                f.append((originalLocationTitle, Self.shortPath(path)))
            } else {
                f.append((locationTitle, library.originalURL(item) == nil ? String(localized: "找不到原始檔") : Self.shortPath(path)))
            }
        }
        if item.kind == .web {
            let saved = item.archivedAt.map { Self.date.string(from: $0) }
            f.append((String(localized: "頁面快照"), item.archiveFilename != nil ? String(localized: "\(saved ?? "") 保存") : item.archivedAt == nil ? String(localized: "保存中…") : String(localized: "這個網站不讓保存")))
        }
        f.append((String(localized: "收藏於"), Self.dateTime.string(from: item.dateAdded)))
        if let created = item.createdDate { f.append((String(localized: "建立於"), Self.date.string(from: created))) }
        if let app = item.sourceApp { f.append((String(localized: "從"), Self.sourceNames[app] ?? app)) }
        if item.viewCount > 0 { f.append((String(localized: "看過"), String(localized: "\(item.viewCount) 次"))) }
        if let colors = item.colors, !colors.isEmpty {
            f.append((colorTitle, colors.prefix(3).map { Self.colorNames[$0] ?? $0 }.joined(separator: String(localized: "、"))))
        }
        return f
    }

    private static let dateTime = formatter(chinese: "y 年 M 月 d 日 HH:mm", template: "yMMMd jm")
    private static let date = formatter(chinese: "y 年 M 月 d 日", template: "yMMMd")

    nonisolated private static var showsChinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
    }

    nonisolated private static func formatter(chinese: String, template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        if showsChinese { f.dateFormat = chinese } else { f.setLocalizedDateFormatFromTemplate(template) }
        return f
    }

    /// "2021-10-22" → 2021 年 10 月 22 日; "2021-10" → 2021 年 10 月; "2021" → 2021 年.
    nonisolated static func released(_ s: String) -> String {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard !showsChinese else {
            let units = ["年", "月", "日"]
            return zip(parts, units).map { "\($0) \($1)" }.joined(separator: " ")
        }
        guard let year = parts.first,
              let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1))
        else { return s }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(["y", "yMMM", "yMMMd"][min(parts.count, 3) - 1])
        return f.string(from: day)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Pieces

    private func label(_ s: String, size: CGFloat, color: NSColor = .labelColor, serif: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        var font = NSFont.systemFont(ofSize: size)
        if serif, let f = Typography.display(size) { font = f }  // the display face (sans)
        l.font = font
        l.textColor = color
        l.isSelectable = true
        // Wraps at whatever width the panel gives it.
        l.preferredMaxLayoutWidth = 0
        return l
    }

    /// Word joiners inside each step; the spaces around → stay breakable.
    static func unbreakable(_ s: String) -> String {
        s.components(separatedBy: " → ").map { step in
            step.map(String.init).joined(separator: "\u{2060}")
        }.joined(separator: " → ")
    }

    /// "~/Documents/Wunderkammer 範例/曼德博集合.mp4" → "~/…/曼德博集合.mp4".
    static func shortPath(_ path: String) -> String {
        let p = (path as NSString).abbreviatingWithTildeInPath
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 3 else { return p }
        return "\(parts[0])/…/\(parts.last!)"
    }

    private func row(_ key: String, _ value: String) -> NSView {
        let k = label(key, size: 11, color: .secondaryLabelColor)
        let v = label(value, size: 12, color: .labelColor)
        v.maximumNumberOfLines = 3
        k.translatesAutoresizingMaskIntoConstraints = false
        k.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let r = NSStackView(views: [k, v])
        r.alignment = .firstBaseline
        r.spacing = 10
        return r
    }

    private func button(_ title: String, icon: Reicon, _ action: @escaping @MainActor () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.image = Icon.image(icon, size: 14)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.lineBreakMode = .byTruncatingTail
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.toolTip = title
        return b
    }
}

/// Top-down document view for scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ClosureButton: NSButton {
    private var handler: (@MainActor () -> Void)?

    convenience init(title: String, action: @escaping @MainActor () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(run)
    }

    convenience init(image: NSImage, action: @escaping @MainActor () -> Void) {
        self.init(frame: .zero)
        self.image = image
        title = ""
        handler = action
        target = self
        self.action = #selector(run)
    }

    @objc private func run() { handler?() }
}

/// The inspector's ground: a rounded card a shade off the window, held by a hairline.
@MainActor
private final class InspectorCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.045))
        layer?.borderColor = resolved(NSColor.labelColor.withAlphaComponent(0.1))
    }
}

/// Around the card: the window's own colour, the same as the title bar's strip above.
@MainActor
private final class InspectorColumn: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = resolved(.windowBackgroundColor)
    }
}
