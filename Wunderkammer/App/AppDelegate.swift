import AppKit

enum ViewMode: Int, CaseIterable {
    case grid, canvas, infinity

    var title: String { ["Grid", "Canvas", "Infinity"][rawValue] }
    var icon: Reicon { [.grid, .layers, .infinite][rawValue] }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, SelfTestUI {
    private var window: NSWindow!
    private let library = Library(root: ProcessInfo.processInfo.environment["WK_LIBRARY_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? Library.defaultRoot)
    private let thumbnailer = Thumbnailer()
    private(set) var sidebar: SidebarViewController!
    private var scroll: NSScrollView!
    private(set) var grid: GridView!
    private(set) var canvas: CanvasView!
    private(set) var infinity: InfinityView!
    private(set) var preview: PreviewView!
    private var modeControl: NSSegmentedControl!
    private var mode = ViewMode.grid
    private var board: UUID?

    private static let modeKey = "mode"
    private static let boardKey = "board"

    func applicationDidFinishLaunching(_ notification: Notification) {
        grid = GridView(library: library, thumbnailer: thumbnailer)
        scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        canvas = CanvasView(library: library, thumbnailer: thumbnailer)
        infinity = InfinityView(library: library, thumbnailer: thumbnailer)
        preview = PreviewView(library: library, thumbnailer: thumbnailer)

        grid.onOpen = { [weak self] id in self?.openPreview(id) }
        canvas.onOpen = { [weak self] id in self?.openPreview(id) }
        infinity.onOpen = { [weak self] id in self?.openPreview(id) }
        preview.onClose = { [weak self] in self?.focusCurrent() }

        let content = NSView()
        for v in [scroll!, canvas!, infinity!, preview!] as [NSView] {
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
        }
        let contentVC = NSViewController()
        contentVC.view = content

        sidebar = SidebarViewController(library: library)
        sidebar.onSelect = { [weak self] id in self?.show(board: id) }

        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 320
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: contentVC))

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
        window.makeKeyAndOrderFront(nil)

        buildMenu()

        let defaults = UserDefaults.standard
        let savedBoard = defaults.string(forKey: Self.boardKey).flatMap(UUID.init(uuidString:))
        setMode(ViewMode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .grid)
        sidebar.select(board: savedBoard)
        NSApp.activate()

        if SelfTest.isEnabled {
            window.setFrameAutosaveName("")
            window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
            setMode(.grid)
            sidebar.select(board: nil)
            let test = SelfTest(window: window, library: library, ui: self)
            Task { await test.run() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: State

    private func show(board: UUID?) {
        self.board = board
        if !SelfTest.isEnabled { UserDefaults.standard.set(board?.uuidString, forKey: Self.boardKey) }
        window.title = board.flatMap { library.collection($0)?.name } ?? "全部圖片"
        grid.show(board: board)
        canvas.show(board: board)
        infinity.show(board: board)
        focusCurrent()
    }

    func setMode(_ new: ViewMode) {
        mode = new
        if !SelfTest.isEnabled { UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey) }
        modeControl?.selectedSegment = new.rawValue
        scroll.isHidden = new != .grid
        canvas.isHidden = new != .canvas
        infinity.isHidden = new != .infinity
        focusCurrent()
    }

    private var currentView: NSView {
        switch mode {
        case .grid: grid
        case .canvas: canvas
        case .infinity: infinity
        }
    }

    private func focusCurrent() {
        window.makeFirstResponder(currentView)
    }

    private func openPreview(_ id: UUID) {
        let surface: ItemSurface = switch mode {
        case .grid: grid
        case .canvas: canvas
        case .infinity: infinity
        }
        preview.open(id, from: surface)
    }

    // MARK: Toolbar

    private static let modeItem = NSToolbarItem.Identifier("mode")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.modeItem else { return nil }
        let images = ViewMode.allCases.map { Icon.image($0.icon, size: 18) }
        let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        for m in ViewMode.allCases { control.setToolTip("\(m.title)（⌘\(m.rawValue + 1)）", forSegment: m.rawValue) }
        control.selectedSegment = mode.rawValue
        modeControl = control
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = control
        item.label = "顯示方式"
        return item
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .grid)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "結束 Wunderkammer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "檔案")
        fileMenu.addItem(withTitle: "新增 board", action: #selector(newBoard), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "匯入…", action: #selector(importFiles), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "從 Atlas 匯入", action: #selector(importAtlas), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "在 Finder 顯示圖庫", action: #selector(revealLibrary), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編輯")
        editMenu.addItem(withTitle: "貼上", action: #selector(GridView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全選", action: #selector(NSView.selectAll(_:)), keyEquivalent: "a")
        let delete = editMenu.addItem(withTitle: "刪除", action: #selector(GridView.delete(_:)), keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = []
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
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "顯示或隱藏側欄", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: "進入全螢幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func modeFromMenu(_ sender: NSMenuItem) {
        if preview.isOpen { return }
        setMode(ViewMode(rawValue: sender.tag) ?? .grid)
    }

    @objc private func newBoard() { sidebar.newBoard(nil) }

    @objc private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let board = board
        Task { await library.importFiles(urls, into: board) }
    }

    @objc private func importAtlas() {
        Task {
            let count = await library.importFromAtlas()
            let alert = NSAlert()
            alert.messageText = count > 0 ? "從 Atlas 匯入了 \(count) 張圖" : "沒有新圖可以匯入"
            alert.informativeText = count > 0 ? "" : "Atlas 圖庫裡的圖都已經在這裡了，或找不到 Atlas 圖庫。"
            _ = await alert.beginSheetModal(for: window)
        }
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    @objc private func zoomIn() { zoom(1.25) }
    @objc private func zoomOut() { zoom(0.8) }

    private func zoom(_ factor: CGFloat) {
        switch mode {
        case .grid: grid.zoom(by: factor)
        case .canvas: canvas.zoom(by: factor)
        case .infinity: infinity.zoom(by: factor)
        }
    }
}
