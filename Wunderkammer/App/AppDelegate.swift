import AppKit
import CoreSpotlight
import Quartz

enum ViewMode: Int, CaseIterable {
    case grid, masonry, timeline, canvas, infinity

    var title: String { ["Grid", "Masonry", "Timeline", "Canvas", "Infinity"][rawValue] }
    var icon: Reicon { [.grid, .layout, .calendar, .layers, .infinite][rawValue] }

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
    private(set) var preview: PreviewView!
    private var modeControl: NSSegmentedControl!
    private var searchItem: NSSearchToolbarItem?
    private(set) var mode = ViewMode.grid
    private(set) var scope = Scope()
    private var capture: CaptureController!
    private let quickLook = QuickLookHost()
    private var understanding: Understanding!
    private var spotlight: SpotlightIndexer?
    /// Recently shown by R, so it doesn't repeat itself.
    private var recentRandom: [UUID] = []

    private static let modeKey = "mode"
    private static let boardKey = "board"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Copies and representations of items removed in an earlier session.
        library.purgeOrphans()
        grid = GridView(library: library, thumbnailer: thumbnailer)
        scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        canvas = CanvasView(library: library, thumbnailer: thumbnailer)
        infinity = InfinityView(library: library, thumbnailer: thumbnailer)
        preview = PreviewView(library: library, thumbnailer: thumbnailer)

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
        for v in [scroll!, canvas!, infinity!, preview!] as [NSView] {
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
        }
        let contentVC = NSViewController()
        contentVC.view = content

        sidebar = SidebarViewController(library: library)
        sidebar.onSelect = { [weak self] base in self?.show(base: base) }
        sidebar.onRandom = { [weak self] in self?.showRandom() }
        inspector = InspectorViewController(library: library)
        inspector.onSelectRelated = { [weak self] id in self?.reveal(id) }
        understanding = Understanding(library: library)
        library.similarity = { [weak self] id in self?.understanding.similar(to: id) ?? [] }
        inspector.related = { [weak self] item in self?.understanding.related(to: item) ?? [] }
        NotificationCenter.default.addObserver(forName: Understanding.didProgress, object: nil, queue: .main) { [weak self] _ in
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

        understanding.start()
        if !SelfTest.isEnabled { spotlight = SpotlightIndexer(library: library) }

        if SelfTest.isEnabled {
            if ProcessInfo.processInfo.environment["WK_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            window.setFrameAutosaveName("")
            window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
            setMode(.grid)
            sidebar.select(board: nil)
            let test = SelfTest(window: window, library: library, ui: self)
            Task { await test.run() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon, or opened with Wunderkammer.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
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
        if mode == .infinity { setMode(.grid) }
        reveal(id)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { library.save() }

    // MARK: State

    private func show(base: Scope.Base) {
        scope = Scope(base: base, search: "")
        searchItem?.searchField.stringValue = ""
        if !SelfTest.isEnabled { UserDefaults.standard.set(scope.board?.uuidString, forKey: Self.boardKey) }
        updateTitle()
        grid.show(scope: scope)
        canvas.show(scope: scope)
        infinity.show(scope: scope)
        inspector.show(nil)
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
        }
        let count = library.items(for: scope).count
        let learning = understanding?.pending ?? 0
        window.subtitle = (scope.isSearching ? "找到 \(count) 件" : "\(count) 件") + (learning > 0 ? " · 正在理解 \(learning) 件" : "")
    }

    func setMode(_ new: ViewMode) {
        mode = new
        if !SelfTest.isEnabled { UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey) }
        modeControl?.selectedSegment = new.rawValue
        scroll.isHidden = new.cabinetStyle == nil
        if let style = new.cabinetStyle {
            if grid.style == style { grid.reload(animated: false) } else { grid.style = style }
        }
        canvas.isHidden = new != .canvas
        infinity.isHidden = new != .infinity
        focusCurrent()
    }

    private var currentView: NSView {
        switch mode {
        case .canvas: canvas
        case .infinity: infinity
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
        guard let item = library.item(id) else { return }
        library.markViewed(id)
        inspector.show(id)
        if [.video, .audio, .pdf, .file].contains(item.kind), let url = library.originalURL(item) {
            quickLook.show(url, for: id)
            return
        }
        // Long text doesn't fit a card: read all of it in Quick Look.
        if item.kind == .text, let text = item.text, text.count > 280 {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.displayTitle.prefix(40)).txt")
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
        if mode == .infinity { setMode(.grid) }
        if scope.isSearching { clearSearch() }
        currentSurface.reveal(pick.id)
        let caption = Rediscovery.ageLine(pick)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.openPreview(pick.id, caption: caption) }
        }
    }

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
        // Results are a list to scan: shown in the scrolling views.
        if scope.isSearching, mode.cabinetStyle == nil { setMode(.grid) }
        grid.show(scope: scope)
        updateTitle()
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
            item.searchField.placeholderString = "搜尋：紅色的椅子、2025、網站…"
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
        let captureItem = fileMenu.addItem(withTitle: "收藏剪貼簿或目前頁面", action: #selector(captureNow), keyEquivalent: "c")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        let shot = fileMenu.addItem(withTitle: "截圖收藏", action: #selector(captureScreenshot), keyEquivalent: "c")
        shot.keyEquivalentModifierMask = [.command, .shift, .control]
        shot.target = self
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

    @objc private func importAtlas() {
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
