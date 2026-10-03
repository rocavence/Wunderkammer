import AppKit
import Testing
@testable import Wunderkammer

/// Pasteboards become the right kind of source, the richest form first.
@MainActor
struct PasteboardReaderTests {
    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("wk-test-\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        return pb
    }

    @Test func plainTextIsText() {
        let pb = board { $0.setString("Keep what catches your eye.", forType: .string) }
        guard case .text(let t, let origin) = PasteboardReader.sources(from: pb).first else { Issue.record("not text"); return }
        #expect(t == "Keep what catches your eye." && origin == nil)
    }

    @Test func aLoneLinkIsAWebPage() {
        let pb = board { $0.setString("  https://example.com/a?b=1  ", forType: .string) }
        guard case .web(let url, _) = PasteboardReader.sources(from: pb).first else { Issue.record("not web"); return }
        #expect(url.absoluteString == "https://example.com/a?b=1")
    }

    @Test func textMentioningALinkStaysText() {
        let pb = board { $0.setString("see https://example.com later", forType: .string) }
        guard case .text = PasteboardReader.sources(from: pb).first else { Issue.record("should be text"); return }
    }

    @Test func copiedTextRemembersItsPage() {
        let pb = board {
            $0.setString("A sentence from a page.", forType: .string)
            $0.setString("https://example.org/essay", forType: .init("org.chromium.source-url"))
        }
        guard case .text(_, let origin) = PasteboardReader.sources(from: pb).first else { Issue.record("not text"); return }
        #expect(origin?.absoluteString == "https://example.org/essay")
    }

    @Test func imageBytesWin() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let pb = board {
            $0.setData(png, forType: .png)
            $0.setString("alt text", forType: .string)
        }
        guard case .imageData(let data, let name, _) = PasteboardReader.sources(from: pb).first else { Issue.record("not image"); return }
        #expect(data == png && name.hasSuffix(".png"))
    }

    @Test func filesAreFiles() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let pb = board { $0.writeObjects([url as NSURL]) }
        guard case .file(let f) = PasteboardReader.sources(from: pb).first else { Issue.record("not file"); return }
        #expect(f.path == url.path)
    }

    @Test func emptyIsNothing() {
        #expect(PasteboardReader.sources(from: board { _ in }).isEmpty)
    }
}

struct CaptureURLTests {
    @Test func pageWithTitle() {
        let url = URL(string: "wunderkammer://capture?url=https%3A%2F%2Fexample.com%2Fx&title=An%20Essay")!
        guard case .web(let page, let title) = CaptureController.sources(fromCaptureURL: url).first else { Issue.record("not web"); return }
        #expect(page.absoluteString == "https://example.com/x" && title == "An Essay")
    }

    @Test func selectedTextKeepsThePage() {
        let url = URL(string: "wunderkammer://capture?url=https%3A%2F%2Fexample.com&text=Hello%20there")!
        guard case .text(let text, let origin) = CaptureController.sources(fromCaptureURL: url).first else { Issue.record("not text"); return }
        #expect(text == "Hello there" && origin?.host() == "example.com")
    }

    @Test func otherLinksAreIgnored() {
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "wunderkammer://open?x=1")!).isEmpty)
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "https://capture?url=x")!).isEmpty)
    }
}
