import AppKit

/// ⌘I: everything the system knows about the focused curiosity. Read-only:
/// metadata is gathered, never asked for.
@MainActor
final class InspectorViewController: NSViewController {
    private let library: Library
    private let stack = NSStackView()
    private var itemID: UUID?
    var onSelectRelated: ((UUID) -> Void)?
    /// Supplies related items (filled in by the understanding layer).
    var related: ((Item) -> [Item])?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 56, left: 18, bottom: 24, right: 18)
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
            picture.layer?.cornerRadius = 6
            picture.layer?.masksToBounds = true
            picture.translatesAutoresizingMaskIntoConstraints = false
            let ratio = CGFloat(item.pixelHeight) / CGFloat(max(item.pixelWidth, 1))
            stack.addArrangedSubview(picture)
            NSLayoutConstraint.activate([
                picture.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
                picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: min(max(ratio, 0.3), 1.6)),
            ])
        }

        let title = label(item.displayTitle, size: 18, serif: true)
        title.maximumNumberOfLines = 4
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        stack.addArrangedSubview(label(Rediscovery.ageLine(item), size: 11, color: .secondaryLabelColor))

        stack.addArrangedSubview(divider())
        for (key, value) in Self.facts(item, library: library) {
            stack.addArrangedSubview(row(key, value))
        }

        if let text = item.ocrText, !text.isEmpty {
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(label("圖中的文字", size: 11, color: .tertiaryLabelColor))
            let body = label(String(text.prefix(600)), size: 12, color: .secondaryLabelColor)
            body.maximumNumberOfLines = 8
            stack.addArrangedSubview(body)
        }
        if let names = item.entities, !names.isEmpty {
            stack.addArrangedSubview(label("提到的名字", size: 11, color: .tertiaryLabelColor))
            let list = label(names.prefix(8).map(\.name).joined(separator: "  ·  "), size: 12, color: .secondaryLabelColor)
            list.maximumNumberOfLines = 3
            stack.addArrangedSubview(list)
        }
        if let labels = item.labels, !labels.isEmpty {
            stack.addArrangedSubview(label("系統看到的", size: 11, color: .tertiaryLabelColor))
            let tags = label(labels.prefix(8).map(Subjects.title).joined(separator: "  ·  "), size: 12, color: .secondaryLabelColor)
            tags.maximumNumberOfLines = 3
            stack.addArrangedSubview(tags)
        }

        let actions = NSStackView()
        actions.spacing = 8
        if library.openURL(item) != nil {
            actions.addArrangedSubview(button("打開", icon: .arrowUpRight) { [weak self] in
                guard let self, let url = self.library.openURL(item) else { return }
                self.library.markViewed(item.id)
                NSWorkspace.shared.open(url)
            })
        }
        if let file = library.originalURL(item), item.storedFilename == nil {
            actions.addArrangedSubview(button("在 Finder 顯示", icon: .file) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            })
        }
        if let url = item.url {
            actions.addArrangedSubview(button("拷貝連結", icon: .link) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        if !actions.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(actions)
        }

        if let related = related?(item), !related.isEmpty {
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(label("相關的收藏", size: 11, color: .tertiaryLabelColor))
            let grid = NSStackView()
            grid.spacing = 6
            for r in related.prefix(4) {
                guard let image = NSImage(contentsOf: library.thumbnailURL(r)) else { continue }
                let b = ClosureButton(image: image) { [weak self] in self?.onSelectRelated?(r.id) }
                b.imageScaling = .scaleProportionallyUpOrDown
                b.isBordered = false
                b.toolTip = r.displayTitle
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 56).isActive = true
                b.heightAnchor.constraint(equalToConstant: 56).isActive = true
                grid.addArrangedSubview(b)
            }
            stack.addArrangedSubview(grid)
        }
    }

    /// The facts worth showing for this kind, in reading order.
    static func facts(_ item: Item, library: Library) -> [(String, String)] {
        var f: [(String, String)] = []
        let kindName: [Item.Kind: String] = [.image: "圖片", .video: "影片", .audio: "聲音", .pdf: "PDF", .web: "網頁", .text: "文字", .file: "檔案"]
        f.append(("類型", kindName[item.kind] ?? item.kind.rawValue))
        if let domain = item.domain { f.append(("來源", domain)) }
        if let creator = item.creator { f.append((item.kind == .audio ? "演出者" : "作者", creator)) }
        if item.kind == .image || item.kind == .video { f.append(("尺寸", "\(item.pixelWidth) × \(item.pixelHeight)")) }
        if let d = item.duration { f.append(("長度", Self.duration(d))) }
        if let p = item.pageCount { f.append(("頁數", "\(p) 頁")) }
        if let size = item.fileSize, size > 0 { f.append(("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        if !item.originalFilename.isEmpty, item.kind != .web { f.append(("檔名", item.originalFilename)) }
        if let path = item.filePath {
            f.append(("位置", library.originalURL(item) == nil ? "找不到原始檔" : (path as NSString).abbreviatingWithTildeInPath))
        }
        f.append(("收藏於", Self.dateTime.string(from: item.dateAdded)))
        if let created = item.createdDate { f.append(("建立於", Self.date.string(from: created))) }
        if let app = item.sourceApp { f.append(("從", app)) }
        if item.viewCount > 0 { f.append(("看過", "\(item.viewCount) 次")) }
        if let colors = item.colors, !colors.isEmpty { f.append(("顏色", colors.prefix(3).joined(separator: "、"))) }
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
        k.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let r = NSStackView(views: [k, v])
        r.alignment = .firstBaseline
        r.spacing = 8
        return r
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 244).isActive = true
        return box
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
