import Foundation
import Translation

/// Descriptions in Chinese become English for MobileCLIP: the system's
/// on-device translation when its language pack is installed (macOS 26+),
/// otherwise the words we know (紅色 → red, 椅子 → chair).
@MainActor
final class QueryTranslator {
    /// A TranslationSession on systems that have one.
    private var session: AnyObject?
    private var cache: [String: String] = [:]
    private(set) var installed = false

    static func needsTranslation(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    func refresh() async {
        guard #available(macOS 26.0, *) else { return }
        let zh = Locale.Language(identifier: "zh-Hant"), en = Locale.Language(identifier: "en")
        installed = await LanguageAvailability().status(from: zh, to: en) == .installed
        if installed, session == nil { session = TranslationSession(installedSource: zh, target: en) }
    }

    func english(_ text: String) async -> String? {
        guard Self.needsTranslation(text) else { return text }
        if let hit = cache[text] { return hit }
        if #available(macOS 26.0, *), installed, let session = session as? TranslationSession {
            // The session is only ever used from here, one query at a time.
            nonisolated(unsafe) let s = session
            if let r = try? await s.translate(text) {
                cache[text] = r.targetText
                return r.targetText
            }
        }
        // Without the language pack: the words we know, in English.
        let words = Search.tokens(text).flatMap { token -> [String] in
            Search.synonyms[token] ?? (token.unicodeScalars.contains { $0.properties.isIdeographic } ? [] : [token])
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
