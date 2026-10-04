import AppKit

/// The cabinet before the first curiosity: not an empty list, a beginning.
/// What this place is, and the three ways in.
@MainActor
final class EmptyCabinetView: NSView {
    var onImportAtlas: (() -> Void)?
    /// Things dropped on the welcome page are collected like anywhere else.
    var onDrop: ((NSPasteboard) -> Bool)?
    private var atlasButton: NSButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
        build()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private func serif(_ size: CGFloat) -> NSFont {
        Typography.display(size) ?? .systemFont(ofSize: size)
    }

    private func build() {
        let icon = NSImageView(image: Icon.image(.cabinet, weight: .outline, size: 56))
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "珍奇室")
        title.font = serif(34)
        let tagline = NSTextField(labelWithString: "Collect without organizing.")
        tagline.font = serif(16)
        tagline.textColor = .secondaryLabelColor

        let capture = CaptureController.captureShortcut.display
        let ways = NSStackView(views: [
            way(.clipboard, "看到喜歡的東西，按 \(capture)", "圖片、網址、文字；在瀏覽器裡直接收目前的頁面"),
            way(.inboxIn, "把東西拖進這個視窗", "檔案、資料夾、圖片、連結都可以，或拖到 Dock 上的 icon"),
            way(.share, "在任何 app 的分享選單選 Wunderkammer", "不用想要放哪裡，系統會替你整理"),
        ])
        ways.orientation = .vertical
        ways.alignment = .leading
        ways.spacing = 16

        let stack = NSStackView(views: [icon, title, tagline, ways])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(36, after: tagline)

        if let count = Self.atlasCount(), count > 0 {
            let b = ClosureButton(title: "從 Atlas 帶進 \(count) 件") { [weak self] in self?.onImportAtlas?() }
            b.bezelStyle = .rounded
            b.controlSize = .large
            stack.addArrangedSubview(b)
            stack.setCustomSpacing(30, after: ways)
            atlasButton = b
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    private func way(_ icon: Reicon, _ title: String, _ detail: String) -> NSView {
        let image = NSImageView(image: Icon.image(icon, size: 20))
        image.contentTintColor = .secondaryLabelColor
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 14, weight: .medium)
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 12)
        d.textColor = .secondaryLabelColor
        let text = NSStackView(views: [t, d])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [image, text])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    /// How many originals an Atlas library on this Mac holds, if any.
    static func atlasCount() -> Int? {
        let originals = Library.atlasRoot.appendingPathComponent("originals")
        return (try? FileManager.default.contentsOfDirectory(atPath: originals.path))?.filter { !$0.hasPrefix(".") }.count
    }
}
