import AppKit
import CoreSpotlight
import Quartz

enum ViewMode: Int, CaseIterable {
    case grid, masonry, timeline, canvas, infinity, graph

    var title: String { ["Grid", "Masonry", "Timeline", "Canvas", "Infinity", "Graph"][rawValue] }
    var icon: Reicon { [.grid, .layout, .calendar, .layers, .infinite, .nodes][rawValue] }

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSSearchFieldDelegate, SelfTestUI {
    private var window: NSWindow!
    private let library = Library(root: ProcessInfo.processInfo.environment["WK_LIBRARY_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? Library.defaultRoot)
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
    private var modeControl: NSSegmentedControl!
    private var searchItem: NSSearchToolbarItem?
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
        }
        try? FileManager.default.removeItem(at: Self.textPreviewDir)
        grid = GridView(library: library, thumbnailer: thumbnailer)
        scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

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

        let content = NSView()
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
        NSLayoutConstraint.activate([
            answerBanner.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
            answerBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            answerBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
        let contentVC = NSViewController()
        contentVC.view = content

        sidebar = SidebarViewController(library: library)
        sidebar.onSelect = { [weak self] base in self?.show(base: base) }
        sidebar.onRandom = { [weak self] in self?.showRandom() }
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
                parts.append(i == path.count - 1 ? "這件" : "《\(self.library.item(step.item)?.displayTitle.prefix(20) ?? "")》")
            }
            return "怎麼來的：" + parts.joined(separator: " → ")
        }
        NotificationCenter.default.addObserver(forName: Understanding.didProgress, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }

        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 300
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 340
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(inspectorItem)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.contentViewController = split
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setFrameAutosaveName("Main")
        if window.frame.origin == .zero { window.center() }
        // Quick Look looks for its controller up the responder chain.
        quickLook.library = library
        quickLook.sourceFrame = { [weak self] id in self?.screenRect(for: id) }
        window.nextResponder = quickLook
        window.makeKeyAndOrderFront(nil)

        buildMenu()

        let defaults = UserDefaults.standard
        let savedBoard = defaults.string(forKey: Self.boardKey).flatMap(UUID.init(uuidString:))
        setMode(ViewMode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .grid)
        sidebar.select(board: savedBoard)
        NSApp.activate()

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
            window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
            // Covered by other windows, the cabinet rightly stops animating and
            // clicks land elsewhere: keep the test window on top while it runs.
            window.level = .floating
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
        NSApp.activate()
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
        item.button?.image = Icon.image(.cabinet, size: 16)
        item.button?.toolTip = "Wunderkammer"
        let menu = NSMenu()
        Self.show(CaptureController.captureShortcut, on: menu.addItem(withTitle: "收藏剪貼簿或目前頁面", action: #selector(captureNow), keyEquivalent: ""))
        Self.show(CaptureController.screenshotShortcut, on: menu.addItem(withTitle: "截圖收藏", action: #selector(captureScreenshot), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(withTitle: "隨機一件", action: #selector(randomFromStatus), keyEquivalent: "")
        menu.addItem(withTitle: "打開珍奇室", action: #selector(showCabinet), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 Wunderkammer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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

    private func show(base: Scope.Base) {
        if case .answer = base {} else if !answerBanner.isHidden { hideAnswerBanner() }
        scope = Scope(base: base, search: "")
        searchItem?.searchField.stringValue = ""
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
        case .all: window.title = "珍奇室"
        case .board(let id): window.title = library.collection(id)?.name ?? "Board"
        case .kind(let k): window.title = k.title
        case .onThisDay: window.title = "過去的今天"
        case .forgotten: window.title = "被遺忘的"
        case .similar(let id): window.title = "與「\(library.item(id)?.displayTitle.prefix(20) ?? "")」相似"
        case .subject(let label): window.title = Subjects.title(label)
        case .mentions(let name): window.title = "提到「\(name)」"
        case .site(let domain): window.title = domain
        case .trail: window.title = "足跡"
        case .answer: window.title = "回答"
        }
        let count = library.items(for: scope).count
        let learning = understanding?.pending ?? 0
        window.subtitle = (scope.isSearching ? "找到 \(count) 件" : "\(count) 件") + (learning > 0 ? " · 正在理解 \(learning) 件" : "")
        // A cabinet with nothing in it yet gets its welcome instead of empty views.
        emptyCabinet?.isHidden = !library.items.isEmpty
    }

    func setMode(_ new: ViewMode) {
        // A preview belongs to the view it flew out of.
        if new != mode, preview.isOpen { preview.dismissImmediately() }
        mode = new
        if !SelfTest.isEnabled { UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey) }
        modeControl?.selectedSegment = new.rawValue
        scroll.isHidden = new.cabinetStyle == nil
        if let style = new.cabinetStyle {
            if grid.style == style { grid.reload(animated: false) } else { grid.style = style }
        }
        canvas.isHidden = new != .canvas
        infinity.isHidden = new != .infinity
        graphView.isHidden = new != .graph
        updateTrailView()
        focusCurrent()
    }

    /// 足跡 in the scrolling views is the path itself, not a grid of what was seen.
    private func updateTrailView() {
        let showing = scope.base == .trail && mode.cabinetStyle != nil && !scope.isSearching
        trailView.isHidden = !showing
        if mode.cabinetStyle != nil { scroll.isHidden = showing }
        if showing { trailView.show(trail.visits(existing: Set(library.items.map(\.id)))) }
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
        case .web: [item.domain, "按 Return 在瀏覽器打開"].compactMap { $0 }.joined(separator: " · ")
        case .text where item.url != nil: [item.domain, "按 Return 打開來源"].compactMap { $0 }.joined(separator: " · ")
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
    func showRandom() {
        if preview.isOpen { preview.dismissImmediately() }
        let pool = library.items(for: Scope(base: scope.base))
        guard let pick = Rediscovery.pick(pool, avoiding: recentRandom) ?? Rediscovery.pick(library.items, avoiding: recentRandom)
        else { NSSound.beep(); return }
        recentRandom = Array(([pick.id] + recentRandom).prefix(20))
        if !pool.contains(where: { $0.id == pick.id }) { sidebar.select(.all) }
        if mode == .infinity || mode == .graph { setMode(.grid) }
        if scope.isSearching { clearSearch() }
        currentSurface.reveal(pick.id)
        let caption = Rediscovery.ageLine(pick)
        pendingVia = .random
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.openPreview(pick.id, caption: caption) }
        }
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
        guard let item = searchItem else { return }
        window.makeFirstResponder(item.searchField)
        item.beginSearchInteraction()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchItem?.searchField else { return }
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
        searchItem?.searchField.stringValue = ""
        search("")
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { clearSearch() }
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

    func ask(_ question: String) {
        guard #available(macOS 26.0, *) else { return }
        let asker = (askerBox as? Asker) ?? {
            let a = Asker(library: library) { [weak self] english, pool in await self?.looksLike(english, in: pool) ?? [] }
            askerBox = a
            return a
        }()
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
                (text, ids) = ("這個問題 Apple Intelligence 不回答，換個問法試試。", nil)
            } catch Asker.Failure.tooSlow {
                (text, ids) = ("想太久了，沒有得到回答。換個說法再問一次試試。", nil)
            } catch {
                (text, ids) = ("沒辦法回答：\(error.localizedDescription)", nil)
            }
            guard let self, !Task.isCancelled else { return }
            self.askTask = nil
            if let ids {
                self.searchItem?.searchField.stringValue = ""
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
        inspectorItem.animator().isCollapsed.toggle()
    }

    func toggleInspectorForTest() { toggleInspector() }

    // MARK: Toolbar

    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let searchID = NSToolbarItem.Identifier("search")
    private static let inspectorID = NSToolbarItem.Identifier("inspector")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem, Self.searchID, .inspectorTrackingSeparator, Self.inspectorID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.modeItem:
            let images = ViewMode.allCases.map { Icon.image($0.icon, size: 17) }
            let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            for m in ViewMode.allCases { control.setToolTip("\(m.title)（⌘\(m.rawValue + 1)）", forSegment: m.rawValue) }
            control.selectedSegment = mode.rawValue
            modeControl = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "顯示方式"
            return item
        case Self.searchID:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "搜尋，或問一個問題：我收過哪些書？"
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 260
            item.toolTip = "搜尋（⌘K）"
            searchItem = item
            return item
        case Self.inspectorID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = Icon.image(.infoCircle, size: 17)
            item.label = "資訊"
            item.toolTip = "資訊（⌘I）"
            item.target = self
            item.action = #selector(toggleInspector)
            return item
        default:
            return nil
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .grid)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "關於 Wunderkammer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "服務", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隱藏 Wunderkammer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "結束 Wunderkammer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "檔案")
        let captureItem = fileMenu.addItem(withTitle: "收藏剪貼簿或目前頁面", action: #selector(captureNow), keyEquivalent: "")
        captureItem.target = self
        Self.show(CaptureController.captureShortcut, on: captureItem)
        let shot = fileMenu.addItem(withTitle: "截圖收藏", action: #selector(captureScreenshot), keyEquivalent: "")
        shot.target = self
        Self.show(CaptureController.screenshotShortcut, on: shot)
        fileMenu.addItem(withTitle: "加入檔案…", action: #selector(importFiles), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "從 Atlas 匯入", action: #selector(importAtlas), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "新增 board", action: #selector(newBoard), keyEquivalent: "n").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "在 Finder 顯示圖庫", action: #selector(revealLibrary), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編輯")
        editMenu.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let remove = editMenu.addItem(withTitle: "移除", action: #selector(GridView.delete(_:)), keyEquivalent: "\u{8}")
        remove.keyEquivalentModifierMask = [.command]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "搜尋", action: #selector(focusSearch), keyEquivalent: "k").target = self
        editMenu.addItem(withTitle: "啟用中文描述搜尋…", action: #selector(enableChineseDescriptions), keyEquivalent: "").target = self
        editMenu.addItem(withTitle: "搜尋", action: #selector(focusSearch), keyEquivalent: "f").target = self
        editMenu.items.last?.isAlternate = false
        editMenu.items.last?.isHidden = true
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "顯示方式")
        for m in ViewMode.allCases {
            let item = viewMenu.addItem(withTitle: m.title, action: #selector(modeFromMenu(_:)), keyEquivalent: "\(m.rawValue + 1)")
            item.tag = m.rawValue
            item.target = self
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "=").target = self
        viewMenu.addItem(withTitle: "縮小", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: "整理 Canvas", action: #selector(CanvasView.arrange(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Canvas 依主題分堆", action: #selector(CanvasView.clusterByTheme(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "隨機一件", action: #selector(randomFromMenu), keyEquivalent: "r").keyEquivalentModifierMask = [.command, .option]
        viewMenu.items.last?.target = self
        viewMenu.addItem(withTitle: "資訊", action: #selector(toggleInspector), keyEquivalent: "i").target = self
        viewMenu.addItem(withTitle: "顯示或隱藏側欄", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: "進入全螢幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "視窗")
        windowMenu.addItem(withTitle: "縮到最小", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "珍奇室", action: #selector(showCabinet), keyEquivalent: "0").target = self
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func modeFromMenu(_ sender: NSMenuItem) {
        if preview.isOpen { return }
        setMode(ViewMode(rawValue: sender.tag) ?? .grid)
    }

    @objc private func randomFromMenu() { showRandom() }
    @objc private func captureNow() { Task { await capture.captureNow() } }
    @objc private func captureScreenshot() { Task { await capture.captureScreenshot() } }
    @objc private func newBoard() { sidebar.newBoard(nil) }

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
