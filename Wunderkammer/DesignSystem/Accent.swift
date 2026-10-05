import AppKit

/// The one colour the app is allowed to choose: the accent. It marks what's
/// chosen and what's active (the space you're in, a selection, a dropped-on
/// target) and nothing else; the rest of the palette stays the system's.
/// The system's own accent, or one of the same colours System Settings
/// offers; orange by default.
enum Accent: String, CaseIterable, Sendable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite

    var title: String {
        switch self {
        case .system: String(localized: "跟隨系統")
        case .blue: String(localized: "藍色")
        case .purple: String(localized: "紫色")
        case .pink: String(localized: "粉紅色")
        case .red: String(localized: "紅色")
        case .orange: String(localized: "橙色")
        case .yellow: String(localized: "黃色")
        case .green: String(localized: "綠色")
        case .graphite: String(localized: "石墨色")
        }
    }

    var color: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }

    /// Choices from before the system's set, mapped to their nearest.
    private static func migrated(_ raw: String) -> Accent? {
        Accent(rawValue: raw) ?? ["vermilion": .red, "amber": .yellow, "sky": .blue, "ultramarine": .blue][raw]
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
