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

    /// Opens the system's Chinese → English language download (AppDelegate).
    var onEnableChinese: (() -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520), styleMask: [.titled, .closable],
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

    /// Grouped like System Settings: what each thing does, then its control.
    private func build() {
        let capture = ShortcutField(key: CaptureController.captureKey, current: CaptureController.captureShortcut,
                                    fallback: CaptureController.defaultCaptureShortcut)
        let shot = ShortcutField(key: CaptureController.screenshotKey, current: CaptureController.screenshotShortcut,
                                 fallback: CaptureController.defaultScreenshotShortcut)
        for f in [capture, shot] {
            f.onChange = { [weak self] in self?.onShortcutsChanged?() }
            f.onRecording = { [weak self] r in self?.onRecording?(r) }
        }
        let spotlight = NSSwitch()
        spotlight.state = Self.spotlightEnabled ? .on : .off
        spotlight.target = self
        spotlight.action = #selector(toggleSpotlight(_:))
        spotlight.setAccessibilityLabel("在 Spotlight 顯示收藏")

        var asking = false
        if #available(macOS 26.0, *) { asking = Asker.isAvailable }
        let chinese = NSButton(title: "下載…", target: self, action: #selector(enableChinese))
        chinese.bezelStyle = .rounded
        chinese.controlSize = .small

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        func group(_ title: String, _ rows: [NSView], note: String? = nil) {
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(header)
            let box = card(rows)
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            if let note {
                let n = NSTextField(wrappingLabelWithString: note)
                n.font = .systemFont(ofSize: 11)
                n.textColor = .secondaryLabelColor
                stack.addArrangedSubview(n)
                n.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }
        }
        group("收藏", [
            row("收藏剪貼簿或目前頁面", "剛拷貝的東西優先；沒有的話，收瀏覽器正在看的頁面", capture),
            row("截圖收藏", "選範圍或視窗，截好直接收進來", shot),
        ], note: "點一下快捷鍵，再按下新的組合鍵。Esc 取消，Delete 還原預設。")
        group("搜尋與理解", [
            row("用描述找圖", "例如「a cat at a dinner table」，用本機的 MobileCLIP 模型",
                status(semanticReady(), ready: "已安裝", missing: "未安裝")),
            row("對收藏提問", "在搜尋框輸入問句後按 Return，或對 Siri 說 Ask Wunderkammer",
                status(asking, ready: "Apple Intelligence 可用", missing: "需要 Apple Intelligence")),
            row("中文描述", "用中文描述找圖，需要系統的中文 → 英文翻譯語言", chinese),
        ])
        group("隱私", [
            row("在 Spotlight 顯示收藏", "只放標題、網站與主題，不放文字內容", spotlight),
        ], note: "圖中文字、物件、相似度與名字的辨識，都在這台 Mac 上完成，不會上傳任何內容。")

        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 540),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    /// One setting: its name and what it does on the left, the control on the right.
    private func row(_ title: String, _ detail: String, _ control: NSView) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        let about = NSTextField(wrappingLabelWithString: detail)
        about.font = .systemFont(ofSize: 11)
        about.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, about])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        // Text from the left, the control against the right edge.
        let row = NSStackView()
        row.addView(text, in: .leading)
        row.addView(control, in: .trailing)
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    /// Rows on a rounded card, a hairline between them.
    private func card(_ rows: [NSView]) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.spacing = 0
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                box.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -28).isActive = true
            }
            box.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        }
        return box
    }

    private func status(_ ok: Bool, ready: String, missing: String) -> NSView {
        let t = NSTextField(labelWithString: (ok ? "● " : "○ ") + (ok ? ready : missing))
        t.font = .systemFont(ofSize: 12)
        t.textColor = ok ? .systemGreen : .secondaryLabelColor
        return t
    }

    @objc private func enableChinese() { onEnableChinese?() }

    @objc private func toggleSpotlight(_ sender: NSSwitch) {
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
