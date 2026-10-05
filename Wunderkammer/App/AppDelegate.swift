import AppKit
import CoreSpotlight
import Quartz

/// What you came to do: look through the cabinet, wander it, or map it.
/// Each space has one or more layouts (ViewMode) and remembers the last one.
enum Space: Int, CaseIterable {
    case cabinet, wander, map

    var title: String { [String(localized: "收藏"), String(localized: "漫遊"), String(localized: "地圖")][rawValue] }
    var layouts: [ViewMode] {
        switch self {
        case .cabinet: [.grid, .masonry, .timeline]
        case .wander: [.infinity]
        case .map: [.canvas, .graph]
        }
    }
}

enum ViewMode: Int, CaseIterable {
    case grid, masonry, timeline, canvas, infinity, graph

    var title: String { [String(localized: "格狀"), String(localized: "瀑布"), String(localized: "時間軸"), String(localized: "畫布"), String(localized: "無限牆"), String(localized: "圖譜")][rawValue] }
    var icon: Reicon { [.grid, .kanban, .calendar, .layers, .infinite, .nodes][rawValue] }
    var space: Space {
        switch self {
        case .grid, .masonry, .timeline: .cabinet
        case .infinity: .wander
        case .canvas, .graph: .map
        }
    }

    /// The three scrolling views share one cabinet view in different styles.
    var cabinetStyle: CabinetStyle? {
        switch self {
        case .grid: .grid
        case .masonry: .masonry
        case .timeline: .timeline
        default: nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, SelfTestUI {
    private var window: NSWindow!
    /// The 珍奇室 on this Mac; the library is whichever one is open.
    private let cabinets = Cabinets(base: ProcessInfo.processInfo.environment["WK_LIBRARY_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? Library.defaultRoot)
    private lazy var library = Library(root: cabinets.root(of: cabinets.current))
    private lazy var folderWatcher = FolderWatcher(library: library)
    private let thumbnailer = Thumbnailer()
    private(set) var sidebar: SidebarViewController!
    private var inspector: InspectorViewController!
    private var inspectorItem: NSSplitViewItem!
    private var scroll: NSScrollView!
    private(set) var grid: GridView!
    private(set) var canvas: CanvasView!
    private(set) var infinity: InfinityView!
    private(set) var graphView: GraphView!
    private var emptyCabinet: EmptyCabinetView!
    private(set) var preview: PreviewView!
    /// Spaces, search and 資訊, across the top of the content.
    private let topBar = TopBar(titles: Space.allCases.map(\.title),
                                tips: Space.allCases.map { String(localized: "\($0.title)（⌘\($0.rawValue + 1)）") })
    private var sidebarItem: NSSplitViewItem!
    private var splitController: NSSplitViewController!
    /// The layouts of the current space (格狀/瀑布/時間軸, 畫布/圖譜); hidden when there's one.
    /// The layouts and tools of the view in front, at its foot.
    private let viewBar = ViewBar()
    private(set) var mode = ViewMode.grid
    private(set) var scope = Scope()
    private var capture: CaptureController!
    private let answerBanner = AnswerBanner()
    private var trailView: TrailView!
    /// The question the cabinet is showing the answer to, for the trail.
    private var lastQuestion = ""
    /// An Asker on systems that have Apple's on-device model.
    private var askerBox: AnyObject?
    private var askTask: Task<Void, Never>?
    /// The automatic top inset, while the answer banner adds to it.
    private var bannerBaseInset: CGFloat?
    /// wunderkammer:// links that arrived before capture was ready.
    private var pendingLinks: [URL] = []
    /// Another copy of the app already has this library open: hand everything to it.
    private var forwardTo: NSRunningApplication?
    private let quickLook = QuickLookHost()
    private var understanding: Understanding!
    private lazy var trail = Trail(root: library.root)
    /// How the next opened item was reached (set by R, related clicks…).
    private var pendingVia: Trail.Via?
    private var spotlight: SpotlightIndexer?
    private var statusItem: NSStatusItem?
    private let statusDrop = StatusDrop()
    private lazy var settings: SettingsWindowController = {
        let s = SettingsWindowController()
        s.onShortcutsChanged = { [weak self] in
            self?.capture.registerShortcuts()
            self?.buildMenu()
            self?.buildStatusItem()
        }
        s.onRecording = { [weak self] recording in
            if recording { self?.capture.suspendShortcuts() } else { self?.capture.registerShortcuts() }
        }
        s.onSpotlightChanged = { [weak self] on in
            guard let self else { return }
            self.spotlight = on ? SpotlightIndexer(library: self.library) : nil
            if !on { SpotlightIndexer.clear() }
        }
        s.semanticReady = { [weak self] in self?.understanding.semantic != nil }
        s.onEnableChinese = { [weak self] in self?.enableChineseDescriptions() }
        return s
    }()

    @objc private func showSettings() { settings.showWindow(nil) }

    func showSettingsForTest() -> NSWindow? {
        settings.showWindow(nil)
        return settings.window
    }
    /// Recently shown by R, so it doesn't repeat itself.
    private var recentRandom: [UUID] = []

    private static let modeKey = "mode"
    private static let boardKey = "board"

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies writing one library.json lose each other's captures. The
        // self-test has a library of its own and runs next to the real app.
        if ProcessInfo.processInfo.environment["WK_LIBRARY_ROOT"] == nil, let id = Bundle.main.bundleIdentifier {
            forwardTo = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        }
        // A link that launches the app arrives before didFinishLaunching.
        if !SelfTest.isEnabled {
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleLink(_:reply:)),
                                                         forEventClass: AEEventClass(kInternetEventClass),
                                                         andEventID: AEEventID(kAEGetURL))
        }
    }

    @objc private func handleLink(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if forwardTo != nil { forward([url]) } else if let capture { capture.handle(url) } else { pendingLinks.append(url) }
    }

    /// Opens links or files in the copy that's already running.
    private func forward(_ urls: [URL]) {
        guard let other = forwardTo?.bundleURL, !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: other, configuration: NSWorkspace.OpenConfiguration())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = forwardTo {
            // Launch-time links and files are forwarded by now; leave the library alone.
            other.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }
        // Copies and representations of items removed in an earlier session.
        library.purgeOrphans()
        if !SelfTest.isEnabled {
            library.archiveMissing()
            Task { await library.refreshWebData() }
            library.shrinkArchives()
            library.redoWebPictures()
            library.redrawTextCards()
        }
        library.renameColours()
        try? FileManager.default.removeItem(at: Self.textPreviewDir)
        grid = GridView(library: library, thumbnailer: thumbnailer)
        scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Room for the bar above, set by hand: the title bar no longer says how tall it is.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: TopBar.chrome, left: 0, bottom: 0, right: 0)

        canvas = CanvasView(library: library, thumbnailer: thumbnailer)
        infinity = InfinityView(library: library, thumbnailer: thumbnailer)
        preview = PreviewView(library: library, thumbnailer: thumbnailer)
        graphView = GraphView(library: library, thumbnailer: thumbnailer)
        graphView.isHidden = true
        graphView.onOpenView = { [weak self] base in
            self?.setMode(.grid)
            self?.sidebar.select(base)
        }

        for surface in [grid, canvas] as [CabinetSurface] {
            surface.onOpen = { [weak self] id in self?.openPreview(id) }
            surface.onActivate = { [weak self] id in self?.openExternally(id) }
            surface.onRandom = { [weak self] in self?.showRandom() }
            surface.onFocus = { [weak self] id in self?.inspector.show(id) }
            surface.onSimilar = { [weak self] id in self?.sidebar.select(.similar(id)) }
        }
        infinity.onOpen = { [weak self] id in self?.openPreview(id) }
        infinity.onRandom = { [weak self] in self?.showRandom() }
        preview.onClose = { [weak self] in self?.focusCurrent() }
        preview.onActivate = { [weak self] id in self?.openExternally(id) }
        preview.onRandom = { [weak self] in self?.showRandom() }

        // A solid ground under everything, the grid's own colour: the window's
        // background is tinted by the desktop and would show as a band above.
        let content = SolidView()
        emptyCabinet = EmptyCabinetView(frame: .zero)
        emptyCabinet.onImportAtlas = { [weak self] in self?.importAtlas() }
        emptyCabinet.onDrop = { [weak self] pb in
            guard let self else { return false }
            return importPasteboard(pb, library: self.library, board: self.scope.board)
        }
        trailView = TrailView(library: library)
        trailView.isHidden = true
        trailView.onSelect = { [weak self] id in
            guard let self else { return }
            self.sidebar.select(.all)
            self.reveal(id)
        }
        for v in [scroll!, canvas!, infinity!, graphView!, trailView!, emptyCabinet!, preview!] as [NSView] {
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
        }
        answerBanner.isHidden = true
        answerBanner.translatesAutoresizingMaskIntoConstraints = false
        answerBanner.onClose = { [weak self] in self?.closeAnswer() }
        content.addSubview(answerBanner, positioned: .below, relativeTo: preview)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topBar, positioned: .below, relativeTo: preview)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor, constant: TopBar.top),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dropOverlay, positioned: .below, relativeTo: preview)
        NSLayoutConstraint.activate([
            // Below the top bar, over the content only.
            dropOverlay.topAnchor.constraint(equalTo: content.topAnchor, constant: TopBar.chrome),
            dropOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let hover: (Bool) -> Void = { [weak self] on in
            guard let self else { return }
            let board = self.scope.board.flatMap { self.library.collection($0)?.name }
            self.dropOverlay.show(on, into: board ?? self.cabinets.current.name)
        }
        grid.onDropHover = hover
        canvas.onDropHover = hover
        edgeFade.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(edgeFade, positioned: .below, relativeTo: answerBanner)
        NSLayoutConstraint.activate([
            edgeFade.topAnchor.constraint(equalTo: content.topAnchor),
            edgeFade.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            edgeFade.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            edgeFade.heightAnchor.constraint(equalToConstant: 120),
        ])
        topBar.searchField.delegate = self
        topBar.onSpace = { [weak self] i in
            guard let self else { return }
            if self.preview.isOpen { self.preview.dismissImmediately() }
            self.setSpace(Space(rawValue: i) ?? .cabinet)
        }
        topBar.onSearchOpen = { [weak self] in self?.focusSearch() }
        topBar.onInfo = { [weak self] in self?.toggleInspector() }
        topBar.onSidebar = { [weak self] in self?.toggleSidebarFromButton() }
        // The sidebar has no button: ⌘⌃S, or the window's left edge brings it back.
        edgeReveal.onReveal = { [weak self] in self?.revealSidebar() }
        edgeReveal.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(edgeReveal, positioned: .below, relativeTo: preview)
        NSLayoutConstraint.activate([
            edgeReveal.topAnchor.constraint(equalTo: content.topAnchor),
            edgeReveal.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            edgeReveal.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            edgeReveal.widthAnchor.constraint(equalToConstant: 6),
        ])
        viewBar.translatesAutoresizingMaskIntoConstraints = false
        viewBar.onLayout = { [weak self] m in self?.setMode(m) }
        content.addSubview(viewBar, positioned: .below, relativeTo: emptyCabinet)
        NSLayoutConstraint.activate([
            viewBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            viewBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        NSLayoutConstraint.activate([
            answerBanner.topAnchor.constraint(equalTo: content.topAnchor, constant: TopBar.chrome + 8),
            answerBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            answerBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
        let contentVC = NSViewController()
        contentArea = content
        contentVC.view = content

        sidebar = SidebarViewController(library: library)
        sidebar.onSelect = { [weak self] base in self?.show(base: base) }
        sidebar.onRandom = { [weak self] in self?.showRandom() }
        sidebar.onManageCabinets = { [weak self] in self?.manageCabinets() }
        sidebar.cabinetName = cabinets.current.name
        sidebar.cabinetID = cabinets.currentID
        sidebar.coverPicture = cabinets.coverURL(cabinets.currentID)
        watchFolders()
        inspector = InspectorViewController(library: library)
        inspector.onSelectRelated = { [weak self] id in
            guard let self else { return }
            // Following a related item is a step on the trail in itself.
            if let from = self.inspectorItemID { self.trail.record(id, via: .related(from)) }
            self.reveal(id)
        }
        inspector.onFollowRelation = { [weak self] id, label in
            guard let self else { return }
            if let from = self.inspectorItemID { self.trail.record(id, via: .relation(from, label)) }
            self.reveal(id)
        }
        inspector.onOpenView = { [weak self] base in self?.sidebar.select(base) }
        understanding = Understanding(library: library)
        library.similarity = { [weak self] id in self?.understanding.similar(to: id) ?? [] }
        inspector.related = { [weak self] item in self?.understanding.related(to: item) ?? [] }
        library.recentlyViewed = { [weak self] in
            guard let self else { return [] }
            return self.trail.recentItems(existing: Set(self.library.items.map(\.id)))
        }
        inspector.arrival = { [weak self] item in
            guard let self else { return nil }
            // The way here, from where that sitting began: 隨機 → 《A》 → 相似 → 這件.
            let path = self.trail.path(to: item.id, existing: Set(self.library.items.map(\.id)))
            guard let last = path.last else { return nil }
            if path.count == 1 { return Trail.describe(last.via) { self.library.item($0)?.displayTitle } }
            var parts: [String] = []
            for (i, step) in path.enumerated() {
                parts.append(Trail.short(step.via))
                let name = self.library.item(step.item)?.displayTitle ?? ""
                // Shortened inside the 《》, and saying so.
                parts.append(i == path.count - 1 ? String(localized: "這件") : "《\(name.count > 18 ? name.prefix(17) + "…" : name)》")
            }
            return String(localized: "怎麼來的：") + parts.joined(separator: " → ")
        }
        NotificationCenter.default.addObserver(forName: Understanding.didProgress, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }

        let split = NSSplitViewController()
        splitController = split
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // About a fifth of the window: the sidebar holds its own beside the
        // content without crowding it.
        sideItem.minimumThickness = 240
        sideItem.maximumThickness = 320
        sideItem.preferredThicknessFraction = 0.21
        sidebarItem = sideItem
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        // The same as the sidebar: the same default share, the same range.
        inspectorItem.minimumThickness = sideItem.minimumThickness
        inspectorItem.maximumThickness = sideItem.maximumThickness
        inspectorItem.preferredThicknessFraction = sideItem.preferredThicknessFraction
        inspectorItem.isCollapsed = true
        inspectorItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(inspectorItem)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.contentViewController = split
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1280, height: 820))
        // Small enough to sit beside another window, never so small the bar's
        // controls run into each other.
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.titlebarAppearsTransparent = true
        // The cabinet carries its own large title (GridView.heading).
        window.titleVisibility = .hidden
        // No toolbar and nothing in the title bar: it draws no ground of its
        // own, so the bar (in the content) and the cabinet are one colour.
        // The traffic lights keep the title bar's row to themselves.
        window.titlebarSeparatorStyle = .none
        window.setFrameAutosaveName("Main")
        if window.frame.origin == .zero { window.center() }
        // Quick Look looks for its controller up the responder chain.
        quickLook.library = library
        quickLook.sourceFrame = { [weak self] id in self?.screenRect(for: id) }
        window.nextResponder = quickLook
        // The self-test never takes focus from whatever you're doing.
        if SelfTest.isEnabled { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }

        buildMenu()
        AppAppearance.apply(AppAppearance.saved)
        // Following the system: a new accent in System Settings repaints the app too.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if Accent.current == .system { NotificationCenter.default.post(name: Accent.didChange, object: nil) }
            }
        }
        NotificationCenter.default.addObserver(forName: Accent.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accentChanged() }
        }

        let defaults = UserDefaults.standard
        let savedBoard = defaults.string(forKey: Self.boardKey).flatMap(UUID.init(uuidString:))
        setMode(ViewMode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .grid)
        sidebar.select(board: savedBoard)
        if !SelfTest.isEnabled { NSApp.activate() }

        capture = CaptureController(library: library)
        capture.currentBoard = { [weak self] in self?.scope.board }
        // The self-test runs next to the real app; the shortcuts belong to that one.
        if !SelfTest.isEnabled { capture.start() }
        pendingLinks.forEach(capture.handle)
        pendingLinks = []

        understanding.start()
        if !SelfTest.isEnabled {
            if SettingsWindowController.spotlightEnabled { spotlight = SpotlightIndexer(library: library) }
            buildStatusItem()
        }

        if SelfTest.isEnabled {
            if ProcessInfo.processInfo.environment["WK_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            window.setFrameAutosaveName("")
            // On a second screen when there is one, out of the way of your work;
            // above other windows there (covered, the cabinet rightly stops
            // animating). Your real pointer passes through it: only the test's
            // own events reach it, and it never becomes the active app.
            let screen = NSScreen.screens.dropFirst().first ?? NSScreen.screens.first
            let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: min(1280, area.width - 20), height: min(820, area.height - 20))
            window.setFrame(NSRect(x: area.minX + 10, y: area.maxY - size.height - 10, width: size.width, height: size.height), display: true)
            window.level = .floating
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            setMode(.grid)
            sidebar.select(board: nil)
            let test = SelfTest(window: window, library: library, ui: self)
            Task { await test.run() }
        }
    }

    /// Closing the window keeps collecting: ⌘⇧C, the menu bar and sharing
    /// still work. The Dock icon or the menu bar brings the cabinet back.
    static let textPreviewDir = FileManager.default.temporaryDirectory.appendingPathComponent("wunderkammer-text", isDirectory: true)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { SelfTest.isEnabled }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if forwardTo != nil { return false }
        if !hasVisibleWindows { showCabinet() }
        return true
    }

    @objc func showCabinet() {
        window.makeKeyAndOrderFront(nil)
        if !SelfTest.isEnabled { NSApp.activate() }
    }

    /// Shows the user's shortcut next to a menu item (the global hotkey does the work).
    static func show(_ shortcut: GlobalHotkeys.Shortcut, on item: NSMenuItem) {
        let key = GlobalHotkeys.Shortcut.keyName(shortcut.keyCode).lowercased()
        // Only a printable letter, digit or symbol can be a menu key equivalent.
        guard key.count == 1, key != "?", key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) })
        else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    private func buildStatusItem() {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = String(localized: "Wunderkammer：把東西拖到這裡就收進珍奇室")
        if let button = item.button { statusDrop.attach(to: button) }
        statusDrop.onDrop = { [weak self] pasteboard in self?.capture.collectDrop(pasteboard) ?? false }
        let menu = NSMenu()
        Self.show(CaptureController.captureShortcut, on: menu.addItem(withTitle: String(localized: "收藏剪貼簿或目前頁面"), action: #selector(captureNow), keyEquivalent: ""))
        Self.show(CaptureController.screenshotShortcut, on: menu.addItem(withTitle: String(localized: "截圖收藏"), action: #selector(captureScreenshot), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "隨機一件"), action: #selector(randomFromStatus), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "打開珍奇室"), action: #selector(showCabinet), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "結束 Wunderkammer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func randomFromStatus() {
        showCabinet()
        showRandom()
    }

    /// Files dropped on the Dock icon, or opened with Wunderkammer.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if forwardTo != nil { return forward(files) }
        let board = scope.board
        Task { await library.capture(files.map { .file($0) }, into: board, sourceApp: "Dock") }
    }

    /// A Spotlight result was opened: show that curiosity.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let s = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = UUID(uuidString: s), library.item(id) != nil else { return false }
        window.makeKeyAndOrderFront(nil)
        if mode == .infinity || mode == .graph { setMode(.grid) }
        reveal(id)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A forwarding copy never owned the library: saving would overwrite the real one.
        guard forwardTo == nil else { return }
        try? FileManager.default.removeItem(at: Self.textPreviewDir)
        library.save()
        trail.save()
    }

    // MARK: State

    private var tipIndex = Int.random(in: 0..<GridView.tips.count)

    private func show(base: Scope.Base) {
        // A different suggestion each time the view changes.
        tipIndex = (tipIndex + 1) % GridView.tips.count
        grid?.tip = GridView.tips[tipIndex]
        // 足跡 lives in 漫遊.
        if base == .trail, mode.space != .wander { setSpace(.wander) }
        if case .answer = base {} else if !answerBanner.isHidden { hideAnswerBanner() }
        scope = Scope(base: base, search: "")
        topBar.searchField.stringValue = ""
        if !SelfTest.isEnabled { UserDefaults.standard.set(scope.board?.uuidString, forKey: Self.boardKey) }
        updateTitle()
        grid.show(scope: scope)
        canvas.show(scope: scope)
        infinity.show(scope: scope)
        inspector.show(nil)
        updateTrailView()
        focusCurrent()
    }

    private func updateTitle() {
        switch scope.base {
        case .all: window.title = cabinets.current.name
        case .board(let id): window.title = library.collection(id)?.name ?? String(localized: "釘選版")
        case .kind(let k): window.title = k.title
        case .onThisDay: window.title = String(localized: "過去的今天")
        case .forgotten: window.title = String(localized: "被遺忘的")
        case .similar(let id): window.title = String(localized: "與「\(String(library.item(id)?.displayTitle.prefix(20) ?? ""))」相似")
        case .subject(let label): window.title = Subjects.title(label)
        case .color(let name): window.title = Colours.title(name)
        case .mentions(let name): window.title = String(localized: "提到「\(name)」")
        case .site(let domain): window.title = domain
        case .trail: window.title = String(localized: "足跡")
        case .answer: window.title = String(localized: "回答")
        }
        let count = library.items(for: scope).count
        let learning = understanding?.pending ?? 0
        window.subtitle = (scope.isSearching ? String(localized: "找到 \(count) 件") : String(localized: "\(count) 件")) + (learning > 0 ? String(localized: " · 正在理解 \(learning) 件") : "")
        // The cabinet says it large; the titlebar stays quiet.
        let today = library.items(for: scope).filter { Calendar.current.isDateInToday($0.dateAdded) }.count
        var detail = [scope.isSearching ? String(localized: "找到 \(count) 件") : String(localized: "\(count) 件")]
        if !scope.isSearching, today > 0, today < count { detail.append(String(localized: "今天新增 \(today) 件")) }
        if learning > 0 { detail.append(String(localized: "正在理解 \(learning) 件")) }
        // Where this view sits (格式, 分類, 主題…) leads the line under the title, its icon beside it.
        let kicker = scope.isSearching ? (String(localized: "搜尋"), Reicon.search) : SidebarViewController.kicker(for: scope.base)
        grid?.heading = GridView.Heading(title: scope.isSearching ? String(localized: "「\(scope.search)」") : window.title,
                                         detail: ([kicker?.0].compactMap { $0 } + detail).joined(separator: " · "),
                                         icon: kicker?.1)
        // Tips need something to try them on: none for the first few pieces.
        grid?.tip = scope.isSearching || library.items.count < 5 ? "" : GridView.tips[tipIndex]
        infinity?.heading = window.title
        // A cabinet with nothing in it yet gets its welcome instead of empty views.
        emptyCabinet?.isHidden = !library.items.isEmpty
        emptyCabinet?.name = cabinets.current.name
        updateViewBar()
    }

    func setMode(_ new: ViewMode) {
        // A preview belongs to the view it flew out of.
        if new != mode, preview.isOpen { preview.dismissImmediately() }
        mode = new
        if !SelfTest.isEnabled { UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey) }
        lastLayout[new.space] = new
        if !SelfTest.isEnabled { UserDefaults.standard.set(new.rawValue, forKey: "mode.\(new.space.rawValue)") }
        updateSpaceControls()
        sidebar.space = new.space
        scroll.isHidden = new.cabinetStyle == nil
        if let style = new.cabinetStyle {
            if grid.style == style { grid.reload(animated: false) } else { grid.style = style }
        }
        canvas.isHidden = new != .canvas
        infinity.isHidden = new != .infinity
        graphView.isHidden = new != .graph
        // The wall draws this shade itself.
        edgeFade.isHidden = new == .infinity
        updateTrailView()
        focusCurrent()
    }

    /// 足跡 in the scrolling views is the path itself, not a grid of what was seen.
    private func updateTrailView() {
        let showing = scope.base == .trail && (mode.cabinetStyle != nil || mode == .infinity) && !scope.isSearching
        trailView.isHidden = !showing
        if mode.cabinetStyle != nil { scroll.isHidden = showing }
        if mode == .infinity { infinity.isHidden = showing }
        if showing { trailView.show(trail.visits(existing: Set(library.items.map(\.id)))) }
        updateViewBar()
    }

    /// The layout each space was last in (this session, else the saved one).
    private var lastLayout: [Space: ViewMode] = [:]

    func setSpace(_ space: Space) {
        guard space != mode.space else { return }
        let saved = SelfTest.isEnabled ? nil
            : (UserDefaults.standard.object(forKey: "mode.\(space.rawValue)") as? Int).flatMap(ViewMode.init(rawValue:))
        let remembered = lastLayout[space] ?? saved
        setMode(remembered.flatMap { space.layouts.contains($0) ? $0 : nil } ?? space.layouts[0])
    }

    private func updateSpaceControls() {
        topBar.spaces.selectedSegment = mode.space.rawValue
        updateViewBar()
    }

    /// The bar at the foot: this space's layouts, then the view's own tools.
    /// Away while there's nothing to arrange (足跡, an empty cabinet).
    private func updateViewBar() {
        let zoom: [ViewBar.Tool] = [
            .init(icon: .searchZoomOut, tip: String(localized: "縮小（⌘-）")) { [weak self] in self?.zoomOut() },
            .init(icon: .searchZoomIn, tip: String(localized: "放大（⌘=）")) { [weak self] in self?.zoomIn() },
        ]
        var tools: [[ViewBar.Tool]]
        switch mode {
        case .canvas:
            tools = [
                [.init(icon: .sparkles, tip: String(localized: "依主題分堆")) { [weak self] in self?.canvas.clusterByTheme(nil) },
                 .init(icon: .link, tip: String(localized: "依關聯分堆"), enabled: canvas.hasRelations) { [weak self] in self?.canvas.clusterByRelation(nil) },
                 .init(icon: .grid2, tip: String(localized: "整理成整齊的排列")) { [weak self] in self?.canvas.arrange(nil) }],
                [.init(icon: .maximize, tip: String(localized: "顯示全部")) { [weak self] in self?.canvas.fit(animated: true) }] + zoom,
                [.init(icon: .restart, tip: String(localized: "重設擺放…"), destructive: true) { [weak self] in self?.canvas.resetArrangement(nil) }],
            ]
        case .graph:
            tools = [[.init(icon: .maximize, tip: String(localized: "顯示全部")) { [weak self] in self?.graphView.showAll() }] + zoom]
        default:
            tools = [zoom]
        }
        viewBar.show(layouts: mode.space.layouts, current: mode, tools: tools)
        let trail = trailView.map { !$0.isHidden } ?? false
        let empty = emptyCabinet.map { !$0.isHidden } ?? false
        if trail || empty { viewBar.isHidden = true }
    }

    private var currentView: NSView {
        switch mode {
        case .canvas: canvas
        case .infinity: infinity
        case .graph: graphView
        default: grid
        }
    }

    private var currentSurface: ItemSurface {
        switch mode {
        case .canvas: canvas
        case .infinity: infinity
        default: grid
        }
    }

    private func focusCurrent() {
        window.makeFirstResponder(currentView)
    }

    // MARK: Looking at things

    /// Space: pictures, pages and text fly out in our own preview; media and
    /// documents open in Quick Look, which can play and page through them.
    private func openPreview(_ id: UUID, caption: String? = nil) {
        // However this ends, the "how you got here" hint is for this visit only.
        defer { pendingVia = nil }
        guard let item = library.item(id) else { return }
        grid.stopHover()
        library.markViewed(id)
        trail.record(id, via: pendingVia ?? currentVia)
        inspector.show(id)
        if [.video, .audio, .pdf, .file].contains(item.kind), let url = library.originalURL(item) {
            quickLook.show(url, for: id)
            return
        }
        // Long text doesn't fit a card: read all of it in Quick Look.
        if item.kind == .text, let text = item.text, text.count > 280 {
            // Named by ID: the text is untrusted and may contain "/" or "..".
            let dir = Self.textPreviewDir
            // Only the text being read now; earlier ones go.
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(item.id.uuidString).txt")
            if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil {
                quickLook.show(file, for: id)
                return
            }
        }
        let hint: String? = switch item.kind {
        case .web: [item.domain, String(localized: "按 Return 在瀏覽器打開")].compactMap { $0 }.joined(separator: " · ")
        case .text where item.url != nil: [item.domain, String(localized: "按 Return 打開來源")].compactMap { $0 }.joined(separator: " · ")
        default: nil
        }
        preview.open(id, from: currentSurface, caption: caption ?? hint)
    }

    /// How the cabinet is being browsed right now, for the trail.
    private var currentVia: Trail.Via {
        if scope.isSearching { return .search(scope.search) }
        switch scope.base {
        case .similar(let id): return .similar(id)
        case .mentions(let n): return .mentions(n)
        case .site(let d): return .site(d)
        case .subject(let l): return .theme(Subjects.title(l))
        case .answer: return .ask(lastQuestion)
        default: return .browse
        }
    }

    /// Enter: the page in the browser, the file in its app.
    private func openExternally(_ id: UUID) {
        guard let item = library.item(id), let url = library.openURL(item) else { NSSound.beep(); return }
        library.markViewed(id)
        NSWorkspace.shared.open(url)
    }

    /// R: something from the past, with how long ago it was kept.
    /// The curiosity picked, if any.
    @discardableResult
    func showRandom() -> Item? {
        if preview.isOpen { preview.dismissImmediately() }
        let pool = library.items(for: Scope(base: scope.base))
        guard let pick = Rediscovery.pick(pool, avoiding: recentRandom) ?? Rediscovery.pick(library.items, avoiding: recentRandom)
        else { NSSound.beep(); return nil }
        recentRandom = Array(([pick.id] + recentRandom).prefix(20))
        if !pool.contains(where: { $0.id == pick.id }) { sidebar.select(.all) }
        // The wall can show it; the graph can't.
        if mode == .graph { setMode(.grid) }
        if scope.isSearching { clearSearch() }
        currentSurface.reveal(pick.id)
        let caption = Rediscovery.ageLine(pick) + String(localized: " · R 再抽一件 · Esc 關閉")
        pendingVia = .random
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.openPreview(pick.id, caption: caption) }
        }
        return pick
    }

    /// The item the inspector is showing (for "came from related").
    private var inspectorItemID: UUID? { inspector.currentID }

    private func reveal(_ id: UUID) {
        if !library.items(for: scope).contains(where: { $0.id == id }) { sidebar.select(.all) }
        currentSurface.reveal(id)
        inspector.show(id)
    }

    private func screenRect(for id: UUID) -> NSRect? {
        currentSurface.rectInWindow(for: id).map { window.convertToScreen($0) }
    }

    // MARK: Search (⌘K)

    @objc private func focusSearch() {
        setSearchExpanded(true)
        window.makeFirstResponder(topBar.searchField)
    }

    /// Search waits as a button; it opens into a field when wanted (click,
    /// ⌘K, Siri) and folds away again once it's empty and left.
    private func setSearchExpanded(_ open: Bool) {
        topBar.setSearchOpen(open)
    }

    var isSearchExpanded: Bool { topBar.isSearchOpen }

    /// Leaving an empty search folds it back into its button.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === topBar.searchField, field.stringValue.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.setSearchExpanded(false) } }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === topBar.searchField else { return }
        search(field.stringValue)
    }

    func search(_ text: String) {
        scope.search = text
        scope.semantic = []
        // Results are a list to scan: shown in the scrolling views.
        if scope.isSearching, mode.cabinetStyle == nil { setMode(.grid) }
        grid.show(scope: scope)
        updateTrailView()
        updateTitle()
        searchByMeaning(text)
    }

    private let translator = QueryTranslator()
    private var meaningTask: Task<Void, Never>?

    /// After the words, look for what the description means. Debounced; a
    /// newer query cancels an older one.
    private func searchByMeaning(_ text: String) {
        meaningTask?.cancel()
        guard scope.isSearching, let semantic = understanding.semantic else { return }
        meaningTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.translator.refresh()
            guard let english = await self.translator.english(text), !Task.isCancelled else { return }
            let vector = await Task.detached { semantic.embed(text: english) }.value
            guard let vector, !Task.isCancelled, self.scope.search == text else { return }
            let pool = self.library.items(for: Scope(base: self.scope.base))
            let hits = self.understanding.semanticMatches(vector, in: pool)
            guard !hits.isEmpty else { return }
            self.scope.semantic = hits
            self.grid.show(scope: self.scope)
            self.updateTitle()
        }
    }

    /// Lets the system offer the Chinese → English language pack.
    @objc private func enableChineseDescriptions() {
        TranslationSetup.present(over: window) { [weak self] in
            Task { await self?.translator.refresh() }
        }
    }

    private func clearSearch() {
        topBar.searchField.stringValue = ""
        search("")
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty {
            clearSearch()
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.setSearchExpanded(false) } }
        }
        focusCurrent()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // A question and Return: ask the cabinet instead of searching it.
        if selector == #selector(NSResponder.insertNewline(_:)), canAsk, Self.isQuestion(control.stringValue) {
            ask(control.stringValue)
            return true
        }
        // From the search field, ↓ or Return moves into the results.
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            focusCurrent()
            grid.focusFirst()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            clearSearch()
            focusCurrent()
            return true
        }
        return false
    }

    // MARK: Siri and Shortcuts (Intents.swift)

    /// Spoken back in the language of the question.
    func answerForIntent(_ question: String) async -> String {
        let chinese = QueryTranslator.needsTranslation(question)
        guard #available(macOS 26.0, *), Asker.isAvailable else {
            return chinese ? "這台 Mac 的 Apple Intelligence 還不能用。" : "Apple Intelligence isn't available on this Mac."
        }
        do {
            return try await asker.ask(question, within: 30).text
        } catch Asker.Failure.refused {
            return chinese ? "這個問題 Apple Intelligence 不回答，換個問法試試。" : "Apple Intelligence won't answer that one. Try asking another way."
        } catch {
            return chinese ? "沒有得到回答，換個說法再問一次試試。" : "I couldn't get an answer. Try asking another way."
        }
    }

    func searchForIntent(_ query: String) -> Int {
        showCabinet()
        if mode.cabinetStyle == nil { setMode(.grid) }
        setSearchExpanded(true)
        topBar.searchField.stringValue = query
        search(query)
        return library.items(for: scope).count
    }

    func randomForIntent() -> String? {
        showCabinet()
        return showRandom()?.displayTitle
    }

    func collectForIntent() async -> Bool { await capture.captureNow() }

    // MARK: Asking (US-211)

    var isAsking: Bool { askTask != nil }

    // Self-test hooks for the trail: the same paths the UI takes.
    func openForTest(_ id: UUID) { openPreview(id) }
    func followRelationForTest(to id: UUID, label: String) { inspector.onFollowRelation?(id, label) }
    var trailVisitCount: Int { trailView.isHidden ? -1 : trailView.visitCount }
    func arrivalLine(for id: UUID) -> String? { library.item(id).flatMap { inspector.arrival?($0) } }
    var answerText: String {
        if #available(macOS 26.0, *), let plan = (askerBox as? Asker)?.lastPlan { return answerBanner.answerText + " ⟨\(plan)⟩" }
        return answerBanner.answerText
    }

    private var canAsk: Bool {
        if #available(macOS 26.0, *) { return Asker.isAvailable }
        return false
    }

    /// Ends in a question mark, or reads like a question.
    nonisolated static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count >= 4 else { return false }
        if t.hasSuffix("?") || t.hasSuffix("？") { return true }
        if ["什麼", "哪", "誰", "幾", "嗎", "呢", "有沒有", "多少", "為什麼", "怎麼", "是否"].contains(where: t.contains) { return true }
        return ["what ", "which ", "who ", "when ", "why ", "how ", "where ", "did i ", "do i ", "have i "].contains { t.hasPrefix($0) }
    }

    @available(macOS 26.0, *)
    private var asker: Asker {
        if let a = askerBox as? Asker { return a }
        let a = Asker(library: library) { [weak self] english, pool in await self?.looksLike(english, in: pool) ?? [] }
        askerBox = a
        return a
    }

    func ask(_ question: String) {
        guard #available(macOS 26.0, *) else { return }
        let asker = asker
        askTask?.cancel()
        lastQuestion = question
        answerBanner.thinking(about: question)
        showAnswerBanner()
        askTask = Task { [weak self] in
            let text: String, ids: [UUID]?
            do {
                let answer = try await asker.ask(question, within: 30)
                (text, ids) = (answer.text, answer.items.map(\.id))
            } catch Asker.Failure.refused {
                (text, ids) = (String(localized: "這個問題 Apple Intelligence 不回答，換個問法試試。"), nil)
            } catch Asker.Failure.tooSlow {
                (text, ids) = (String(localized: "想太久了，沒有得到回答。換個說法再問一次試試。"), nil)
            } catch {
                (text, ids) = (String(localized: "沒辦法回答：\(error.localizedDescription)"), nil)
            }
            guard let self, !Task.isCancelled else { return }
            self.askTask = nil
            if let ids {
                self.topBar.searchField.stringValue = ""
                self.setSearchExpanded(false)
                if self.mode.cabinetStyle == nil { self.setMode(.grid) }
                self.show(base: .answer(ids))
            }
            self.answerBanner.show(answer: text, failed: ids == nil)
            self.updateBannerInset()
        }
    }

    /// What looks like an English description (MobileCLIP), if installed.
    private func looksLike(_ english: String, in pool: [Item]) async -> [UUID] {
        guard let semantic = understanding.semantic else { return [] }
        let vector = await Task.detached { semantic.embed(text: english) }.value
        return vector.map { understanding.semanticMatches($0, in: pool) } ?? []
    }

    private func showAnswerBanner() {
        answerBanner.isHidden = false
        updateBannerInset()
    }

    private func hideAnswerBanner() {
        askTask?.cancel()
        answerBanner.isHidden = true
        updateBannerInset()
    }

    private func closeAnswer() {
        hideAnswerBanner()
        if case .answer = scope.base { sidebar.select(.all) }
        focusCurrent()
    }

    /// The cabinet starts below the banner while it's up.
    private func updateBannerInset() {
        if answerBanner.isHidden {
            if bannerBaseInset != nil {
                bannerBaseInset = nil
                scroll.automaticallyAdjustsContentInsets = true
            }
            return
        }
        answerBanner.superview?.layoutSubtreeIfNeeded()
        let base = bannerBaseInset ?? scroll.contentView.contentInsets.top
        bannerBaseInset = base
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: base + answerBanner.frame.height + 16, left: 0, bottom: 0, right: 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentView.contentInsets.top))
    }

    // MARK: Inspector (⌘I)

    @objc private func toggleInspector() {
        // At once, not slid: sliding reflowed the whole cabinet beside it on
        // every frame. The pieces then spring to their new places in one go.
        grid.animateNextWidthChange = mode.cabinetStyle != nil
        let opening = inspectorItem.isCollapsed
        inspectorItem.isCollapsed.toggle()
        if opening, !sidebarItem.isCollapsed {
            // Opens as wide as the sidebar: held at that width while it lays
            // out, then free again to be dragged within the sidebar's range.
            let width = sidebar.view.frame.width
            let (low, high) = (inspectorItem.minimumThickness, inspectorItem.maximumThickness)
            inspectorItem.minimumThickness = width
            inspectorItem.maximumThickness = width
            window.layoutIfNeeded()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inspectorItem.minimumThickness = low
                    self.inspectorItem.maximumThickness = high
                    // Loosened, the split would go back to its own idea of the
                    // width; put the divider where the sidebar's width says.
                    if let split = self.splitController?.splitView, split.arrangedSubviews.count == 3 {
                        split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
                    }
                }
            }
        }
    }

    func toggleInspectorForTest() { toggleInspector() }
    func inspectForTest(_ id: UUID) { inspector.show(id) }
    var inspectorViewForTest: NSView? { inspector.view.superview }

    // MARK: Accent

    /// A new accent: every view that resolves its colours does so again.
    private func accentChanged() {
        func refresh(_ view: NSView) {
            view.viewDidChangeEffectiveAppearance()
            view.needsDisplay = true
            view.subviews.forEach(refresh)
        }
        for window in NSApp.windows {
            // From the frame view down, so the title bar's strip (the top bar) is included.
            if let frame = window.contentView?.superview { refresh(frame) } else if let content = window.contentView { refresh(content) }
        }
        grid.reload(animated: false)
        updateViewBar()
    }

    // MARK: Window chrome

    /// The middle of the window: what the bar spans.
    private var contentArea: NSView?

    @objc private func toggleSidebarFromButton() {
        sidebarPeeking = false
        splitController.toggleSidebar(nil)
    }

    private let edgeReveal = EdgeReveal()
    /// The top shade the wall has, behind the bar in the other views too.
    private let edgeFade = EdgeFade()
    private let dropOverlay = DropOverlay()
    /// The sidebar came out because the pointer reached the edge: it goes
    /// back once the pointer leaves it.
    private var sidebarPeeking = false

    private func revealSidebar() {
        guard sidebarItem.isCollapsed else { return }
        sidebarPeeking = true
        sidebarItem.animator().isCollapsed = false
        edgeReveal.watch(sidebar.view) { [weak self] in
            guard let self, self.sidebarPeeking else { return }
            self.sidebarPeeking = false
            self.sidebarItem.animator().isCollapsed = true
        }
    }

    @objc private func spaceChanged(_ sender: NSSegmentedControl) {
        if preview.isOpen { preview.dismissImmediately() }
        setSpace(Space(rawValue: sender.selectedSegment) ?? .cabinet)
    }


    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "關於 Wunderkammer"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "設定…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "服務"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "隱藏 Wunderkammer"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "結束 Wunderkammer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "檔案"))
        let captureItem = fileMenu.addItem(withTitle: String(localized: "收藏剪貼簿或目前頁面"), action: #selector(captureNow), keyEquivalent: "")
        captureItem.target = self
        Self.show(CaptureController.captureShortcut, on: captureItem)
        let shot = fileMenu.addItem(withTitle: String(localized: "截圖收藏"), action: #selector(captureScreenshot), keyEquivalent: "")
        shot.target = self
        Self.show(CaptureController.screenshotShortcut, on: shot)
        fileMenu.addItem(withTitle: String(localized: "加入檔案…"), action: #selector(importFiles), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: String(localized: "從 Atlas 匯入"), action: #selector(importAtlas), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "新增釘選版"), action: #selector(newBoard), keyEquivalent: "n").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "在 Finder 顯示珍奇室的資料"), action: #selector(revealLibrary), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: String(localized: "關閉視窗"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "編輯"))
        editMenu.addItem(withTitle: String(localized: "還原"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "剪下"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "拷貝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "貼上"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "全選"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let remove = editMenu.addItem(withTitle: String(localized: "移除"), action: #selector(GridView.delete(_:)), keyEquivalent: "\u{8}")
        remove.keyEquivalentModifierMask = [.command]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "搜尋"), action: #selector(focusSearch), keyEquivalent: "k").target = self
        editMenu.addItem(withTitle: String(localized: "啟用中文描述搜尋…"), action: #selector(enableChineseDescriptions), keyEquivalent: "").target = self
        editMenu.addItem(withTitle: String(localized: "搜尋"), action: #selector(focusSearch), keyEquivalent: "f").target = self
        editMenu.items.last?.isAlternate = false
        editMenu.items.last?.isHidden = true
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "顯示方式"))
        // ⌘1–3 the spaces; ⌥⌘ and a number the layouts within them.
        for s in Space.allCases {
            let item = viewMenu.addItem(withTitle: s.title, action: #selector(spaceFromMenu(_:)), keyEquivalent: "\(s.rawValue + 1)")
            item.tag = s.rawValue
            item.target = self
        }
        viewMenu.addItem(.separator())
        for (i, m) in [ViewMode.grid, .masonry, .timeline, .canvas, .graph].enumerated() {
            let item = viewMenu.addItem(withTitle: String(localized: "\(m.space.title)：\(m.title)"), action: #selector(modeFromMenu(_:)), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = m.rawValue
            item.target = self
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "放大"), action: #selector(zoomIn), keyEquivalent: "=").target = self
        viewMenu.addItem(withTitle: String(localized: "縮小"), action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: String(localized: "整理畫布"), action: #selector(CanvasView.arrange(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: String(localized: "畫布依主題分堆"), action: #selector(CanvasView.clusterByTheme(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: String(localized: "重設地圖擺放…"), action: #selector(CanvasView.resetArrangement(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "隨機一件"), action: #selector(randomFromMenu), keyEquivalent: "r").keyEquivalentModifierMask = [.command, .option]
        viewMenu.items.last?.target = self
        viewMenu.addItem(withTitle: String(localized: "資訊"), action: #selector(toggleInspector), keyEquivalent: "i").target = self
        viewMenu.addItem(withTitle: String(localized: "顯示或隱藏側欄"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: String(localized: "進入全螢幕"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "視窗"))
        windowMenu.addItem(withTitle: String(localized: "縮到最小"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "珍奇室"), action: #selector(showCabinet), keyEquivalent: "0").target = self
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func spaceFromMenu(_ sender: NSMenuItem) {
        if preview.isOpen { return }
        setSpace(Space(rawValue: sender.tag) ?? .cabinet)
    }

    @objc private func modeFromMenu(_ sender: NSMenuItem) {
        if preview.isOpen { return }
        setMode(ViewMode(rawValue: sender.tag) ?? .grid)
    }

    @objc private func randomFromMenu() { showRandom() }
    @objc private func captureNow() { Task { await capture.captureNow() } }
    @objc private func captureScreenshot() { Task { await capture.captureScreenshot() } }
    @objc private func newBoard() { sidebar.newBoard(nil) }

    // MARK: Cabinets (珍奇室)

    private var cabinetsPanel: CabinetsPanel?

    /// The window for switching, adding, renaming and removing 珍奇室 (a sheet).
    func manageCabinets() {
        let panel = CabinetsPanel(cabinets: cabinets, count: { [weak self] entry in self?.itemCount(of: entry) ?? 0 },
                                  covers: { [weak self] entry in self?.coverURLs(of: entry) ?? [] },
                                  referenced: { [weak self] entry in self?.referencedCount(of: entry) ?? 0 })
        panel.onSwitch = { [weak self] id in self?.switchCabinet(to: id) }
        panel.onChange = { [weak self] in self?.cabinetsChanged() }
        cabinetsPanel = panel
        panel.present(on: window)
    }

    /// How many things a 珍奇室 holds (the open one from memory, others from disk).
    /// Collected files that still live where they were found.
    private func referencedCount(of entry: Cabinets.Entry) -> Int {
        guard entry.id == cabinets.currentID else { return Library.storedReferencedCount(at: cabinets.root(of: entry)) }
        return library.items.filter { $0.filePath != nil && $0.storedFilename == nil }.count
    }

    private func itemCount(of entry: Cabinets.Entry) -> Int {
        if entry.id == cabinets.currentID { return library.items.count }
        return Library.storedCount(at: cabinets.root(of: entry))
    }

    /// The newest few pictures of a cabinet, for its card.
    private func coverURLs(of entry: Cabinets.Entry) -> [URL] {
        guard entry.id == cabinets.currentID else { return Library.storedCovers(at: cabinets.root(of: entry)) }
        return library.items.sorted { $0.dateAdded > $1.dateAdded }.prefix(4).map(library.thumbnailURL)
    }

    /// Opens another cabinet in place: the same window, its own things.
    func switchCabinet(to id: UUID) {
        guard id != cabinets.currentID, let entry = cabinets.entries.first(where: { $0.id == id }) else { return }
        if preview.isOpen { preview.dismissImmediately() }
        hideAnswerBanner()
        trail.save()
        cabinets.select(id)
        library.open(root: cabinets.root(of: entry))
        library.renameColours()
        trail = Trail(root: library.root)
        understanding.libraryChanged()
        topBar.searchField.stringValue = ""
        setSearchExpanded(false)
        sidebar.select(.all)
        cabinetsChanged()
    }

    private func cabinetsChanged() {
        sidebar.cabinetName = cabinets.current.name
        sidebar.cabinetID = cabinets.currentID
        sidebar.coverPicture = cabinets.coverURL(cabinets.currentID)
        updateTitle()
        watchFolders()
    }

    private var watchedNow: (UUID, [URL])?

    /// The open 珍奇室's folders, watched; the same ones aren't restarted.
    /// A 珍奇室 that keeps its files fills its vault instead.
    private func watchFolders() {
        let vault = cabinets.vault(cabinets.currentID)
        if library.vaultDir != vault {
            library.vaultDir = vault
            if vault != nil { Task { await library.fillVault() } }
        }
        let folders = cabinets.watched(cabinets.currentID)
        if let now = watchedNow, now.0 == cabinets.currentID, now.1 == folders { return }
        watchedNow = (cabinets.currentID, folders)
        folderWatcher.watch(folders)
    }

    // Tests switch cabinets the way the menu does.
    var cabinetNames: [String] { cabinets.entries.map(\.name) }
    func createCabinetForTest(_ name: String) -> UUID { cabinets.create(named: name).id }
    var currentCabinet: UUID { cabinets.currentID }
    func closeCabinetsForTest() { cabinetsPanel?.closeForTest() }
    var cabinetsWindowNumber: Int? { cabinetsPanel?.windowNumber }
    func beginAddCabinetForTest() { cabinetsPanel?.beginAddForTest() }
    func typeCabinetNameForTest(_ name: String) { cabinetsPanel?.typeNameForTest(name) }
    func cabinetID(named name: String) -> UUID? { cabinets.entries.first { $0.name == name }?.id }
    func watchFolderForTest(_ folder: URL) -> Bool {
        defer { cabinetsChanged() }
        return cabinets.watch(folder, in: cabinets.currentID)
    }
    func hoverViewBarForTest() -> String? { viewBar.hoverFirstForTest() }
    func openSearchForTest() { focusSearch() }
    var spacesControlForTest: NSView { topBar.spaces }
    var contentAreaForTest: NSView? { contentArea }
    var topBarOverlapsForTest: Bool { topBar.layoutSubtreeIfNeeded(); return topBar.controlsOverlap }
    var sidebarToggleForTest: NSView { topBar.sidebarButton }
    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }
    func showSettingsTabForTest(_ tab: SettingsWindowController.Tab) { settings.showForTest(tab) }
    func flipCabinetForTest() { cabinetsPanel?.flipForTest(cabinets.currentID) }
    func collectDropForTest(_ pasteboard: NSPasteboard) -> Bool { capture.collectDrop(pasteboard) }
    func setCoverForTest(_ picture: URL?) -> Bool {
        defer { cabinetsChanged() }
        guard let picture else { cabinets.clearCover(for: cabinets.currentID); return true }
        return cabinets.setCover(from: picture, for: cabinets.currentID)
    }
    func setVaultForTest(_ folder: URL?) {
        if let folder { cabinets.setVault(folder, for: cabinets.currentID) } else { cabinets.clearVault(for: cabinets.currentID) }
        cabinetsChanged()
    }
    func leaveEmptySearchForTest() {
        let field = topBar.searchField
        field.stringValue = ""
        searchFieldDidEndSearching(field)
    }
    var viewBarTipsForTest: [String] { viewBar.isHidden ? [] : viewBar.tips }
    var watchedFoldersForTest: [URL] { cabinets.watched(cabinets.currentID) }
    func unwatchFolderForTest(_ folder: URL) { cabinets.unwatch(folder, in: cabinets.currentID); cabinetsChanged() }
    func canDeleteCabinet(_ id: UUID) -> Bool { cabinets.canDelete(id) }
    func deleteCabinetForTest(_ id: UUID) { cabinets.delete(id); cabinetsChanged() }

    @objc private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let board = scope.board
        Task { await library.importFiles(urls, into: board) }
    }

    @objc func importAtlas() {
        Task { _ = await library.importFromAtlas() }
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    @objc private func zoomIn() { zoom(1.25) }
    @objc private func zoomOut() { zoom(0.8) }

    private func zoom(_ factor: CGFloat) {
        switch mode {
        case .canvas: canvas.zoom(by: factor)
        case .infinity: infinity.zoom(by: factor)
        case .graph: graphView.zoom(by: factor)
        default: grid.zoom(by: factor)
        }
    }
}

/// The views Space, Enter, R and selection come from.
@MainActor
protocol CabinetSurface: AnyObject {
    var onOpen: ((UUID) -> Void)? { get set }
    var onActivate: ((UUID) -> Void)? { get set }
    var onRandom: (() -> Void)? { get set }
    var onFocus: ((UUID?) -> Void)? { get set }
    var onSimilar: ((UUID) -> Void)? { get set }
}

extension AppDelegate {
    var graphForTest: GraphView { graphView }
}

/// System Quick Look for media and documents: plays video and audio, pages
/// through PDFs, previews any file type, zooming from the tile.
@MainActor
final class QuickLookHost: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var library: Library?
    var sourceFrame: ((UUID) -> NSRect?)?
    private var url: URL?
    private var id: UUID?

    func show(_ url: URL, for id: UUID) {
        self.url = url
        self.id = id
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated { id.flatMap { sourceFrame?($0) } ?? .zero }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        // NSImage isn't Sendable; it's created and used on the main thread here.
        nonisolated(unsafe) var image: NSImage?
        MainActor.assumeIsolated {
            if let id, let library, let item = library.item(id) { image = NSImage(contentsOf: library.thumbnailURL(item)) }
        }
        return image
    }
}
