import AppKit

/// 足跡: how you went from one curiosity to the next. One row per sitting,
/// newest first; between two pictures, what took you from one to the other.
@MainActor
final class TrailView: NSScrollView {
    var onSelect: ((UUID) -> Void)?

    private let library: Library
    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: String(localized: "還沒有足跡\n打開的每一件收藏，都會依序留在這裡"))

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
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func header(_ visit: [Trail.Step]) -> NSView {
        let count = Set(visit.map(\.item)).count
        let label = NSTextField(labelWithString: String(localized: "\(Self.time.string(from: visit[0].date)) · \(count) 件"))
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
        for (i, step) in visit.enumerated() {
            // Plain browsing is just a step; a search, chance or a relation says so.
            // (A sitting that simply began has nothing before its first picture.)
            if !(i == 0 && step.via == .browse) {
                row.addArrangedSubview(arrow(step.via == .browse ? "" : Trail.short(step.via)))
            }
            if let item = library.item(step.item) { row.addArrangedSubview(node(item)) }
        }
        // Long sittings scroll sideways rather than wrap: it's a path.
        let scroller = NSScrollView()
        scroller.hasHorizontalScroller = true
        scroller.autohidesScrollers = true
        // Shown while scrolling, not standing under every row.
        scroller.scrollerStyle = .overlay
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
        // The row fades at the right edge: there's more if you scroll. Both in a
        // plain container (a scroll view keeps its own subviews in order).
        let container = NSView()
        let fade = EdgeFade()
        fade.towardsRight = true
        for v in [scroller, fade] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: container.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fade.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fade.topAnchor.constraint(equalTo: container.topAnchor),
            fade.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fade.widthAnchor.constraint(equalToConstant: 56),
        ])
        return container
    }

    private func arrow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.isEmpty ? "→" : "\(text) →")
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
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

