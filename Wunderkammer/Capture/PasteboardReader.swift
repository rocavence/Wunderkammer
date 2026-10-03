import AppKit
import UniformTypeIdentifiers

/// Reads whatever is on a pasteboard (clipboard, drag, service) as sources,
/// keeping the richest form: files as files, image bytes as they are, a link
/// as a page, text as text with the page it was copied from.
enum PasteboardReader {
    /// Browsers note where copied text or images came from.
    private static let sourceURLTypes: [NSPasteboard.PasteboardType] = [
        .init("org.chromium.source-url"), .init("org.mozilla.source-url"), .init("com.apple.webarchive.url"),
    ]
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    /// Image formats in order of preference: originals before re-encodings.
    private static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.init(UTType.gif.identifier), "gif"), (.init(UTType.png.identifier), "png"),
        (.init(UTType.jpeg.identifier), "jpg"), (.init(UTType.heic.identifier), "heic"),
        (.init(UTType.webP.identifier), "webp"), (.tiff, "tiff"),
    ]

    static func sources(from pasteboard: NSPasteboard) -> [Source] {
        // Files (Finder, Photos exports, Desktop).
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.map { .file($0) } }

        let origin = sourceURL(pasteboard)

        // Image bytes (copied image, screenshot to clipboard, browser drag).
        for (type, ext) in imageTypes {
            if let data = pasteboard.data(forType: type) {
                let name = origin.flatMap { $0.pathExtension.isEmpty ? nil : $0.lastPathComponent } ?? "Image.\(ext)"
                return [.imageData(data, name: name, origin: webURL(pasteboard) ?? origin)]
            }
        }

        // A link (copied URL, dragged link, address bar).
        if let url = webURL(pasteboard) {
            let title = pasteboard.string(forType: urlNameType)
            return [.web(url, title: title?.isEmpty == false ? title : nil)]
        }

        // Text: plain, or the plain form of rich text.
        if let text = pasteboard.string(forType: .string)
            ?? pasteboard.data(forType: .rtf).flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = linkOnly(trimmed) { return [.web(url, title: nil)] }
            if !trimmed.isEmpty { return [.text(trimmed, origin: origin)] }
        }
        return []
    }

    /// A pasteboard URL that's a web page (not a file).
    private static func webURL(_ pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        if let web = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) { return web }
        return pasteboard.string(forType: .URL).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
    }

    private static func sourceURL(_ pasteboard: NSPasteboard) -> URL? {
        for type in sourceURLTypes {
            if let s = pasteboard.string(forType: type), let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        return nil
    }

    /// Text that is nothing but one web address.
    static func linkOnly(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), text.count < 2048,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }
}
