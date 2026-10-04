import AppKit

/// The answer to a question, floating over the top of the cabinet; the
/// cabinet below shows what the answer is about.
@MainActor
final class AnswerBanner: NSVisualEffectView {
    var onClose: (() -> Void)?

    private let question = NSTextField(labelWithString: "")
    private let answer = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let close = NSButton()

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        question.font = .systemFont(ofSize: 12)
        question.textColor = .secondaryLabelColor
        question.lineBreakMode = .byTruncatingTail
        let size: CGFloat = 15
        answer.font = Typography.display(size)
            ?? .systemFont(ofSize: size)
        answer.maximumNumberOfLines = 6
        answer.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        close.image = Icon.image(.x)
        close.isBordered = false
        close.toolTip = "關閉回答"
        close.target = self
        close.action = #selector(closeTapped)
        close.setAccessibilityLabel("關閉回答")

        for v in [question, answer, spinner, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        answer.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            question.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            question.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            question.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: answer.topAnchor, constant: 9),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            answer.topAnchor.constraint(equalTo: question.bottomAnchor, constant: 6),
            answer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            answer.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            answer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var answerText: String { answer.stringValue }

    func thinking(about q: String) {
        question.stringValue = "問：\(q)"
        answer.stringValue = "      正在看你的收藏…"
        answer.textColor = .secondaryLabelColor
        spinner.startAnimation(nil)
    }

    func show(answer text: String, failed: Bool = false) {
        spinner.stopAnimation(nil)
        answer.stringValue = text
        answer.textColor = failed ? .secondaryLabelColor : .labelColor
    }

    @objc private func closeTapped() { onClose?() }

    /// Esc closes it, like the search it came from.
    override func cancelOperation(_ sender: Any?) { onClose?() }
}
