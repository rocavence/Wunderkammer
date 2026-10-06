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
    /// AI assistants let in (true) or shut out.
    var onMCPChanged: ((Bool) -> Void)?
    var mcpLastUse: () -> (client: String, at: Date)? = { nil }
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
        case general, collecting, understanding, privacy, ai, about

        var title: String {
            switch self {
            case .general: String(localized: "一般")
            case .collecting: String(localized: "收藏")
            case .understanding: String(localized: "搜尋與理解")
            case .privacy: String(localized: "隱私")
            case .ai: String(localized: "AI 控制")
            case .about: String(localized: "關於")
            }
        }

        var icon: Reicon {
            switch self {
            case .general: .setting
            case .collecting: .inboxIn
            case .understanding: .sparkles
            case .privacy: .shield
            case .ai: .magicWand
            case .about: .infoCircle
            }
        }
    }

    private var tab: Tab = .general
    private let sidebar = NSStackView()
    private let heading = NSTextField(labelWithString: "")
    private let page = FlippedView()
    private let scroll = NSScrollView()

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
        // The AI page's status follows assistants as they call.
        NotificationCenter.default.addObserver(forName: MCPHost.didUse, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.tab == .ai { self?.refresh() } }
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
        rowLines = []
        let rows: [NSView]
        switch tab {
        case .general: rows = generalRows()
        case .collecting: rows = collectingRows()
        case .understanding: rows = understandingRows()
        case .privacy: rows = privacyRows()
        case .ai: rows = aiRows()
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
        // A note closes the page: no hairline between it and the last setting.
        if rows.last is Note { rowLines.last?.isHidden = true }
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

    /// AI control, as Flione's: let assistants in, let them collect too, how
    /// they're doing, and what to paste into each kind of assistant.
    private func aiRows() -> [NSView] {
        let allow = PillSwitch(on: MCP.isEnabled) { [weak self] on in
            UserDefaults.standard.set(on, forKey: MCP.enabledKey)
            self?.onMCPChanged?(on)
            self?.show(.ai)
        }
        allow.setAccessibilityLabel(String(localized: "讓 AI 助手使用 Wunder"))
        var rows = [row(String(localized: "讓 AI 助手使用 Wunder"),
                        String(localized: "Claude、Cursor 等支援 MCP 的 App 可以搜尋、瀏覽與讀取目前的展室，也能隨機挑一件或提問。"),
                        allow)]
        if MCP.isEnabled {
            let write = PillSwitch(on: MCP.canWrite) { on in UserDefaults.standard.set(on, forKey: MCP.writeKey) }
            write.setAccessibilityLabel(String(localized: "也讓它收藏"))
            rows.append(row(String(localized: "也讓它收藏"), String(localized: "允許 AI 助手把連結、文字和檔案收進來，或加進釘選版。"), write))
            rows.append(row(String(localized: "狀態"), mcpStatus(), NSView()))
            let path = Bundle.main.executablePath ?? ""
            rows.append(setup(String(localized: "Claude Desktop、Cursor 等 App"),
                              String(localized: "加進 App 的 MCP 伺服器設定。Claude Desktop：設定 → 開發者 → 編輯設定檔。"),
                              MCP.settingsSnippet))
            rows.append(setup(String(localized: "Claude Code"), String(localized: "在終端機執行這一行。"),
                              "claude mcp add wunder -- \"\(path)\" --mcp"))
        }
        let footnote = Self.label(String(localized: "只有這台 Mac 上的 App 能連線，不經過網路。"), size: 11, color: .tertiaryLabelColor)
        let box = NSStackView(views: [footnote])
        box.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
        rows.append(box)
        return rows
    }

    private func mcpStatus() -> String {
        guard let use = mcpLastUse() else { return String(localized: "等 AI 助手來連線。需要時，AI 助手會自己打開 Wunder。") }
        let time = use.at.formatted(date: Calendar.current.isDateInToday(use.at) ? .omitted : .abbreviated, time: .shortened)
        let who = use.client.isEmpty ? String(localized: "AI 助手") : use.client
        return String(localized: "\(who) 上次使用：\(time)")
    }

    /// How to connect one kind of assistant: what to do, a Copy button, and
    /// the text itself in a box you can select from.
    private func setup(_ title: String, _ detail: String, _ code: String) -> NSView {
        let copy = Self.copyButton(String(localized: "拷貝"), code)
        let head = row(title, detail, copy)
        let text = NSTextField(wrappingLabelWithString: code)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = Self.rowWidth - 24
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.cornerCurve = .continuous
        well.layer?.borderWidth = 1
        well.layer?.borderColor = NSColor.separatorColor.cgColor
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        text.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: well.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -12),
            text.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -12),
        ])
        // The code sits between the row and its hairline.
        if let stack = head as? NSStackView, stack.arrangedSubviews.count == 2 {
            stack.insertArrangedSubview(well, at: 1)
            stack.setCustomSpacing(16, after: well)
            well.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            (stack.arrangedSubviews.first as? NSStackView)?.edgeInsets.bottom = 12
        }
        return head
    }

    /// Copies the text; says so on the button for a moment.
    private static func copyButton(_ title: String, _ text: String) -> PillButton {
        let box = WeakBox<PillButton>()
        let button = PillButton(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            box.value?.setLabel(String(localized: "已拷貝"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { box.value?.setLabel(title) }
        }
        box.value = button
        return button
    }

    /// As Flione's About: who made it, the app and its version, then why it
    /// exists — the trouble it answers and how — its name, and thanks.
    private func about() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = Self.label("Wunder", size: 14, weight: .medium)
        let tagline = Self.label(String(localized: "收進來就好，不必整理。"), size: 13, color: .secondaryLabelColor)
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
        let app = NSStackView(views: [icon, words])
        app.alignment = .top
        app.spacing = 16
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let page = NSStackView(views: [
            AuthorCard(),
            app,
            section(String(localized: "為什麼做 Wunder"), [
                String(localized: "同類的 App 我用過不少，很多其實都不便宜。但用下來就是覺得不好用，而且花最多時間的竟然是整理！"),
                String(localized: "Wunder 你大概也不會天天打開，這樣剛好，它會把你的「珍奇」分門別類擺好掛上牆，哪天想到再打開，就是一個舒服的展室，你就隨意逛逛，不整理也完全沒問題！"),
            ]),
            section(String(localized: "Wunder 怎麼解決"), leads: true, [
                String(localized: "收進來就好。按快捷鍵、拖到選單列的拱門或截圖，一個動作就收好，不問要放哪裡。"),
                String(localized: "整理交給系統。依格式、分類、主題與顏色自動分好；記不得檔名，用一句話描述也找得到。"),
                String(localized: "一切留在這台 Mac。文字、物件、相似與描述的辨識都在本機完成，不上傳、不用帳號、不用訂閱。"),
                String(localized: "讓舊收藏回來找你。漫遊、過去的今天、被遺忘的，把收過的東西一件件再帶回眼前。"),
            ]),
            section(String(localized: "名字"), [
                String(localized: "Wunderkammer 是文藝復興時期的珍奇室：書、標本、畫與地圖放在同一個房間，靠擺放與並置產生意義，而不是靠分類。Wunder 是它的簡稱，德文的「驚奇」。每個展室，都是你自己的珍奇室。"),
            ]),
            credits(),
        ])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 28
        page.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
        return page
    }

    /// A small uppercase heading and a few paragraphs, as Flione's. With
    /// `leads`, each paragraph's first sentence stands out as its point.
    private func section(_ title: String, leads: Bool = false, _ paragraphs: [String]) -> NSView {
        let stack = NSStackView(views: [Self.micro(title)] + paragraphs.map { text in
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.lineBreakStrategy = .standard
            let p = NSTextField(wrappingLabelWithString: "")
            let body = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85), .paragraphStyle: style,
            ])
            if leads, let end = text.firstIndex(where: { "。.".contains($0) }) {
                body.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor],
                                   range: NSRange(text.startIndex...end, in: text))
            }
            p.attributedStringValue = body
            p.preferredMaxLayoutWidth = Self.rowWidth
            return p
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func credits() -> NSView {
        let entries: [(String, String, String)] = [
            ("MobileCLIP", "https://github.com/apple/ml-mobileclip", String(localized: "Apple 的圖文模型，讓你用一句話找圖。")),
            ("Reicon", "https://github.com/dqev/reicon", String(localized: "介面上的圖示都來自 Reicon。")),
            ("XcodeGen", "https://github.com/yonaskolb/XcodeGen", String(localized: "產生 Xcode 專案。")),
        ]
        let stack = NSStackView(views: [Self.micro(String(localized: "致謝"))] + entries.map { name, url, detail in
            let link = NSButton(title: "", target: nil, action: nil)
            link.isBordered = false
            link.attributedTitle = NSAttributedString(string: name + " ↗", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.accent,
            ])
            link.target = ActionBox.make(link) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
            link.action = #selector(ActionBox.run)
            let words = Self.label(detail, size: 13, color: .secondaryLabelColor, wraps: true)
            words.preferredMaxLayoutWidth = Self.rowWidth
            let one = NSStackView(views: [link, words])
            one.orientation = .vertical
            one.alignment = .leading
            one.spacing = 2
            return one
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private static func micro(_ text: String) -> NSTextField {
        label(text.uppercased(), size: 10, weight: .medium, color: .secondaryLabelColor).withTracking(0.6)
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
        rowLines.append(line)
        return box
    }

    /// Every row's height, as laid out (tests).
    var rowHeightsForTest: [CGFloat] {
        window?.contentView?.layoutSubtreeIfNeeded()
        return rows.map(\.frame.height)
    }
    private var rows: [NSView] = []
    private var rowLines: [NSView] = []

    /// How wide a control can be beside the words.
    private static let besideLimit: CGFloat = 220
    private static let rowHeight: CGFloat = 68

    /// Flione's type: 28 and 19 semibold for titles, 14 medium for a
    /// setting's name, 13 for words, 11 for small print.
    static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                     tracking: CGFloat = 0, alignment: NSTextAlignment = .natural, wraps: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .standard
        // A one-line label stays one line, cut short at the end if it must.
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        style.alignment = alignment
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: tracking,
            .paragraphStyle: style,
        ])
    }

    static func label(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                      wraps: Bool = false, alignment: NSTextAlignment = .natural) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        label.attributedStringValue = text(string, size: size, weight: weight, color: color, alignment: alignment, wraps: wraps)
        return label
    }

    private func note(_ text: String) -> NSView { Note(text, width: Self.rowWidth) }

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
    func scrollToEndForTest() {
        window?.contentView?.layoutSubtreeIfNeeded()
        page.scroll(NSPoint(x: 0, y: max(0, page.frame.height - scroll.contentView.bounds.height)))
    }
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
                                                  color: selected ? .labelColor : .secondaryLabelColor, wraps: true,
                                                  alignment: .center)
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

/// A word on how a page works, under its settings: an info mark and the
/// words, on a faint rounded ground, apart from the settings themselves.
@MainActor
private final class Note: NSView {
    init(_ text: String, width: CGFloat) {
        super.init(frame: .zero)
        let mark = NSImageView(image: Icon.optical(.infoCircle, size: 14))
        mark.contentTintColor = .tertiaryLabelColor
        let words = SettingsWindowController.label(text, size: 12, color: .secondaryLabelColor, wraps: true)
        words.preferredMaxLayoutWidth = width - 14 - 8 - 28
        let ground = NSView()
        ground.wantsLayer = true
        ground.layer?.cornerRadius = 10
        ground.layer?.cornerCurve = .continuous
        ground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        for v in [ground, mark, words] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 14),
            mark.topAnchor.constraint(equalTo: words.topAnchor, constant: 1),
            words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            words.trailingAnchor.constraint(lessThanOrEqualTo: ground.trailingAnchor, constant: -14),
            words.topAnchor.constraint(equalTo: ground.topAnchor, constant: 12),
            words.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        subviews.first?.layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.04))
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
            // Behind the page, never over its words.
            g.zPosition = -1
            layer?.insertSublayer(g, at: 0)
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

private extension NSTextField {
    func withTracking(_ kern: CGFloat) -> NSTextField {
        let text = NSMutableAttributedString(attributedString: attributedStringValue)
        text.addAttribute(.kern, value: kern, range: NSRange(location: 0, length: text.length))
        attributedStringValue = text
        return self
    }
}

/// Who made it, as Flione's: a capsule with the author's picture and handle
/// that lifts a little under the pointer; a click opens their GitHub page.
/// The picture ships with the app, nothing is fetched.
@MainActor
private final class AuthorCard: NSView {
    private var hovering = false { didSet { paint() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 29
        layer?.borderWidth = 1
        let face = NSImageView(image: NSImage(named: "DeveloperAvatar") ?? NSImage())
        face.imageScaling = .scaleProportionallyUpOrDown
        face.wantsLayer = true
        face.layer?.cornerRadius = 21
        face.layer?.masksToBounds = true
        let handle = SettingsWindowController.label("@rocavence", size: 15, weight: .semibold)
        let role = SettingsWindowController.label(String(localized: "作者 · GitHub"), size: 12.5, color: .secondaryLabelColor)
        let words = NSStackView(views: [handle, role])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        for v in [face, words] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            face.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            face.centerYAnchor.constraint(equalTo: centerYAnchor),
            face.widthAnchor.constraint(equalToConstant: 42),
            face.heightAnchor.constraint(equalToConstant: 42),
            words.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 12),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel("rocavence on GitHub")
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)), let url = URL(string: "https://github.com/rocavence") {
            NSWorkspace.shared.open(url)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            layer?.borderColor = resolved(hovering ? NSColor.labelColor.withAlphaComponent(0.2) : .separatorColor)
            layer?.backgroundColor = hovering ? resolved(.controlBackgroundColor) : nil
            layer?.shadowOpacity = hovering ? 0.3 : 0
            layer?.shadowRadius = 16
            layer?.shadowOffset = CGSize(width: 0, height: -8)
            layer?.transform = hovering ? CATransform3DMakeTranslation(0, 2, 0) : CATransform3DIdentity
        }
    }
}

private final class WeakBox<T: AnyObject> { weak var value: T? }
