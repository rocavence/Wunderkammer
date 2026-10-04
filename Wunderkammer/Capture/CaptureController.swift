import AppKit
import Carbon.HIToolbox

/// Every way in: the global shortcut, screenshots, macOS Services, and
/// wunderkammer:// links (bookmarklet, browser extension). All of them end in
/// Library.capture and a toast; none asks a question.
@MainActor
final class CaptureController: NSObject {
    private let library: Library
    private let hotkeys = GlobalHotkeys()
    let toast = CaptureToast()
    /// The board new captures also join (the one being looked at), if any.
    var currentBoard: () -> UUID? = { nil }

    /// Clipboard bookkeeping: what we've already captured, and when it last changed.
    private var capturedChangeCount = NSPasteboard.general.changeCount
    private var seenChangeCount = NSPasteboard.general.changeCount
    private var lastChange = Date.distantPast
    private var pollTimer: Timer?
    /// A copy this recent is what ⌘⇧C means; older, the frontmost page wins.
    private let freshClipboard: TimeInterval = 60

    static let defaultCaptureShortcut = GlobalHotkeys.Shortcut(keyCode: kVK_ANSI_C, modifiers: [.command, .shift])
    static let defaultScreenshotShortcut = GlobalHotkeys.Shortcut(keyCode: kVK_ANSI_C, modifiers: [.command, .shift, .control])
    static let captureKey = "shortcut.capture", screenshotKey = "shortcut.screenshot"

    /// The user's choice (Settings), else the default.
    static var captureShortcut: GlobalHotkeys.Shortcut {
        UserDefaults.standard.string(forKey: captureKey).flatMap(GlobalHotkeys.Shortcut.init(stored:)) ?? defaultCaptureShortcut
    }
    static var screenshotShortcut: GlobalHotkeys.Shortcut {
        UserDefaults.standard.string(forKey: screenshotKey).flatMap(GlobalHotkeys.Shortcut.init(stored:)) ?? defaultScreenshotShortcut
    }

    init(library: Library) {
        self.library = library
        super.init()
    }

    private(set) var shortcutRegistered = false
    private var shareInbox: ShareInboxWatcher?

    /// (Re)binds both shortcuts; called again after Settings changes them.
    func registerShortcuts() {
        hotkeys.unregisterAll()
        shortcutRegistered = hotkeys.register(Self.captureShortcut) { [weak self] in
            Task { await self?.captureNow() }
        }
        if !shortcutRegistered {
            toast.show(title: "\(Self.captureShortcut.display) 已被其他 app 使用",
                       detail: "到設定換一組快捷鍵，或從選單「檔案 → 收藏剪貼簿或目前頁面」收藏", image: nil)
        }
        hotkeys.register(Self.screenshotShortcut) { [weak self] in
            Task { await self?.captureScreenshot() }
        }
    }

    /// While Settings records a new shortcut, the old ones must not swallow it.
    func suspendShortcuts() { hotkeys.unregisterAll() }

    func start() {
        registerShortcuts()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        let inbox = ShareInboxWatcher { [weak self] sources in await self?.collect(sources, sourceApp: "分享") }
        inbox.start()
        shareInbox = inbox
    }

    private func watchClipboard() {
        let count = NSPasteboard.general.changeCount
        if count != seenChangeCount {
            seenChangeCount = count
            lastChange = Date()
        }
    }

    // MARK: ⌘⇧C

    /// Something just copied → that. Otherwise, in a browser → the page.
    /// Otherwise whatever is on the clipboard.
    /// Whether anything was collected (Siri says so).
    @discardableResult
    func captureNow() async -> Bool {
        watchClipboard()
        let front = NSWorkspace.shared.frontmostApplication
        let fromUs = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let pb = NSPasteboard.general
        let fresh = pb.changeCount != capturedChangeCount && Date().timeIntervalSince(lastChange) < freshClipboard
        var sources: [Source] = fresh ? PasteboardReader.sources(from: pb) : []

        if sources.isEmpty, !fromUs, BrowserTab.isBrowser(front) {
            switch await BrowserTab.current(front) {
            case .success(let page):
                sources = [.web(page.url, title: page.title)]
            case .failure(let error) where error.reason == .needsAccessibility:
                toast.show(title: "需要「輔助使用」權限", detail: "允許後再按一次 ⌘⇧C，就能收藏這個瀏覽器的網址", image: nil)
                return false
            case .failure:
                break
            }
        }
        if sources.isEmpty { sources = PasteboardReader.sources(from: pb) }
        guard !sources.isEmpty else {
            toast.show(title: "沒有東西可以收", detail: "先複製圖片、網址或文字，再按 ⌘⇧C", image: nil)
            return false
        }
        capturedChangeCount = pb.changeCount
        await collect(sources, sourceApp: fromUs ? nil : front?.localizedName)
        return true
    }

    // MARK: Screenshot

    /// The system's own selection UI (drag a region, Space for a window).
    func captureScreenshot() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(Self.stamp()).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        do { try process.run() } catch { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
        }
        guard let data = try? Data(contentsOf: file) else { return } // cancelled with Esc
        try? FileManager.default.removeItem(at: file)
        await collect([.imageData(data, name: file.lastPathComponent, origin: nil)], sourceApp: "Screenshot")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    // MARK: Services ("Collect in Wunderkammer" in every app's Services menu)

    @objc func collectService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let sources = PasteboardReader.sources(from: pboard)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        Task { await collect(sources, sourceApp: app) }
    }

    // MARK: wunderkammer://capture?url=…&title=…&text=…&image=…

    /// The app delegate receives the link (it can arrive before launch is done).
    func handle(_ url: URL) {
        let sources = Self.sources(fromCaptureURL: url)
        guard !sources.isEmpty else { return }
        Task { await collect(sources, sourceApp: "Browser") }
    }

    /// The bookmarklet/extension contract, kept separate so it can be tested.
    nonisolated static func sources(fromCaptureURL url: URL) -> [Source] {
        guard url.scheme == "wunderkammer", url.host() == "capture",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // Any web page can open a wunderkammer:// link: accept only web
        // addresses (never file:// or other schemes) and bounded text.
        func web(_ s: String?) -> URL? {
            guard let s, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host() != nil else { return nil }
            return url
        }
        let page = web(value("url"))
        if let image = web(value("image")) {
            // An image from a page: fetched like a link to an image.
            return [.web(image, title: value("title"))]
        }
        if let text = value("text") { return [.text(String(text.prefix(20_000)), origin: page)] }
        if let page { return [.web(page, title: value("title"))] }
        return []
    }

    // MARK: Common end

    private func collect(_ sources: [Source], sourceApp: String?) async {
        guard !sources.isEmpty else { return }
        let before = Set(library.items.map(\.id))
        let ids = await library.capture(sources, into: currentBoard(), sourceApp: sourceApp)
        guard let first = ids.first.flatMap(library.item) else {
            toast.show(title: "收不進來", detail: "這個格式讀不到內容", image: nil)
            return
        }
        let isNew = !before.contains(first.id)
        let image = NSImage(contentsOf: library.thumbnailURL(first))
        let count = ids.count
        let title = isNew ? (count > 1 ? "收進 \(count) 件" : "收進珍奇櫃") : "已經在珍奇櫃裡"
        toast.show(title: title, detail: first.displayTitle, image: image)
    }
}
