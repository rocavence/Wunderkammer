import AppKit

/// The bar across the top of the content, in place of a system toolbar, with
/// room above it: the three spaces in the middle; search (a button that opens
/// into a field) and 資訊 at the right.
@MainActor
final class TopBar: NSView {
    var onSpace: ((Int) -> Void)?
    var onSearchOpen: (() -> Void)?
    var onInfo: (() -> Void)?

    let spaces: SpaceSwitch
    let searchField = NSSearchField()
    private let searchCapsule = TopBar.capsule()
    private let searchButton = NSButton()
    private var fieldWidth: NSLayoutConstraint!
    private(set) var isSearchOpen = false

    static let height: CGFloat = 36
    /// From the window's top edge to the bar: the breathing room.
    static let top: CGFloat = 16

    init(titles: [String], tips: [String]) {
        spaces = SpaceSwitch(titles: titles, tips: tips)
        super.init(frame: .zero)
        spaces.onPick = { [weak self] i in self?.onSpace?(i) }

        searchButton.image = Icon.optical(.search, size: 18)
        searchButton.isBordered = false
        searchButton.contentTintColor = .secondaryLabelColor
        searchButton.toolTip = "搜尋或提問（⌘K）"
        searchButton.setAccessibilityLabel("搜尋")
        searchButton.target = self
        searchButton.action = #selector(searchTapped)
        searchField.placeholderString = "搜尋或提問"
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.alphaValue = 0
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil

        let info = TopBar.capsule()
        let infoButton = NSButton(image: Icon.optical(.infoCircle, size: 18), target: self, action: #selector(infoTapped))
        infoButton.isBordered = false
        infoButton.contentTintColor = .secondaryLabelColor
        infoButton.toolTip = "資訊（⌘I）"
        infoButton.setAccessibilityLabel("資訊")

        for v in [searchButton, searchField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            searchCapsule.addSubview(v)
        }
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        info.addSubview(infoButton)
        for v in [spaces, searchCapsule, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        fieldWidth = searchField.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            spaces.centerXAnchor.constraint(equalTo: centerXAnchor),
            spaces.centerYAnchor.constraint(equalTo: centerYAnchor),
            spaces.heightAnchor.constraint(equalToConstant: Self.height),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            info.centerYAnchor.constraint(equalTo: centerYAnchor),
            info.widthAnchor.constraint(equalToConstant: Self.height),
            info.heightAnchor.constraint(equalToConstant: Self.height),
            infoButton.centerXAnchor.constraint(equalTo: info.centerXAnchor),
            infoButton.centerYAnchor.constraint(equalTo: info.centerYAnchor),
            searchCapsule.trailingAnchor.constraint(equalTo: info.leadingAnchor, constant: -10),
            searchCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchCapsule.heightAnchor.constraint(equalToConstant: Self.height),
            searchButton.leadingAnchor.constraint(equalTo: searchCapsule.leadingAnchor),
            searchButton.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: Self.height),
            searchButton.heightAnchor.constraint(equalToConstant: Self.height),
            searchField.leadingAnchor.constraint(equalTo: searchButton.trailingAnchor, constant: -6),
            searchField.trailingAnchor.constraint(equalTo: searchCapsule.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            fieldWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A round-ended piece of glass, like the view bar at the foot.
    private static func capsule() -> Glass { Glass(cornerRadius: height / 2) }

    /// Clicks on the empty parts of the bar fall through to what's below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// The search button grows into a field, or the field folds back.
    func setSearchOpen(_ open: Bool, animated: Bool = true) {
        guard open != isSearchOpen else { return }
        isSearchOpen = open
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.allowsImplicitAnimation = true
            fieldWidth.animator().constant = open ? 200 : 0
            searchField.animator().alphaValue = open ? 1 : 0
            layoutSubtreeIfNeeded()
        }
    }

    @objc private func searchTapped() { onSearchOpen?() }
    @objc private func infoTapped() { onInfo?() }
}

/// A thin strip at the window's left edge: resting the pointer there brings
/// a hidden sidebar out; it can then watch the sidebar to put it back.
@MainActor
final class EdgeReveal: NSView {
    var onReveal: (() -> Void)?
    private var pending: DispatchWorkItem?
    private weak var watched: NSView?
    private var watchArea: NSTrackingArea?
    private var onLeave: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea?.owner === self, event.trackingArea !== watchArea else { return }
        // A moment's rest, so passing by doesn't throw the sidebar out.
        let work = DispatchWorkItem { [weak self] in self?.onReveal?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        if let area = watchArea, event.trackingArea === area {
            watched?.removeTrackingArea(area)
            watchArea = nil
            let leave = onLeave
            onLeave = nil
            leave?()
            return
        }
        pending?.cancel()
    }

    /// Calls `leave` once the pointer has gone out of `view`.
    func watch(_ view: NSView, leave: @escaping () -> Void) {
        if let area = watchArea { watched?.removeTrackingArea(area) }
        let area = NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        view.addTrackingArea(area)
        watched = view
        watchArea = area
        onLeave = leave
    }
}

/// The light glass every floating bar wears: what's behind shows through,
/// softly blurred, held by a hairline. The same over the wall, the grid or
/// the map.
@MainActor
final class Glass: NSView {
    private let blur = NSVisualEffectView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        // Mostly clear: a veil, not a pane.
        blur.alphaValue = 0.45
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = resolved(NSColor.windowBackgroundColor.withAlphaComponent(0.18))
        layer?.borderColor = resolved(NSColor.labelColor.withAlphaComponent(0.14))
    }

    /// Only what's on the glass takes clicks; the glass itself does too, so
    /// a click between buttons doesn't fall into the view behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === blur ? self : hit
    }
}

/// The three spaces on one piece of glass, as tall as the buttons beside it.
/// The one you're in sits on a pill that slides across when you change.
@MainActor
final class SpaceSwitch: NSView {
    var onPick: ((Int) -> Void)?
    private let glass = Glass(cornerRadius: TopBar.height / 2)
    private let pill = CALayer()
    private var labels: [NSButton] = []
    private static let segment: CGFloat = 72
    private static let inset: CGFloat = 3

    var selectedSegment = 0 {
        didSet { if selectedSegment != oldValue { place(animated: window != nil) } }
    }

    init(titles: [String], tips: [String]) {
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.wantsLayer = true
        glass.layer?.addSublayer(pill)
        pill.cornerRadius = (TopBar.height - Self.inset * 2) / 2
        var constraints = [
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.segment * CGFloat(titles.count) + Self.inset * 2),
        ]
        for (i, title) in titles.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(picked(_:)))
            b.isBordered = false
            b.tag = i
            b.toolTip = tips[safe: i]
            b.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(b)
            labels.append(b)
            constraints += [
                b.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Self.inset + CGFloat(i) * Self.segment),
                b.widthAnchor.constraint(equalToConstant: Self.segment),
                b.topAnchor.constraint(equalTo: glass.topAnchor, constant: Self.inset),
                b.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -Self.inset),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityRole(.radioGroup)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        pill.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.16))
        for (i, b) in labels.enumerated() {
            let on = i == selectedSegment
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: on ? .semibold : .medium),
                .foregroundColor: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
        }
    }

    private func place(animated: Bool) {
        let h = TopBar.height - Self.inset * 2
        let frame = CGRect(x: Self.inset + CGFloat(selectedSegment) * Self.segment, y: Self.inset, width: Self.segment, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        pill.frame = frame
        CATransaction.commit()
        updateColors()
    }

    @objc private func picked(_ sender: NSButton) {
        selectedSegment = sender.tag
        onPick?(sender.tag)
    }
}
