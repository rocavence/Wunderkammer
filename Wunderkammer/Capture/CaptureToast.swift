import AppKit

/// The confirmation after a capture: a small card near the top of the screen
/// that never takes focus, never needs an answer, and fades by itself.
@MainActor
final class CaptureToast {
    private(set) var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, detail: String?, image: NSImage?) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.state = .active
        content.blendingMode = .behindWindow
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true

        let thumb = NSImageView()
        thumb.image = image
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.isHidden = image == nil

        let label = NSTextField(labelWithString: title)
        label.font = Typography.display(15) ?? .systemFont(ofSize: 15)
        label.textColor = .labelColor
        // One line, whatever was collected: a note's line breaks run together.
        let oneLine = (detail ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let sub = NSTextField(labelWithString: oneLine)
        sub.maximumNumberOfLines = 1
        sub.cell?.usesSingleLineMode = true
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.isHidden = detail == nil

        let text = NSStackView(views: [label, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [thumb, text])
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 44),
            thumb.heightAnchor.constraint(equalToConstant: 44),
            sub.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        let size = content.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let target = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14, width: size.width, height: size.height)
        panel.setFrame(target.offsetBy(dx: 0, dy: 8), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }
}
