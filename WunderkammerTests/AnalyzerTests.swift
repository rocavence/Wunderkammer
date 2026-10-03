import AppKit
import Testing
@testable import Wunderkammer

struct AnalyzerTests {
    @Test func colourNames() {
        #expect(Analyzer.name(0.9, 0.1, 0.1) == "red")
        #expect(Analyzer.name(0.1, 0.3, 0.9) == "blue")
        #expect(Analyzer.name(0.2, 0.7, 0.3) == "green")
        #expect(Analyzer.name(0.95, 0.85, 0.2) == "yellow")
        #expect(Analyzer.name(0.05, 0.05, 0.05) == "black")
        #expect(Analyzer.name(0.97, 0.97, 0.97) == "white")
        #expect(Analyzer.name(0.5, 0.5, 0.52) == "gray")
        #expect(Analyzer.name(0.45, 0.28, 0.15) == "brown")
        #expect(Analyzer.name(0.95, 0.6, 0.7) == "pink")
    }

    /// A red picture with words on it: OCR reads them, colour says red, and a
    /// visual fingerprint comes out.
    @Test func readsWordsAndColours() throws {
        let size = NSSize(width: 800, height: 400)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        ("CABINET OF WONDER" as NSString).draw(at: NSPoint(x: 60, y: 160), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wk-ocr-\(UUID().uuidString).png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)

        let result = Analyzer.analyze(imageAt: file, pdf: nil, knownText: false)
        #expect(result.ocrText?.uppercased().contains("CABINET") == true)
        #expect(result.colors.first == "red")
        #expect(result.featurePrint != nil)
        let d = try #require(Analyzer.distance(result.featurePrint!, result.featurePrint!))
        #expect(d < 0.001)
    }
}
