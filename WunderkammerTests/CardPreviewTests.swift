import AppKit
import Testing
@testable import Wunderkammer

/// Writes every card style to WK_CARD_PREVIEW_DIR for eyeballing. No-op otherwise.
struct CardPreviewTests {
    @Test func writeCards() throws {
        guard let dir = ProcessInfo.processInfo.environment["WK_CARD_PREVIEW_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cards: [(String, CGImage?)] = [
            ("text-short", CardRenderer.text("Everything worth keeping, nowhere to put it.", source: "wunderkammer.app")),
            ("text-long", CardRenderer.text(String(repeating: "世界每天都會丟給你無數東西。一張照片、一個網站、一段音樂、一部電影、一句話。大部分東西都會消失。Wunderkammer 只做一件事情：讓你留下它。", count: 4), source: nil)),
            ("web", CardRenderer.web(title: "The Cabinet of Curiosities and the Birth of the Museum", domain: "example.com", description: "Long before museums, collectors filled rooms with shells, maps, instruments and oddities, arranged by wonder rather than taxonomy.", favicon: nil)),
            ("audio", CardRenderer.audio(title: "In the Mood for Love", artist: "Shigeru Umebayashi", waveform: (0..<48).map { Float(abs(sin(Double($0) * 0.4))) * 0.9 + 0.05 })),
            ("file", CardRenderer.file(name: "Wunderkammer-Product-Planning.sketch", ext: "sketch", detail: "Sketch Document · 2.4 MB")),
        ]
        for (name, image) in cards {
            let image = try #require(image)
            Thumbnailer.writeJPEG(image, to: out.appendingPathComponent("\(name).jpg"))
        }
    }
}
