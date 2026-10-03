import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Wunderkammer

/// Every source becomes a curiosity with a representation on disk.
struct RepresenterTests {
    let dir: URL
    let context: Representer.Context

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wk-tests-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals"), thumbs = dir.appendingPathComponent("thumbnails")
        for d in [originals, thumbs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        context = Representer.Context(originalsDir: originals, thumbnailsDir: thumbs, sourceApp: "Tests")
    }

    private func ingest(_ source: Source, known: Set<String> = []) async -> Item? {
        guard case .new(let item) = await Representer.ingest(source, context: context, known: known) else { return nil }
        return item
    }

    private func hasThumbnail(_ item: Item) -> Bool {
        FileManager.default.fileExists(atPath: Representer.thumbnailURL(context.thumbnailsDir, id: item.id, version: item.representationVersion).path)
    }

    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func imageFileIsReferencedNotCopied() async throws {
        let file = dir.appendingPathComponent("red.png")
        try png(width: 300, height: 200).write(to: file)
        let item = try #require(await ingest(.file(file)))
        #expect(item.kind == .image)
        #expect(item.pixelWidth == 300 && item.pixelHeight == 200)
        #expect(item.filePath == file.standardizedFileURL.path)
        #expect(item.storedFilename == nil)
        #expect(item.sourceApp == "Tests")
        #expect(hasThumbnail(item))
        #expect(try FileManager.default.contentsOfDirectory(atPath: context.originalsDir.path).isEmpty)
    }

    @Test func copiedImageIsKept() async throws {
        let item = try #require(await ingest(.imageData(png(width: 40, height: 80), name: "Pasted.png", origin: URL(string: "https://example.com/a.png"))))
        #expect(item.kind == .image && item.storedFilename != nil)
        #expect(item.url == "https://example.com/a.png")
        #expect(item.aspect == 0.5)
    }

    @Test func duplicatesAreRecognised() async throws {
        let data = png(width: 10, height: 10)
        let first = try #require(await ingest(.imageData(data, name: "a.png", origin: nil)))
        let again = await Representer.ingest(.imageData(data, name: "b.png", origin: nil), context: context, known: [first.contentHash])
        guard case .duplicate(let hash) = again else { Issue.record("expected duplicate"); return }
        #expect(hash == first.contentHash)
    }

    @Test func textBecomesACard() async throws {
        let item = try #require(await ingest(.text("  Everything worth keeping, nowhere to put it.  ", origin: URL(string: "https://www.example.org/x"))))
        #expect(item.kind == .text)
        #expect(item.text == "Everything worth keeping, nowhere to put it.")
        #expect(item.domain == "example.org")
        #expect(hasThumbnail(item))
    }

    @Test func textFileBecomesACard() async throws {
        let file = dir.appendingPathComponent("notes.md")
        try "# Wunderkammer\nCollect without organizing.".write(to: file, atomically: true, encoding: .utf8)
        let item = try #require(await ingest(.file(file)))
        #expect(item.kind == .text)
        #expect(item.text?.contains("Collect without organizing.") == true)
    }

    @Test func pdfShowsItsFirstPage() async throws {
        let file = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = try #require(CGContext(file as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "A Test Paper"] as CFDictionary))
        for _ in 0..<3 { ctx.beginPDFPage(nil); ctx.setFillColor(.black); ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 100)); ctx.endPDFPage() }
        ctx.closePDF()
        let item = try #require(await ingest(.file(file)))
        #expect(item.kind == .pdf)
        #expect(item.pageCount == 3)
        #expect(item.title == "A Test Paper")
        #expect(abs(item.aspect - 0.75) < 0.02)
        #expect(hasThumbnail(item))
    }

    @Test func audioGetsDurationAndACard() async throws {
        let file = dir.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        do {
            // Scoped so the file is closed (header written) before it's read.
            let out = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for i in 0..<16000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.2) * Float(i) / 16000 }
            try out.write(from: buffer)
        }
        let item = try #require(await ingest(.file(file)))
        #expect(item.kind == .audio)
        #expect(abs((item.duration ?? 0) - 2) < 0.1)
        #expect(item.pixelWidth == item.pixelHeight)
        #expect(hasThumbnail(item))
    }

    @Test func otherFilesGetARepresentation() async throws {
        let file = dir.appendingPathComponent("data.bin")
        try Data(repeating: 7, count: 2048).write(to: file)
        let item = try #require(await ingest(.file(file)))
        #expect(item.kind == .file)
        #expect(item.fileSize == 2048)
        #expect(hasThumbnail(item))
    }

    @Test func webPageIsInstantAndDeduplicatedByURL() async throws {
        let url = URL(string: "https://www.example.com/article/#comments")!
        let item = try #require(await ingest(.web(url, title: "An Article")))
        #expect(item.kind == .web && item.title == "An Article" && item.domain == "example.com")
        #expect(hasThumbnail(item))
        let again = await Representer.ingest(.web(URL(string: "https://www.example.com/article")!, title: nil), context: context, known: [item.contentHash])
        guard case .duplicate = again else { Issue.record("same page should be a duplicate"); return }
    }

    @Test func foldersExpandButPackagesDont() throws {
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("a.txt"))
        try Data([1]).write(to: folder.appendingPathComponent("sub/b.txt"))
        try Data([1]).write(to: folder.appendingPathComponent(".hidden"))
        #expect(Representer.expand(folder).map(\.lastPathComponent) == ["a.txt", "b.txt"])
    }
}

struct WebMetadataTests {
    @Test func parsesOpenGraphAndIcons() {
        let html = """
        <html><head><title>Fallback &amp; Title</title>
        <meta property="og:title" content="The Real Title &#8211; Site">
        <meta name='description' content='A description.'>
        <meta property="og:image" content="/img/cover.jpg">
        <meta property="og:site_name" content="Example">
        <link rel="icon" href="/favicon-16.png" sizes="16x16">
        <link rel="apple-touch-icon" href="/touch.png" sizes="180x180">
        </head></html>
        """
        let meta = WebMetadata.parse(html, base: URL(string: "https://example.com/post/1")!)
        #expect(meta.title == "The Real Title – Site")
        #expect(meta.description == "A description.")
        #expect(meta.imageURL?.absoluteString == "https://example.com/img/cover.jpg")
        #expect(meta.iconURL?.absoluteString == "https://example.com/touch.png")
        #expect(meta.siteName == "Example")
    }

    @Test func titleTagIsTheFallback() {
        let meta = WebMetadata.parse("<title>\n  Just a title \n</title>", base: URL(string: "https://a.b")!)
        #expect(meta.title == "Just a title")
        #expect(meta.iconURL?.absoluteString == "https://a.b/favicon.ico")
    }
}

struct ItemDecodingTests {
    /// Libraries from before curiosities had kinds still load.
    @Test func legacyImageItemDecodes() throws {
        let json = """
        {"id":"5274D7AA-79C2-4FCD-B575-51C23FA7DF5B","originalFilename":"a.jpg","storedFilename":"X.jpg",
         "pixelWidth":100,"pixelHeight":50,"contentHash":"abc","dateAdded":800000000}
        """
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        #expect(item.kind == .image)
        #expect(item.aspect == 2)
        #expect(item.viewCount == 0 && item.representationVersion == 0)
        #expect(item.hasFullImage)
    }
}
