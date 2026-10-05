import AppKit

/// The one colour the app is allowed to choose: the accent. It marks what's
/// chosen and what's active (the space you're in, a selection, a dropped-on
/// target) and nothing else; the rest of the palette stays the system's.
/// The system's own accent, or one of a set of vivid colours, each named for
/// the designer or artist it calls to mind; Rams orange by default.
enum Accent: String, CaseIterable, Sendable {
    case system, orange, red, pink, purple, blue, glacier, green

    var title: String {
        switch self {
        case .system: String(localized: "跟隨系統")
        case .orange: String(localized: "拉姆斯橘")
        case .red: String(localized: "馬諦斯紅")
        case .pink: String(localized: "巴拉岡粉")
        case .purple: String(localized: "鳶尾紫")
        case .blue: String(localized: "克萊因藍")
        case .glacier: String(localized: "霍克尼藍")
        case .green: String(localized: "莫內綠")
        }
    }

    /// Braun's orange, Matisse's red studio, Barragán's pink walls, Van Gogh's
    /// irises, Klein's blue, Hockney's pools, Monet's bridge at Giverny.
    var color: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .orange: Self.rgb(0xED3F1C)
        case .red: Self.rgb(0xD21F3C)
        case .pink: Self.rgb(0xE5508F)
        case .purple: Self.rgb(0x7C5CF5)
        case .blue: Self.rgb(0x2147E0)
        case .glacier: Self.rgb(0x23A6DA)
        case .green: Self.rgb(0x2AA572)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Choices that are gone, mapped to their nearest.
    private static func migrated(_ raw: String) -> Accent? {
        Accent(rawValue: raw) ?? ["vermilion": .red, "amber": .orange, "yellow": .orange, "sky": .glacier,
                                  "ultramarine": .blue, "graphite": .system][raw]
    }

    private static let key = "accent"
    nonisolated(unsafe) private(set) static var current: Accent =
        UserDefaults.standard.string(forKey: key).flatMap(migrated) ?? .orange

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
