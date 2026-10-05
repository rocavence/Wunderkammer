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
    private let scroll = FadingScrollView()

    /// Flione's settings card: 900 × 600, 32 all round, a 184-wide column of
    /// sections, a hairline, then the page 24 in from it.
    private static let size = NSSize(width: 900, height: 600)
    private static let margin: CGFloat = 32
    private static let sidebarWidth: CGFloat = 184
    private static let gutter: CGFloat = 24
    /// Room for a row: the card less the column, the hairline and the margins.
    private static let rowWidth = size.width - margin * 2 - sidebarWidth - 16 - 1 - gutter

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height),
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
        let title = NSTextField(labelWithString: String(localized: "設定"))
        title.attributedStringValue = Self.text(title.stringValue, size: 28, weight: .semibold, tracking: -0.6)
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = page
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let root = SettingsBackground()
        for v in [title, sidebar, line, heading, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        // The traffic lights sit in the top margin, so the columns start a little lower.
        let top = Self.margin + 8
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: top),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin + 8),
            sidebar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            line.topAnchor.constraint(equalTo: root.topAnchor),
            line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            line.widthAnchor.constraint(equalToConstant: 1),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: top),
            heading.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: Self.gutter),
            heading.heightAnchor.constraint(equalToConstant: 36),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: Self.gutter),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.margin),
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
        heading.attributedStringValue = Self.text(tab.title, size: 19, weight: .semibold, tracking: -0.3)
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
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.margin, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    // MARK: Sections

    private func generalRows() -> [NSView] {
        // Language: takes effect on the next launch, with a restart offered.
        let language = PillMenu(AppLanguage.allCases.map(\.title),
                                selected: AppLanguage.allCases.firstIndex(of: AppLanguage.saved) ?? 0) { [weak self] i in
            AppLanguage.save(AppLanguage.allCases[i])
            self?.show(.general)
        }
        let restart = PillButton(String(localized: "重新開啟")) { AppLanguage.relaunch() }
        restart.isHidden = AppLanguage.saved == AppLanguage.launched
        let languageControl = NSStackView(views: [restart, language])
        languageControl.spacing = 8
        let pending = AppLanguage.saved != AppLanguage.launched

        let look = PillMenu(AppAppearance.allCases.map(\.title),
                            selected: AppAppearance.allCases.firstIndex(of: AppAppearance.saved) ?? 0) { i in
            AppAppearance.apply(AppAppearance.allCases[i])
        }

        let swatches = NSStackView(views: Accent.allCases.map { a in
            Swatch(a, selected: a == Accent.current) { Accent.apply(a) }
        })
        swatches.spacing = 10
        swatches.alignment = .top
        return [
            row(String(localized: "語言"),
                pending ? String(localized: "重新開啟 Wunder 後換成新的語言。") : String(localized: "選單、按鈕與訊息使用的語言。"),
                languageControl),
            row(String(localized: "外觀"), String(localized: "淺色、深色，或跟著系統切換。"), look),
            row(String(localized: "重點色"), String(localized: "標示選取、所在的空間與拖放的目標。"),
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
            row(String(localized: "收藏剪貼簿或目前頁面"), String(localized: "先收剛拷貝的東西，沒有就收瀏覽器正在看的頁面。"), capture),
            row(String(localized: "截圖收藏"), String(localized: "選範圍或視窗，截好直接收進來。"), shot),
            note(String(localized: "點一下快捷鍵，再按下新的組合鍵。Esc 取消，Delete 還原預設。\n也可以把任何東西拖到選單列的拱門。")),
        ]
    }

    private func understandingRows() -> [NSView] {
        var asking = false
        if #available(macOS 26.0, *) { asking = Asker.isAvailable }
        let chinese = PillButton(String(localized: "下載…")) { [weak self] in self?.onEnableChinese?() }
        return [
            row(String(localized: "用描述找圖"), String(localized: "用一句話找圖，例如「a cat at a dinner table」。\n模型在這台 Mac 上執行，約 106 MB。"),
                semanticControl()),
            row(String(localized: "對收藏提問"), String(localized: "在搜尋框輸入問句後按 Return，或對 Siri 說「Ask Wunder」。"),
                status(asking, ready: String(localized: "Apple Intelligence 可用"), missing: String(localized: "需要 Apple Intelligence"))),
            row(String(localized: "中文描述"), String(localized: "用中文描述找圖，需要系統的「中文 → 英文」翻譯語言。"), chinese),
        ]
    }

    private func privacyRows() -> [NSView] {
        let spotlight = PillSwitch(on: Self.spotlightEnabled) { [weak self] on in
            UserDefaults.standard.set(on, forKey: Self.spotlightKey)
            self?.onSpotlightChanged?(on)
        }
        spotlight.setAccessibilityLabel(String(localized: "在 Spotlight 顯示收藏"))
        return [
            row(String(localized: "在 Spotlight 顯示收藏"), String(localized: "只放標題、網站與主題，不放文字內容。"), spotlight),
            note(String(localized: "圖中文字、物件、相似度與名字的辨識，都在這台 Mac 上完成，不會上傳任何內容。")),
        ]
    }

    private func about() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = Self.label("Wunder", size: 14, weight: .medium)
        let tagline = Self.label(String(localized: "收進來就好，不必整理。看到喜歡的東西就收，系統負責理解、搜尋與重新發現。"),
                                 size: 13, color: .secondaryLabelColor, wraps: true)
        tagline.preferredMaxLayoutWidth = Self.rowWidth - 64 - 16
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let detail = Self.label(String(localized: "版本 \(version)"), size: 11, color: .tertiaryLabelColor)
        let updateRow = NSStackView()
        updateRow.spacing = 8
        if let release = update() {
            updateRow.addArrangedSubview(PillButton(String(localized: "下載新版本 \(release.version)")) { NSWorkspace.shared.open(release.page) })
        } else {
            updateRow.addArrangedSubview(PillButton(String(localized: "檢查更新")) { [weak self] in self?.onCheckUpdate?() })
            if updateResult == false {
                updateRow.addArrangedSubview(Self.label(String(localized: "已經是最新版本"), size: 11, color: .secondaryLabelColor))
            }
        }
        let words = NSStackView(views: [name, tagline, detail, updateRow])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        words.setCustomSpacing(10, after: detail)
        let stack = NSStackView(views: [icon, words])
        stack.alignment = .top
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return stack
    }

    // MARK: Pieces

    /// One setting, as Flione's: its name and what it does on the left, the
    /// control at the right, 16 above and below, a hairline under it. A wide
    /// control (the colour swatches) goes under the words instead.
    private func row(_ title: String, _ detail: String, _ control: NSView) -> NSView {
        let name = Self.label(title, size: 14, weight: .medium)
        let about = Self.label(detail, size: 13, color: .secondaryLabelColor, wraps: true)
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
            about.preferredMaxLayoutWidth = Self.rowWidth
        } else {
            row.addView(text, in: .leading)
            row.addView(control, in: .trailing)
            row.alignment = .centerY
            row.spacing = Self.gutter
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            about.preferredMaxLayoutWidth = Self.rowWidth - control.fittingSize.width - row.spacing
        }
        row.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight).isActive = true
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
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

    /// How wide a control can be beside the words.
    private static let besideLimit: CGFloat = 220
    private static let rowHeight: CGFloat = 68

    /// Flione's type: 28 and 19 semibold for titles, 14 medium for a
    /// setting's name, 13 for words, 11 for small print.
    static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor, tracking: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .standard
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: tracking,
            .paragraphStyle: style,
        ])
    }

    static func label(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        label.attributedStringValue = text(string, size: size, weight: weight, color: color)
        return label
    }

    private func note(_ text: String) -> NSView {
        let n = Self.label(text, size: 13, color: .secondaryLabelColor, wraps: true)
        n.preferredMaxLayoutWidth = Self.rowWidth
        let box = NSStackView(views: [n])
        box.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
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
        Self.label((ok ? "● " : "○ ") + (ok ? ready : missing), size: 13, weight: .medium,
                   color: ok ? .systemGreen : .secondaryLabelColor)
    }

    // Tests.
    func showForTest(_ tab: Tab) { show(tab) }
}

/// A section in the settings' sidebar, as Flione's: icon and name, filled
/// with the accent when chosen, a faint fill under the pointer.
@MainActor
private final class TabRow: NSView {
    private let action: () -> Void
    private let selected: Bool

    init(_ title: String, icon: Reicon, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let ink = selected ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.82)
        let image = NSImageView(image: Icon.optical(icon, size: 16))
        image.contentTintColor = ink
        let label = SettingsWindowController.label(title, size: 13, weight: selected ? .medium : .regular, color: ink)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [image, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if selected { layer?.backgroundColor = NSColor.accent.cgColor }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        if !selected { layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.06)) }
    }

    override func mouseExited(with event: NSEvent) {
        if !selected { layer?.backgroundColor = nil }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// One accent to choose, as Flione's theme swatches: a disc of the colour,
/// ringed when chosen, its name under it.
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
        let name = SettingsWindowController.label(accent.title, size: selected ? 12 : 11, weight: selected ? .medium : .regular,
                                                  color: selected ? .labelColor : .secondaryLabelColor, wraps: true)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.preferredMaxLayoutWidth = Self.width
        for v in [ring, disc, name] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 34),
            ring.heightAnchor.constraint(equalToConstant: 34),
            disc.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 26),
            disc.heightAnchor.constraint(equalToConstant: 26),
            name.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 6),
            name.widthAnchor.constraint(equalToConstant: Self.width),
            name.centerXAnchor.constraint(equalTo: centerXAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = accent.title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accent.title)
        setAccessibilityValue(selected)
    }

    /// Wide enough for a two-word name on two lines; eight fit a row.
    static let width: CGFloat = 64

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// A rounded button tinted with the accent, as Flione's: 32 high, a faint
/// accent fill that deepens under the pointer.
@MainActor
class PillButton: NSButton {
    private let run: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        setLabel(title)
        target = self
        self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        tint(0.12)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The words on it, in the accent.
    func setLabel(_ title: String) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.accent,
        ])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 32, height: 32)
    }

    private func tint(_ alpha: CGFloat) { layer?.backgroundColor = NSColor.accent.withAlphaComponent(alpha).cgColor }
    override func mouseEntered(with event: NSEvent) { tint(0.2) }
    override func mouseExited(with event: NSEvent) { tint(0.12) }

    @objc private func fire() { run() }
}

/// A choice from a list, as Flione's menu: the current one and a chevron on a
/// pill; a click opens the list with the current one ticked.
@MainActor
final class PillMenu: PillButton {
    init(_ titles: [String], selected: Int, picked: @escaping (Int) -> Void) {
        let menu = NSMenu()
        for (i, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(ActionBox.run), keyEquivalent: "")
            item.target = ActionBox.make(item) { picked(i) }
            item.state = i == selected ? .on : .off
            menu.addItem(item)
        }
        weak var weakSelf: PillMenu?
        super.init(titles[selected]) {
            guard let button = weakSelf else { return }
            menu.popUp(positioning: menu.item(at: selected), at: NSPoint(x: 6, y: button.bounds.height - 9), in: button)
        }
        weakSelf = self
        // The chevron goes into the words, so both sit centred on the pill.
        let chevron = NSTextAttachment()
        let glyph = Icon.optical(.chevronDown, size: 11)
        chevron.image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor.accent.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        chevron.bounds = CGRect(x: 0, y: -1, width: glyph.size.width, height: glyph.size.height)
        let title = NSMutableAttributedString(attributedString: attributedTitle)
        title.append(NSAttributedString(string: "  "))
        title.append(NSAttributedString(attachment: chevron))
        attributedTitle = title
        invalidateIntrinsicContentSize()
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError() }
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
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        show(current.display)
        target = self
        action = #selector(record)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The keys on a pill like the other controls; in the accent while it listens.
    private func show(_ text: String, recording: Bool = false) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: recording ? NSColor.accent : NSColor.labelColor,
        ])
        layer?.backgroundColor = recording ? NSColor.accent.withAlphaComponent(0.12).cgColor
                                           : resolved(NSColor.labelColor.withAlphaComponent(0.06))
    }

    /// The field currently waiting for a combination (never more than one).
    static weak var active: ShortcutField?

    @objc private func record() {
        guard monitor == nil else { return }
        Self.active?.cancel()
        Self.active = self
        show(String(localized: "按下組合鍵…"), recording: true)
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
        show(current.display)
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
        show(current.display)
        onRecording?(false)
        onChange?()
    }
}

/// The card's ground, as Flione's: a faint glow of the accent from the top and
/// of violet from the bottom right.
@MainActor
private final class SettingsBackground: NSView {
    private let top = CAGradientLayer()
    private let corner = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for g in [top, corner] {
            g.type = .radial
            layer?.addSublayer(g)
        }
        NotificationCenter.default.addObserver(forName: Accent.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = resolved(.windowBackgroundColor)
        top.colors = [NSColor.accent.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        corner.colors = [Accent.purple.color.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
    }

    override func layout() {
        super.layout()
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        for (g, centre, radius) in [(top, CGPoint(x: 0.5, y: 1), 420.0), (corner, CGPoint(x: 1, y: 0), 360.0)] {
            g.frame = bounds
            g.startPoint = centre
            g.endPoint = CGPoint(x: centre.x + radius / w, y: centre.y + (centre.y > 0.5 ? -1 : 1) * radius / h)
        }
    }
}

/// A scroll view whose content fades out over its last 28 points, in place
/// of a scroller, as Flione's.
@MainActor
private final class FadingScrollView: NSScrollView {
    private let fade = CAGradientLayer()

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.mask = fade
        fade.frame = bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.locations = [0, NSNumber(value: Double(28 / max(bounds.height, 28))), 1]
    }
}
