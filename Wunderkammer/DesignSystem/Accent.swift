import AppKit

/// The one colour the app is allowed to choose: the accent. It marks what's
/// chosen and what's active (the space you're in, a selection, a dropped-on
/// target) and nothing else; the rest of the palette stays the system's.
/// The system's own accent, or one of a set of vivid colours drawn from
/// Flione's themes; Wunder's orange by default.
enum Accent: String, CaseIterable, Sendable {
    case system, orange, red, pink, purple, blue, glacier, green

    var title: String {
        switch self {
        case .system: String(localized: "跟隨系統")
        case .orange: String(localized: "橙色")
        case .red: String(localized: "紅色")
        case .pink: String(localized: "玫瑰色")
        case .purple: String(localized: "紫色")
        case .blue: String(localized: "藍色")
        case .glacier: String(localized: "冰川藍")
        case .green: String(localized: "翠綠")
        }
    }

    /// Vivid colours, taken from Flione's themes, with Wunder's own orange first.
    var color: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .orange: Self.rgb(0xF26B1D)
        case .red: Self.rgb(0xE8374A)
        case .pink: Self.rgb(0xE14F7B)
        case .purple: Self.rgb(0x8B6CFF)
        case .blue: Self.rgb(0x2F6BFF)
        case .glacier: Self.rgb(0x2BA9D6)
        case .green: Self.rgb(0x22B07D)
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
