import AppKit

/// Content fading out under the glass toolbar, so tiles scrolling up never sit
/// hard against its controls. Never takes a click.
@MainActor
final class EdgeFade: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private func render() {
        let bg = resolved(.windowBackgroundColor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        gradient.colors = [bg.copy(alpha: 0.96)!, bg.copy(alpha: 0.8)!, bg.copy(alpha: 0)!]
        gradient.locations = [0, 0.55, 1]
        CATransaction.commit()
    }
}
