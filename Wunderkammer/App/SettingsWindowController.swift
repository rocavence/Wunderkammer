import AppKit

/// ⌘, — laid out as in Flione: the sections down the left, each one's
/// settings on the right, every setting its name, a line on what it does, and
/// its control. Language, look and accent; the shortcuts; search; privacy.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let spotlightKey = "spotlight.enabled"
    static var spotlightEnabled: Bool { UserDefaults.standard.object(forKey: spotlightKey) as? Bool ?? true }

    var onShortcutsChanged: (() -> Void)?
    var onRecording: ((Bool) -> Void)?
    var onSpotlightChanged: ((Bool) -> Void)?
    var semanticReady: () -> Bool = { false }
    var update: () -> UpdateChecker.Release? = { nil }
    var onCheckUpdate: (() -> Void)?
    /// What the last check by hand found: nil not asked (or GitHub unreachable).
    var updateResult: Bool?
    var semanticState: () -> ModelInstaller.State = { .idle }
    var onInstallSemantic: (() -> Void)?

    /// Redraws the page in front, for a status that changed while it was open.
    func refresh() {
        guard window?.isVisible == true else { return }
        show(tab)
    }

    /// Opens the system's Chinese → English language download (AppDelegate).
    var onEnableChinese: (() -> Void)?

    enum Tab: CaseIterable {
        case general, collecting, understanding, privacy, about

        var title: String {
            switch self {
            case .general: String(localized: "一般")
            case .collecting: String(localized: "收藏")
            case .understanding: String(localized: "搜尋與理解")
            case .privacy: String(localized: "隱私")
            case .about: String(localized: "關於")
            }
        }

        var icon: Reicon {
            switch self {
            case .general: .setting
            case .collecting: .inboxIn
            case .understanding: .sparkles
            case .privacy: .shield
            case .about: .infoCircle
            }
        }
    }

    private var tab: Tab = .general
    private let sidebar = NSStackView()
    private let heading = NSTextField(labelWithString: "")
    private let page = FlippedView()
    private let scroll = NSScrollView()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "設定")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        self.init(window: window)
        buildFrame()
        // Closing Settings mid-recording must give the keyboard back.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutField.active?.cancel() }
        }
        NotificationCenter.default.addObserver(forName: Accent.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(self?.tab ?? .general) }
        }
    }

    override func showWindow(_ sender: Any?) {
        ShortcutField.active?.cancel()
        window?.center()
        super.showWindow(sender)
        // Laid out once the window is on screen, at its real width.
        show(tab)
        if !SelfTest.isEnabled { NSApp.activate() }
    }

    // MARK: Frame: sections on the left, the chosen one on the right

    private func buildFrame() {
        let left = NSVisualEffectView()
        left.material = .sidebar
        left.blendingMode = .behindWindow
        left.state = .followsWindowActiveState
        let title = NSTextField(labelWithString: String(localized: "設定"))
        title.font = Typography.display(22) ?? .systemFont(ofSize: 22, weight: .semibold)
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        for v in [title, sidebar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(v)
        }
        let line = NSBox()
        line.boxType = .separator
        heading.font = Typography.display(24) ?? .systemFont(ofSize: 24, weight: .semibold)
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = page
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let root = NSView()
        for v in [left, line, heading, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: 220),
            title.topAnchor.constraint(equalTo: left.topAnchor, constant: 52),
            title.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 22),
            sidebar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            sidebar.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            sidebar.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            line.topAnchor.constraint(equalTo: root.topAnchor),
            line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            heading.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 32),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: line.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        window?.contentView = root
    }

    private func show(_ tab: Tab) {
        self.tab = tab
        sidebar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for t in Tab.allCases {
            let row = TabRow(t.title, icon: t.icon, selected: t == tab) { [weak self] in self?.show(t) }
            sidebar.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        heading.stringValue = tab.title
        page.subviews.forEach { $0.removeFromSuperview() }
        self.rows = []
        let rows: [NSView]
        switch tab {
        case .general: rows = generalRows()
        case .collecting: rows = collectingRows()
        case .understanding: rows = understandingRows()
        case .privacy: rows = privacyRows()
        case .about: rows = [about()]
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 32, bottom: 32, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true }
    }

    // MARK: Sections

    private func generalRows() -> [NSView] {
        // Language: takes effect on the next launch, with a restart offered.
        let language = NSPopUpButton()
        for l in AppLanguage.allCases {
            language.addItem(withTitle: l.title)
            language.lastItem?.representedObject = l.rawValue
        }
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.saved) ?? 0)
        language.target = self
        language.action = #selector(languagePicked(_:))
        let restart = PillButton(String(localized: "重新開啟")) { AppLanguage.relaunch() }
        restart.isHidden = AppLanguage.saved == AppLanguage.launched
        let languageControl = NSStackView(views: [restart, language])
        languageControl.spacing = 8
        let pending = AppLanguage.saved != AppLanguage.launched

        let look = NSPopUpButton()
        for a in AppAppearance.allCases { look.addItem(withTitle: a.title) }
        look.selectItem(at: AppAppearance.allCases.firstIndex(of: AppAppearance.saved) ?? 0)
        look.target = self
        look.action = #selector(appearancePicked(_:))

        let swatches = NSStackView(views: Accent.allCases.map { a in
            Swatch(a, selected: a == Accent.current) { Accent.apply(a) }
        })
        swatches.spacing = 6
        return [
            row(String(localized: "語言"),
                pending ? String(localized: "重新開啟 Wunder 後換成新的語言。") : String(localized: "選單、按鈕與訊息使用的語言。"),
                languageControl),
            row(String(localized: "外觀"), String(localized: "淺色、深色，或跟著系統切換。"), look),
            row(String(localized: "重點色"), String(localized: "只用在選中與作用中的東西：所在的空間、選取、拖放的目標。可以跟隨系統，或在這裡另外指定。"),
                swatches),
        ]
    }

    private func collectingRows() -> [NSView] {
        let capture = ShortcutField(key: CaptureController.captureKey, current: CaptureController.captureShortcut,
                                    fallback: CaptureController.defaultCaptureShortcut)
        let shot = ShortcutField(key: CaptureController.screenshotKey, current: CaptureController.screenshotShortcut,
                                 fallback: CaptureController.defaultScreenshotShortcut)
        for f in [capture, shot] {
            f.onChange = { [weak self] in self?.onShortcutsChanged?() }
            f.onRecording = { [weak self] r in self?.onRecording?(r) }
        }
        return [
            row(String(localized: "收藏剪貼簿或目前頁面"), String(localized: "剛拷貝的東西優先；沒有的話，收瀏覽器正在看的頁面"), capture),
            row(String(localized: "截圖收藏"), String(localized: "選範圍或視窗，截好直接收進來"), shot),
            note(String(localized: "點一下快捷鍵，再按下新的組合鍵。Esc 取消，Delete 還原預設。也可以把任何東西拖到選單列的拱門。")),
        ]
    }

    private func understandingRows() -> [NSView] {
        var asking = false
        if #available(macOS 26.0, *) { asking = Asker.isAvailable }
        let chinese = PillButton(String(localized: "下載…")) { [weak self] in self?.onEnableChinese?() }
        return [
            row(String(localized: "用描述找圖"), String(localized: "例如「a cat at a dinner table」，用本機的 MobileCLIP 模型（約 106 MB）"),
                semanticControl()),
            row(String(localized: "對收藏提問"), String(localized: "在搜尋框輸入問句後按 Return，或對 Siri 說 Ask Wunder"),
                status(asking, ready: String(localized: "Apple Intelligence 可用"), missing: String(localized: "需要 Apple Intelligence"))),
            row(String(localized: "中文描述"), String(localized: "用中文描述找圖，需要系統的中文 → 英文翻譯語言"), chinese),
        ]
    }

    private func privacyRows() -> [NSView] {
        let spotlight = PillSwitch(on: Self.spotlightEnabled) { [weak self] on in
            UserDefaults.standard.set(on, forKey: Self.spotlightKey)
            self?.onSpotlightChanged?(on)
        }
        spotlight.setAccessibilityLabel(String(localized: "在 Spotlight 顯示收藏"))
        return [
            row(String(localized: "在 Spotlight 顯示收藏"), String(localized: "只放標題、網站與主題，不放文字內容"), spotlight),
            note(String(localized: "圖中文字、物件、相似度與名字的辨識，都在這台 Mac 上完成，不會上傳任何內容。")),
        ]
    }

    private func about() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: "Wunder")
        name.font = Typography.display(26) ?? .systemFont(ofSize: 26, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let detail = NSTextField(labelWithString: String(localized: "版本 \(version)"))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let tagline = NSTextField(wrappingLabelWithString: String(localized: "收進來就好，不必整理。看到喜歡的東西就收，系統負責理解、搜尋與重新發現。"))
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        let updateRow = NSStackView()
        updateRow.spacing = 10
        if let release = update() {
            updateRow.addArrangedSubview(PillButton(String(localized: "下載新版本 \(release.version)")) { NSWorkspace.shared.open(release.page) })
        } else {
            updateRow.addArrangedSubview(PillButton(String(localized: "檢查更新")) { [weak self] in self?.onCheckUpdate?() })
            if updateResult == false {
                let latest = NSTextField(labelWithString: String(localized: "已經是最新版本"))
                latest.font = .systemFont(ofSize: 12)
                latest.textColor = .secondaryLabelColor
                updateRow.addArrangedSubview(latest)
            }
        }
        let stack = NSStackView(views: [icon, name, detail, tagline, updateRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(16, after: tagline)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        return stack
    }

    // MARK: Pieces

    /// One setting: its name and what it does on the left, the control at the
    /// right, a hairline under it.
    /// One setting: its name and what it does, the control beside them, a
    /// hairline under it. Every row is at least the same height with the same
    /// room around it; a wide control (the colour swatches) goes under the
    /// words instead of squeezing them.
    private func row(_ title: String, _ detail: String, _ control: NSView) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13.5, weight: .medium)
        let about = NSTextField(wrappingLabelWithString: detail)
        about.font = .systemFont(ofSize: 11.5)
        about.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, about])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let wide = control.fittingSize.width > Self.besideLimit
        let row = NSStackView()
        if wide {
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 12
            row.addArrangedSubview(text)
            row.addArrangedSubview(control)
            about.preferredMaxLayoutWidth = Self.textWidth + Self.besideLimit
        } else {
            row.addView(text, in: .leading)
            row.addView(control, in: .trailing)
            row.alignment = .centerY
            row.spacing = 24
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // The words keep their width; the row grows taller instead.
            about.preferredMaxLayoutWidth = Self.textWidth
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.textWidth).isActive = true
        }
        row.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight).isActive = true
        let line = NSBox()
        line.boxType = .separator
        let box = NSStackView(views: [row, line])
        box.orientation = .vertical
        box.spacing = 0
        row.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        line.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        rows.append(row)
        return box
    }

    /// Every row's height, as laid out (tests).
    var rowHeightsForTest: [CGFloat] {
        window?.contentView?.layoutSubtreeIfNeeded()
        return rows.map(\.frame.height)
    }
    private var rows: [NSView] = []

    /// Room for the words of a row, and how wide a control can be beside them.
    private static let textWidth: CGFloat = 300
    private static let besideLimit: CGFloat = 220
    private static let rowHeight: CGFloat = 68

    private func note(_ text: String) -> NSView {
        let n = NSTextField(wrappingLabelWithString: text)
        n.font = .systemFont(ofSize: 11.5)
        n.textColor = .secondaryLabelColor
        let box = NSStackView(views: [n])
        box.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        return box
    }

    private func semanticControl() -> NSView {
        if semanticReady() { return status(true, ready: String(localized: "已安裝"), missing: "") }
        switch semanticState() {
        case .downloading(let done):
            return status(false, ready: "", missing: String(localized: "正在下載… \(Int(done * 100))%"))
        case .failed:
            return PillButton(String(localized: "再試一次")) { [weak self] in self?.onInstallSemantic?() }
        case .idle:
            return PillButton(String(localized: "下載")) { [weak self] in self?.onInstallSemantic?() }
        }
    }

    private func status(_ ok: Bool, ready: String, missing: String) -> NSView {
        let t = NSTextField(labelWithString: (ok ? "● " : "○ ") + (ok ? ready : missing))
        t.font = .systemFont(ofSize: 12)
        t.textColor = ok ? .systemGreen : .secondaryLabelColor
        return t
    }

    @objc private func languagePicked(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let l = AppLanguage(rawValue: raw) else { return }
        AppLanguage.save(l)
        show(.general)
    }

    @objc private func appearancePicked(_ sender: NSPopUpButton) {
        AppAppearance.apply(AppAppearance.allCases[max(0, sender.indexOfSelectedItem)])
    }

    // Tests.
    func showForTest(_ tab: Tab) { show(tab) }
}

/// A section in the settings' sidebar: icon and name, filled with the accent when chosen.
@MainActor
private final class TabRow: NSView {
    private let action: () -> Void

    init(_ title: String, icon: Reicon, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let image = NSImageView(image: Icon.optical(icon, size: 16))
        image.contentTintColor = selected ? .white : .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .white : .labelColor
        for v in [image, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if selected { layer?.backgroundColor = NSColor.accent.cgColor }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// One accent to choose: a disc of the colour, ringed when chosen, its name under it.
@MainActor
private final class Swatch: NSView {
    private let action: () -> Void

    init(_ accent: Accent, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let disc = NSView()
        disc.wantsLayer = true
        disc.layer?.cornerRadius = 13
        disc.layer?.masksToBounds = true
        if accent == .system {
            // The system's choice: a wheel of every colour, as in System Settings.
            let wheel = CAGradientLayer()
            wheel.type = .conic
            wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
            wheel.endPoint = CGPoint(x: 0.5, y: 0)
            wheel.colors = [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                            .systemPurple, .systemPink, .systemRed].map(\.cgColor)
            wheel.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
            disc.layer?.addSublayer(wheel)
        } else {
            disc.layer?.backgroundColor = accent.color.cgColor
        }
        let ring = NSView()
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 17
        ring.layer?.borderWidth = selected ? 2 : 0
        ring.layer?.borderColor = (accent == .system ? NSColor.controlAccentColor : accent.color).cgColor
        let name = NSTextField(labelWithString: accent.title)
        // Only the chosen one says its name, as in System Settings; the rest on hover.
        name.font = .systemFont(ofSize: 10.5)
        name.textColor = .secondaryLabelColor
        name.isHidden = !selected
        for v in [ring, disc, name] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 34),
            ring.heightAnchor.constraint(equalToConstant: 34),
            disc.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 26),
            disc.heightAnchor.constraint(equalToConstant: 26),
            name.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 4),
            name.centerXAnchor.constraint(equalTo: centerXAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = accent.title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accent.title)
        setAccessibilityValue(selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// A rounded button tinted with the accent, as Flione's.
@MainActor
final class PillButton: NSButton {
    private let run: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.accent.withAlphaComponent(0.14).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.accent,
        ])
        target = self
        self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: intrinsicContentSize.width + 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// A switch that keeps its colour when the window isn't in front (the
/// system's goes grey): a capsule filled with the accent when on.
@MainActor
final class PillSwitch: NSView {
    private let knob = CALayer()
    private let changed: (Bool) -> Void
    private(set) var isOn: Bool

    init(on: Bool, changed: @escaping (Bool) -> Void) {
        isOn = on
        self.changed = changed
        super.init(frame: NSRect(x: 0, y: 0, width: 42, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 12
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = 10
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knob)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 42).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        update(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        layer?.backgroundColor = isOn ? NSColor.accent.cgColor : resolved(NSColor.labelColor.withAlphaComponent(0.18))
        knob.frame = CGRect(x: isOn ? 20 : 2, y: 2, width: 20, height: 20)
        CATransaction.commit()
        setAccessibilityValue(isOn)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        update(animated: true)
        changed(isOn)
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
        title = String(localized: "按下組合鍵…")
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
