import AppKit

enum Typography {
    /// The display face for titles: the system's own sans (SF, PingFang for
    /// Chinese), a step heavier than body text. No serif anywhere.
    static func display(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont? {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}
