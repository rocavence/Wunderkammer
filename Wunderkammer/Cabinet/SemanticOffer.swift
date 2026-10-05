import AppKit

/// Shown the first time you search without the meaning-search models: an
/// offer to fetch them, then how far along they are. Sits just above the
/// view bar and never covers what was found.
@MainActor
final class SemanticOffer: NSView {
    var onDownload: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()

    init() {
        super.init(frame: .zero)
        let glass = Glass(cornerRadius: 16)
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        buttons.spacing = 6
        let row = NSStackView(views: [label, buttons])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 8)
        for v in [glass, row] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var textForTest: String { label.stringValue }

    func show(_ state: ModelInstaller.State) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .idle:
            label.stringValue = String(localized: "想用描述找圖？下載語意模型（約 106 MB），只在這台 Mac 上執行。")
            buttons.addArrangedSubview(PillButton(String(localized: "下載")) { [weak self] in self?.onDownload?() })
            buttons.addArrangedSubview(quiet(String(localized: "不用了")) { [weak self] in self?.onDismiss?() })
        case .downloading(let done):
            label.stringValue = String(localized: "正在下載語意模型… \(Int(done * 100))%")
        case .failed:
            label.stringValue = String(localized: "下載沒有完成，請確認網路後再試一次。")
            buttons.addArrangedSubview(PillButton(String(localized: "再試一次")) { [weak self] in self?.onDownload?() })
            buttons.addArrangedSubview(quiet(String(localized: "不用了")) { [weak self] in self?.onDismiss?() })
        }
    }

    private func quiet(_ title: String, _ action: @escaping () -> Void) -> NSView {
        let b = PillButton(title, action: action)
        b.layer?.backgroundColor = nil
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return b
    }
}
