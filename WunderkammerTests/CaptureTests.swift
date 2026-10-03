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

    @Test func onlyWebAddressesAreAccepted() {
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "wunderkammer://capture?url=file%3A%2F%2F%2Fetc%2Fpasswd")!).isEmpty)
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "wunderkammer://capture?image=file%3A%2F%2F%2FUsers%2Fx%2Fa.png")!).isEmpty)
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "wunderkammer://capture?url=javascript%3Aalert(1)")!).isEmpty)
        let long = String(repeating: "x", count: 50_000)
        guard case .text(let t, _) = CaptureController.sources(fromCaptureURL: URL(string: "wunderkammer://capture?text=\(long)")!).first
        else { Issue.record("text dropped"); return }
        #expect(t.count == 20_000)
    }

    @Test func otherLinksAreIgnored() {
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "wunderkammer://open?x=1")!).isEmpty)
        #expect(CaptureController.sources(fromCaptureURL: URL(string: "https://capture?url=x")!).isEmpty)
    }
}

struct ShareInboxTests {
    @Test func untrustedManifestsCantReachOutside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wk-share-evil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["entries": [
            ["image": "../../../../etc/hosts"],
            ["image": ".hidden"],
            ["path": "/etc/hosts"],
            ["path": NSHomeDirectory() + "/Library/Preferences/com.apple.finder.plist"],
            ["path": NSHomeDirectory() + "/.ssh/id_rsa"],
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        #expect(ShareInboxWatcher.sources(in: folder).isEmpty)
        #expect(ShareInboxWatcher.contained("../x", in: folder) == nil)
    }

    @Test func manifestBecomesSources() throws {
        // A visible folder under home, like a share from Finder.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("wk-share-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let referenced = folder.appendingPathComponent("doc.txt")
        try "hello".write(to: referenced, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("pic.png"))
        let manifest: [String: Any] = ["entries": [
            ["path": referenced.path],
            ["path": "/nonexistent/gone.png", "image": "pic.png"],
            ["url": "https://example.com/a"],
            ["url": "file:///etc/passwd"],
            ["text": "  https://example.org/b  "],
            ["text": "a thought"],
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let sources = ShareInboxWatcher.sources(in: folder)
        #expect(sources.count == 5)
        guard case .file(let f) = sources[0], case .imageData(_, let name, _) = sources[1],
              case .web(let a, _) = sources[2], case .web(let b, _) = sources[3], case .text(let t, _) = sources[4]
        else { Issue.record("wrong kinds: \(sources)"); return }
        #expect(f.path == referenced.path && name == "pic.png")
        #expect(a.absoluteString == "https://example.com/a" && b.absoluteString == "https://example.org/b" && t == "a thought")
    }
}

@MainActor
struct ShortcutTests {
    @Test func storedRoundTripAndDisplay() {
        let s = GlobalHotkeys.Shortcut(keyCode: 8, modifiers: [.command, .shift, .capsLock])  // C
        #expect(s.modifiers == [.command, .shift])
        #expect(GlobalHotkeys.Shortcut(stored: s.stored) == s)
        #expect(s.display == "⇧⌘C")
        #expect(GlobalHotkeys.Shortcut(keyCode: 8, modifiers: [.option, .command]).display == "⌥⌘C")
        #expect(GlobalHotkeys.Shortcut(stored: "garbage") == nil)
    }
}
