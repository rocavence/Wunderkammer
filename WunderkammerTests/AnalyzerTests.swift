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

struct EntityAndSubjectTests {
    /// Names are found; their kind (person, place) is only a guess, so it isn't relied on.
    @Test func namesInEnglish() {
        let names = Set(Analyzer.entities(in: "Wong Kar-wai filmed In the Mood for Love in Hong Kong with Tony Leung and Maggie Cheung.").map(\.name))
        #expect(names.isSuperset(of: ["Wong Kar-wai", "Tony Leung", "Maggie Cheung", "Hong Kong"]))
    }

    @Test func chineseQueriesAreSegmented() {
        #expect(Search.tokens("王家衛的電影") == ["王家衛", "電影"])
        #expect(Search.tokens("紅色的椅子") == ["紅色", "椅子"])
    }

    @Test func themesNeedEnoughButNotEverything() {
        func item(_ labels: [String]) -> Item {
            var i = Item(kind: .image, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: UUID().uuidString)
            i.labels = labels
            return i
        }
        let items = (0..<10).map { i in item(["people"] + (i < 4 ? ["cat"] : []) + (i < 2 ? ["dog"] : []) + ["structure"]) }
        let subjects = Subjects.discover(in: items)
        // "people" is on everything, "dog" on too few, "structure" is too general.
        #expect(subjects.map(\.label) == ["cat"])
        #expect(subjects.first?.title == "貓" && subjects.first?.count == 4)
    }
}
