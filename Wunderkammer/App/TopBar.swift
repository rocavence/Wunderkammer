import AppKit

/// The bar across the top of the content, in place of a system toolbar, with
/// room above it: the three spaces in the middle; search (a button that opens
/// into a field) and 資訊 at the right.
@MainActor
final class TopBar: NSView {
    var onSpace: ((Int) -> Void)?
    var onSearchOpen: (() -> Void)?
    var onInfo: (() -> Void)?

    let spaces: NSSegmentedControl
    let searchField = NSSearchField()
    private let searchCapsule = TopBar.capsule()
    private let searchButton = NSButton()
    private var fieldWidth: NSLayoutConstraint!
    private(set) var isSearchOpen = false

    static let height: CGFloat = 36
    /// From the window's top edge to the bar: the breathing room.
    static let top: CGFloat = 16

    init(titles: [String], tips: [String]) {
        spaces = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        spaces.target = self
        spaces.action = #selector(spacePicked)
        spaces.controlSize = .large
        spaces.segmentStyle = .automatic
        spaces.selectedSegmentBezelColor = .controlAccentColor
        for (i, tip) in tips.enumerated() {
            spaces.setToolTip(tip, forSegment: i)
            spaces.setWidth(68, forSegment: i)
        }

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

    /// A round-ended pane of frosted glass, like the view bar at the foot.
    private static func capsule() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = height / 2
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.separatorColor.cgColor
        return v
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for v in subviews { v.layer?.borderColor = resolved(.separatorColor) }
    }

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

    @objc private func spacePicked() { onSpace?(spaces.selectedSegment) }
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
