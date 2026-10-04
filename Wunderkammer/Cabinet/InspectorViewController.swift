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
        stack.edgeInsets = NSEdgeInsets(top: 60, left: 18, bottom: 32, right: 18)
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
        view = scroll
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        show(nil)
    }

    func show(_ id: UUID?) {
        itemID = id
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let id = itemID, let item = library.item(id) else {
            let hint = label("選一件收藏，這裡會顯示系統替它記下的一切。", size: 12, color: .secondaryLabelColor)
            stack.addArrangedSubview(hint)
            return
        }

        if let image = NSImage(contentsOf: library.thumbnailURL(item)) {
            let picture = NSImageView(image: image)
            picture.imageScaling = .scaleProportionallyUpOrDown
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
                picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: min(max(ratio, 0.3), 1.4)),
            ])
            stack.setCustomSpacing(16, after: picture)
        }

        // What it is, where it's from, when: one quiet line under the name.
        let title = label(item.displayTitle, size: 22, serif: true)
        title.maximumNumberOfLines = 4
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(6, after: title)
        let about = [Self.kindName(item), item.domain, item.released.map { String($0.prefix(4)) }, Rediscovery.ageLine(item)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let line = label(about.joined(separator: " · "), size: 12, color: .secondaryLabelColor)
        line.maximumNumberOfLines = 2
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(14, after: line)

        // What you can do with it, right away.
        let actions = NSStackView()
        actions.spacing = 6
        if library.openURL(item) != nil {
            actions.addArrangedSubview(button("打開", icon: .arrowUpRight) { [weak self] in
                guard let self, let url = self.library.openURL(item) else { return }
                self.library.markViewed(item.id)
                NSWorkspace.shared.open(url)
            })
        }
        if let page = library.archiveURL(item) {
            actions.addArrangedSubview(button("看快照", icon: .fileText) { NSWorkspace.shared.open(page) })
        }
        if let file = library.originalURL(item), item.storedFilename == nil {
            actions.addArrangedSubview(button("在 Finder 顯示", icon: .file) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            })
        }
        if item.storedFilename == nil, item.filePath != nil, library.originalURL(item) != nil {
            actions.addArrangedSubview(button("複製到圖庫", icon: .copy) { [weak self] in
                guard let self else { return }
                Task {
                    await self.library.copyIntoLibrary([item.id])
                    self.show(item.id)
                }
            })
        }
        if let url = item.url, actions.arrangedSubviews.count < 3 {
            actions.addArrangedSubview(button("拷貝連結", icon: .link) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        if !actions.arrangedSubviews.isEmpty { stack.addArrangedSubview(actions) }

        if let arrived = arrival?(item) {
            let way = label(arrived, size: 11, color: .tertiaryLabelColor)
            way.maximumNumberOfLines = 3
            stack.addArrangedSubview(way)
        }

        // How it relates to other kinds of things: the same person, a mention, the same city.
        let relations = CrossMedia.relations(of: item, in: library.items).prefix(8)
        if !relations.isEmpty {
            section("關聯")
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
        let facts = Self.facts(item, library: library).filter { $0.0 != "類型" && $0.0 != "來源" }
        if !facts.isEmpty {
            section("資訊")
            for (key, value) in facts { stack.addArrangedSubview(row(key, value)) }
        }

        // Names and the site lead to everything else they appear in.
        var links: [(String, Scope.Base)] = (item.entities ?? []).prefix(8).map { ($0.name, .mentions($0.name)) }
        if let domain = item.domain { links.append((domain, .site(domain))) }
        let connected = links.filter { library.items(for: Scope(base: $0.1)).count > 1 }
        if !connected.isEmpty {
            section("也出現在")
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
            section("圖中的文字")
            let body = label(String(text.prefix(600)), size: 12, color: .secondaryLabelColor)
            body.maximumNumberOfLines = 8
            stack.addArrangedSubview(body)
        }
        if let labels = item.labels, !labels.isEmpty {
            section("系統看到的")
            let tags = label(labels.prefix(8).map(Subjects.title).joined(separator: "  ·  "), size: 12, color: .secondaryLabelColor)
            tags.maximumNumberOfLines = 3
            stack.addArrangedSubview(tags)
        }

        if let related = related?(item), !related.isEmpty {
            section("相關的收藏")
            let columns = 3
            let side: CGFloat = 76
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

    /// A section starts with a little air above its name.
    private func section(_ title: String) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(26, after: last) }
        let header = label(title, size: 11, color: .tertiaryLabelColor)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)
    }

    private func link(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.isBordered = false
        // Links look like links; the accent colour is for selection.
        b.contentTintColor = .linkColor
        b.font = .systemFont(ofSize: 12.5)
        b.lineBreakMode = .byTruncatingTail
        b.alignment = .left
        return b
    }

    /// Stored as keys; shown in Chinese.
    static let sourceNames = ["Browser": "瀏覽器", "Dock": "Dock 圖示", "Screenshot": "截圖"]
    static let colorNames = ["black": "黑", "white": "白", "gray": "灰", "grey": "灰", "red": "紅", "orange": "橙",
                             "yellow": "黃", "green": "綠", "blue": "藍", "purple": "紫", "pink": "粉紅", "brown": "棕",
                             "beige": "米", "teal": "青", "cyan": "青", "gold": "金", "silver": "銀"]

    static func kindName(_ item: Item) -> String {
        let names: [Item.Kind: String] = [.image: "圖片", .video: "影片", .audio: "聲音", .pdf: "PDF", .web: "網頁", .text: "文字", .file: "檔案"]
        return item.thing?.title ?? names[item.kind] ?? ""
    }

    /// The facts worth showing for this kind, in reading order.
    static func facts(_ item: Item, library: Library) -> [(String, String)] {
        var f: [(String, String)] = []
        let kindName: [Item.Kind: String] = [.image: "圖片", .video: "影片", .audio: "聲音", .pdf: "PDF", .web: "網頁", .text: "文字", .file: "檔案"]
        f.append(("類型", item.thing?.title ?? kindName[item.kind] ?? item.kind.rawValue))
        if let domain = item.domain { f.append(("來源", domain)) }
        if let credits = item.credits, !credits.isEmpty {
            // One line per role, in the order the page gave them.
            var roles: [Item.Credit.Role] = []
            for c in credits where !roles.contains(c.role) { roles.append(c.role) }
            for role in roles {
                // The leads; the rest counted.
                let names = credits.filter { $0.role == role }.map(\.name)
                let shown = names.prefix(4).joined(separator: "、")
                f.append((role.title, names.count > 4 ? "\(shown) 等 \(names.count) 位" : shown))
            }
        } else if let creator = item.creator {
            f.append((item.kind == .audio ? "演出者" : "作者", creator))
        }
        if let released = item.released { f.append(("發行", Self.released(released))) }
        if item.kind == .image || item.kind == .video { f.append(("尺寸", "\(item.pixelWidth) × \(item.pixelHeight)")) }
        if let d = item.duration { f.append(("長度", Self.duration(d))) }
        if let p = item.pageCount { f.append(("頁數", "\(p) 頁")) }
        if let size = item.fileSize, size > 0 { f.append(("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        if !item.originalFilename.isEmpty, item.kind != .web { f.append(("檔名", item.originalFilename)) }
        if let path = item.filePath {
            if item.storedFilename != nil {
                f.append(("位置", "圖庫裡有一份複本"))
                f.append(("原始位置", (path as NSString).abbreviatingWithTildeInPath))
            } else {
                f.append(("位置", library.originalURL(item) == nil ? "找不到原始檔" : (path as NSString).abbreviatingWithTildeInPath))
            }
        }
        if item.kind == .web {
            let saved = item.archivedAt.map { Self.date.string(from: $0) }
            f.append(("頁面快照", item.archiveFilename != nil ? "\(saved ?? "") 保存" : item.archivedAt == nil ? "保存中…" : "這個網站不讓保存"))
        }
        f.append(("收藏於", Self.dateTime.string(from: item.dateAdded)))
        if let created = item.createdDate { f.append(("建立於", Self.date.string(from: created))) }
        if let app = item.sourceApp { f.append(("從", Self.sourceNames[app] ?? app)) }
        if item.viewCount > 0 { f.append(("看過", "\(item.viewCount) 次")) }
        if let colors = item.colors, !colors.isEmpty {
            f.append(("顏色", colors.prefix(3).map { Self.colorNames[$0] ?? $0 }.joined(separator: "、")))
        }
        return f
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "y 年 M 月 d 日 HH:mm"
        return f
    }()

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "y 年 M 月 d 日"
        return f
    }()

    /// "2021-10-22" → 2021 年 10 月 22 日; "2021-10" → 2021 年 10 月; "2021" → 2021 年.
    nonisolated static func released(_ s: String) -> String {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        let units = ["年", "月", "日"]
        return zip(parts, units).map { "\($0) \($1)" }.joined(separator: " ")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Pieces

    private func label(_ s: String, size: CGFloat, color: NSColor = .labelColor, serif: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        var font = NSFont.systemFont(ofSize: size)
        if serif, let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
        l.font = font
        l.textColor = color
        l.isSelectable = true
        l.preferredMaxLayoutWidth = 240
        return l
    }

    private func row(_ key: String, _ value: String) -> NSView {
        let k = label(key, size: 11, color: .tertiaryLabelColor)
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
