import AppKit

/// 足跡: how you went from one curiosity to the next. One row per sitting,
/// newest first; between two pictures, what took you from one to the other.
@MainActor
final class TrailView: NSScrollView {
    var onSelect: ((UUID) -> Void)?

    private let library: Library
    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: "還沒有足跡\n打開的每一件收藏，都會依序留在這裡")

    init(library: Library) {
        self.library = library
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 40, right: 24)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 15)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Number of sittings shown (tests).
    private(set) var visitCount = 0

    func show(_ visits: [[Trail.Step]]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        visitCount = visits.count
        guard !visits.isEmpty else {
            stack.addArrangedSubview(empty)
            return
        }
        for visit in visits.prefix(40) {
            stack.addArrangedSubview(header(visit))
            let row = chain(visit)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func header(_ visit: [Trail.Step]) -> NSView {
        let count = Set(visit.map(\.item)).count
        let label = NSTextField(labelWithString: "\(Self.time.string(from: visit[0].date)) · \(count) 件")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Pictures left to right, each preceded by how you got to it.
    private func chain(_ visit: [Trail.Step]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        for step in visit {
            row.addArrangedSubview(arrow(Trail.short(step.via)))
            if let item = library.item(step.item) { row.addArrangedSubview(node(item)) }
        }
        // Long sittings scroll sideways rather than wrap: it's a path.
        let scroller = NSScrollView()
        scroller.hasHorizontalScroller = true
        scroller.autohidesScrollers = true
        scroller.drawsBackground = false
        scroller.verticalScrollElasticity = .none
        row.translatesAutoresizingMaskIntoConstraints = false
        let holder = FlippedView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(row)
        scroller.documentView = holder
        scroller.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            row.topAnchor.constraint(equalTo: holder.topAnchor),
            row.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            holder.heightAnchor.constraint(equalTo: scroller.contentView.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: 132),
        ])
        scroller.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return scroller
    }

    private func arrow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: "\(text) →")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        return label
    }

    private func node(_ item: Item) -> NSView {
        let image = NSImage(contentsOf: library.thumbnailURL(item)) ?? NSImage()
        let height: CGFloat = 96
        let width = min(max(height * item.aspect, 48), 200)
        let button = ClosureButton(image: image) { [weak self] in self?.onSelect?(item.id) }
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.toolTip = item.displayTitle
        button.setAccessibilityLabel(item.displayTitle)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: item.displayTitle)
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        let column = NSStackView(views: [button, title])
        column.orientation = .vertical
        column.spacing = 4
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: height),
            title.widthAnchor.constraint(equalToConstant: width),
        ])
        return column
    }
}

