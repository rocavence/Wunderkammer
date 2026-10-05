import AppKit

/// The one colour the app is allowed to choose: the accent. It marks what's
/// chosen and what's active (the space you're in, a selection, a dropped-on
/// target) and nothing else; the rest of the palette stays the system's.
/// The system's own accent, or one of five drawn from the arch in the icon;
/// orange by default.
enum Accent: String, CaseIterable, Sendable {
    case system, orange, vermilion, amber, sky, ultramarine

    var hex: UInt32 {
        switch self {
        case .system: 0x007AFF
        case .orange: 0xFE6911
        case .vermilion: 0xF2361A
        case .amber: 0xF5A021
        case .sky: 0x2AA6F2
        case .ultramarine: 0x1450F5
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "跟隨系統")
        case .orange: String(localized: "橘")
        case .vermilion: String(localized: "朱紅")
        case .amber: String(localized: "琥珀")
        case .sky: String(localized: "天藍")
        case .ultramarine: String(localized: "群青")
        }
    }

    var color: NSColor {
        if self == .system { return .controlAccentColor }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static let key = "accent"
    nonisolated(unsafe) private(set) static var current: Accent =
        UserDefaults.standard.string(forKey: key).flatMap(Accent.init) ?? .orange

    static let didChange = Notification.Name("AccentDidChange")

    static func apply(_ accent: Accent) {
        guard accent != current else { return }
        current = accent
        UserDefaults.standard.set(accent.rawValue, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

extension NSColor {
    /// The chosen accent, read whenever it's drawn.
    static let accent = NSColor(name: "WunderkammerAccent") { _ in Accent.current.color }
}
