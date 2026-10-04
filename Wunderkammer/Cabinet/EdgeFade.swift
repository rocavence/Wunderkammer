import AppKit

/// Content fading out under the glass toolbar, so tiles scrolling up never sit
/// hard against its controls. Never takes a click.
@MainActor
final class EdgeFade: NSView {
    private let gradient = CAGradientLayer()
    /// Fades towards the right edge instead (a row that carries on).
    var towardsRight = false { didSet { render() } }

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
        if towardsRight {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.colors = [bg.copy(alpha: 0)!, bg.copy(alpha: 0.95)!]
            gradient.locations = [0, 1]
        } else {
            // The wall's own top shade, for every view: the content shows
            // through behind the bar, darkening into it.
            gradient.colors = [bg.copy(alpha: 0.9)!, bg.copy(alpha: 0)!]
            gradient.locations = [0, 1]
        }
        CATransaction.commit()
    }
}
