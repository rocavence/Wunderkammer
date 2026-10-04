import AppKit

/// ⌘, — the few things worth choosing: the two shortcuts, and whether
/// curiosities appear in Spotlight. Everything else just works.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let spotlightKey = "spotlight.enabled"
    static var spotlightEnabled: Bool { UserDefaults.standard.object(forKey: spotlightKey) as? Bool ?? true }

    var onShortcutsChanged: (() -> Void)?
    var onRecording: ((Bool) -> Void)?
    var onSpotlightChanged: ((Bool) -> Void)?
    var semanticReady: () -> Bool = { false }

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "設定"
        self.init(window: window)
        // Closing Settings mid-recording must give the keyboard back.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutField.active?.cancel() }
        }
    }

    override func showWindow(_ sender: Any?) {
        ShortcutField.active?.cancel()
        build()
        window?.center()
        super.showWindow(sender)
        if !SelfTest.isEnabled { NSApp.activate() }
    }

    private func build() {
        let capture = ShortcutField(key: CaptureController.captureKey, current: CaptureController.captureShortcut,
                                    fallback: CaptureController.defaultCaptureShortcut)
        let shot = ShortcutField(key: CaptureController.screenshotKey, current: CaptureController.screenshotShortcut,
                                 fallback: CaptureController.defaultScreenshotShortcut)
        for f in [capture, shot] {
            f.onChange = { [weak self] in self?.onShortcutsChanged?() }
            f.onRecording = { [weak self] r in self?.onRecording?(r) }
        }
        let spotlight = NSButton(checkboxWithTitle: "在 Spotlight 顯示收藏（只有標題、網站與主題）", target: self, action: #selector(toggleSpotlight(_:)))
        spotlight.state = Self.spotlightEnabled ? .on : .off
        let semantic = NSTextField(wrappingLabelWithString: semanticReady()
            ? "語意搜尋：已安裝本機模型。"
            : "語意搜尋：尚未安裝本機模型。執行 scripts/models/fetch-mobileclip.sh 後重新打開 Wunderkammer。")
        semantic.textColor = .secondaryLabelColor
        semantic.font = .systemFont(ofSize: 12)

        let grid = NSGridView(views: [
            [label("收藏剪貼簿或目前頁面"), capture],
            [label("截圖收藏"), shot],
            [NSGridCell.emptyContentView, hint("點一下欄位，再按下新的組合鍵。Esc 取消，Delete 還原預設。")],
            [NSGridCell.emptyContentView, spotlight],
            [NSGridCell.emptyContentView, semantic],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            semantic.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        window?.contentView = content
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func hint(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .tertiaryLabelColor
        t.preferredMaxLayoutWidth = 260
        return t
    }

    @objc private func toggleSpotlight(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.spotlightKey)
        onSpotlightChanged?(sender.state == .on)
    }
}

/// Click, press a combination, done.
@MainActor
final class ShortcutField: NSButton {
    private let key: String
    private let fallback: GlobalHotkeys.Shortcut
    private var current: GlobalHotkeys.Shortcut
    private var monitor: Any?
    var onChange: (() -> Void)?
    var onRecording: ((Bool) -> Void)?

    init(key: String, current: GlobalHotkeys.Shortcut, fallback: GlobalHotkeys.Shortcut) {
        self.key = key
        self.current = current
        self.fallback = fallback
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = current.display
        target = self
        action = #selector(record)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The field currently waiting for a combination (never more than one).
    static weak var active: ShortcutField?

    @objc private func record() {
        guard monitor == nil else { return }
        Self.active?.cancel()
        Self.active = self
        title = "按下組合鍵…"
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only keystrokes aimed at Settings; everything else passes through.
            guard let self, event.window === self.window else { return event }
            MainActor.assumeIsolated { self.handle(event) }
            return nil
        }
    }

    /// Stop recording, keep the current shortcut.
    func cancel() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        title = current.display
        if Self.active === self { Self.active = nil }
        onRecording?(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { cancel() }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case 53: break // Esc: keep the current one
        case 51, 117: // Delete: back to the default
            UserDefaults.standard.removeObject(forKey: key)
            current = fallback
        default:
            // A global shortcut needs ⌘, ⌃ or ⌥, or it would eat ordinary typing.
            guard !mods.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
            current = GlobalHotkeys.Shortcut(keyCode: Int(event.keyCode), modifiers: mods)
            UserDefaults.standard.set(current.stored, forKey: key)
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.active === self { Self.active = nil }
        title = current.display
        onRecording?(false)
        onChange?()
    }
}
