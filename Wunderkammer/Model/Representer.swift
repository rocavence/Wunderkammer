import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Where a curiosity comes from, as handed over by a capture surface.
enum Source: Sendable {
    /// A file on disk. Referenced, not copied.
    case file(URL)
    /// Image bytes with no file of their own (copied image, screenshot, browser drag).
    case imageData(Data, name: String, origin: URL?)
    /// A web page.
    case web(URL, title: String?)
    /// Plain or rich text, with the page it came from if known.
    case text(String, origin: URL?)
}

/// Turns a source into a curiosity: detects the format, builds the cabinet
/// representation (written to thumbnails/) and reads the metadata it can get
/// cheaply. Slow enrichment (web pages, OCR…) happens later.
enum Representer {
    struct Context: Sendable {
        var originalsDir: URL
        var thumbnailsDir: URL
        var sourceApp: String?
    }

    enum Outcome: Sendable {
        case new(Item)
        case duplicate(String)
    }

    static let thumbnailSize = 600
    /// Non-image representations are kept larger: they're all the cabinet has.
    static let cardSize = 1200

    static func thumbnailURL(_ dir: URL, id: UUID, version: Int) -> URL {
        dir.appendingPathComponent(version == 0 ? "\(id.uuidString).jpg" : "\(id.uuidString)-v\(version).jpg")
    }

    static func ingest(_ source: Source, context: Context, known: Set<String>) async -> Outcome? {
        var outcome: Outcome?
        // Background tasks don't drain autorelease pools by themselves: wrap the
        // synchronous image work, or thousands of captures keep gigabytes alive.
        switch source {
        case .file(let url): outcome = await file(url, context, known)
        case .imageData(let data, let name, let origin): outcome = autoreleasepool { imageData(data, name: name, origin: origin, context, known) }
        case .web(let url, let title): outcome = autoreleasepool { web(url, title: title, context, known) }
        case .text(let text, let origin): outcome = autoreleasepool { textItem(text, origin: origin, context, known) }
        }
        if case .new(var item) = outcome {
            item.sourceApp = item.sourceApp ?? context.sourceApp
            outcome = .new(item)
        }
        return outcome
    }

    /// Folders become their contents, recursively (hidden files skipped).
    static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        // Packages (.app, .key, .pages…) are single things, not folders to walk.
        guard isDir.boolValue, !NSWorkspace.shared.isFilePackage(atPath: url.path) else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        let files = (walker?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                || NSWorkspace.shared.isFilePackage(atPath: $0.path)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: Files

    private static func file(_ url: URL, _ context: Context, _ known: Set<String>) async -> Outcome? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey, .nameKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let size = Int64(values?.fileSize ?? 0)

        // Pictures are deduplicated by content; everything else by where it lives.
        var hash = "file:" + url.standardizedFileURL.path
        if type.conforms(to: .image), size < 80_000_000, let data = try? Data(contentsOf: url) {
            hash = sha256(data)
        }
        if known.contains(hash) { return .duplicate(hash) }

        var item: Item
        if type.conforms(to: .image), let made = autoreleasepool(invoking: { image(at: url, hash: hash, context) }) {
            item = made
        } else if type.conforms(to: .pdf) {
            item = autoreleasepool { pdf(url, hash: hash, context) }
        } else if type.conforms(to: .audio) {
            item = await audio(url, hash: hash, context)
        } else if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            item = await video(url, hash: hash, context)
        } else if type.conforms(to: .plainText) || type.conforms(to: .rtf) || type.conforms(to: .html),
                  size < 2_000_000, let text = readText(url, type: type), !text.isEmpty {
            item = textCard(text, filename: url.lastPathComponent, hash: hash, context)
        } else {
            item = await genericFile(url, type: type, hash: hash, context)
        }
        item.filePath = url.standardizedFileURL.path
        item.fileBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        item.fileType = type.identifier
        item.fileSize = size
        item.createdDate = values?.creationDate
        if item.originalFilename.isEmpty { item.originalFilename = url.lastPathComponent }
        return .new(item)
    }

    private static func image(at url: URL, hash: String, _ context: Context) -> Item? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let (w, h) = pixelSize(source) else { return nil }
        var item = Item(kind: .image, originalFilename: url.lastPathComponent, pixelWidth: w, pixelHeight: h, contentHash: hash)
        writeThumbnail(Thumbnailer.decode(source: source, maxPixel: thumbnailSize), item.id, context)
        if let exif = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            item.createdDate = exifDate.date(from: taken)
        }
        return item
    }

    private static func pdf(_ url: URL, hash: String, _ context: Context) -> Item {
        let doc = PDFDocument(url: url)
        var image: CGImage?
        if let page = doc?.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = CGFloat(cardSize) / max(bounds.width, bounds.height)
            image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        var item = representation(.pdf, image ?? CardRenderer.file(name: url.lastPathComponent, ext: "pdf", detail: nil),
                                  name: url.lastPathComponent, hash: hash, context)
        item.pageCount = doc?.pageCount
        let attrs = doc?.documentAttributes
        if let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { item.title = title }
        if let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { item.creator = author }
        return item
    }

    private static func video(_ url: URL, hash: String, _ context: Context) async -> Item {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: cardSize, height: cardSize)
        // A frame a little in, so it isn't the black first frame.
        let at = CMTime(seconds: min(max((duration ?? 0) * 0.1, 0), 3), preferredTimescale: 600)
        let poster = try? await generator.image(at: at).image
        var item = representation(.video, poster ?? CardRenderer.file(name: url.lastPathComponent, ext: url.pathExtension, detail: nil),
                                  name: url.lastPathComponent, hash: hash, context)
        item.duration = duration.flatMap { $0.isFinite ? $0 : nil }
        if let meta = try? await asset.load(.commonMetadata) {
            if let title = await string(meta, .commonIdentifierTitle) { item.title = title }
            let artist = await string(meta, .commonIdentifierArtist)
            let author = await string(meta, .commonIdentifierAuthor)
            item.creator = artist ?? author
        }
        return item
    }

    private static func audio(_ url: URL, hash: String, _ context: Context) async -> Item {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let meta = (try? await asset.load(.commonMetadata)) ?? []
        let metaTitle = await string(meta, .commonIdentifierTitle)
        let title = metaTitle ?? (url.lastPathComponent as NSString).deletingPathExtension
        let artist = await string(meta, .commonIdentifierArtist)
        var artwork: CGImage?
        if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue),
           let src = CGImageSourceCreateWithData(data as CFData, nil) {
            artwork = Thumbnailer.decode(source: src, maxPixel: cardSize)
        }
        var picture = artwork
        if picture == nil {
            picture = CardRenderer.audio(title: title, artist: artist, waveform: await waveform(asset, bars: 48))
        }
        var item = representation(.audio, picture, name: url.lastPathComponent, hash: hash, context)
        item.title = title
        item.creator = artist
        item.duration = duration.flatMap { $0.isFinite ? $0 : nil }
        return item
    }

    private static func genericFile(_ url: URL, type: UTType, hash: String, _ context: Context) async -> Item {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 600, height: 600), scale: 2,
                                                   representationTypes: .all)
        let thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        let card = CardRenderer.file(name: url.lastPathComponent, ext: url.pathExtension,
                                     detail: [type.localizedDescription, size].compactMap { $0 }.joined(separator: " · "))
        // Icons (apps, folders…) have transparent corners: set them on a card.
        let picture = thumb.map { Thumbnailer.hasAlpha($0) ? (CardRenderer.framed($0, size: CGSize(width: 360, height: 360)) ?? $0) : $0 }
        return representation(.file, picture ?? card, name: url.lastPathComponent, hash: hash, context)
    }

    // MARK: Content without a file

    private static func imageData(_ data: Data, name: String, origin: URL?, _ context: Context, _ known: Set<String>) -> Outcome? {
        let hash = sha256(data)
        if known.contains(hash) { return .duplicate(hash) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let (w, h) = pixelSize(source) else { return nil }
        var item = Item(kind: .image, originalFilename: name, pixelWidth: w, pixelHeight: h, contentHash: hash)
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension.lowercased()
        let stored = item.id.uuidString + "." + ext
        guard (try? data.write(to: context.originalsDir.appendingPathComponent(stored))) != nil else { return nil }
        item.storedFilename = stored
        item.url = origin?.absoluteString
        item.fileSize = Int64(data.count)
        item.fileType = UTType(filenameExtension: ext)?.identifier
        writeThumbnail(Thumbnailer.decode(source: source, maxPixel: thumbnailSize), item.id, context)
        return .new(item)
    }

    private static func web(_ url: URL, title: String?, _ context: Context, _ known: Set<String>) -> Outcome? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let hash = "url:" + normalized(url)
        if known.contains(hash) { return .duplicate(hash) }
        let domain = url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        // A card right away; the page's own preview replaces it once fetched.
        var item = representation(.web, CardRenderer.web(title: title ?? domain, domain: domain, description: nil, favicon: nil),
                                  name: "", hash: hash, context)
        item.url = url.absoluteString
        item.title = title
        return .new(item)
    }

    private static func textItem(_ text: String, origin: URL?, _ context: Context, _ known: Set<String>) -> Outcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hash = sha256(Data(trimmed.utf8))
        if known.contains(hash) { return .duplicate(hash) }
        var item = textCard(trimmed, filename: "", hash: hash, context, origin: origin)
        item.url = origin?.absoluteString
        return .new(item)
    }

    private static func textCard(_ text: String, filename: String, hash: String, _ context: Context, origin: URL? = nil) -> Item {
        let source = origin?.host() ?? (filename.isEmpty ? nil : filename)
        var item = representation(.text, CardRenderer.text(text, source: source), name: filename, hash: hash, context)
        item.text = String(text.prefix(20_000))
        return item
    }

    // MARK: Helpers

    /// An item whose look is `image` (already rendered), saved as its thumbnail.
    private static func representation(_ kind: Item.Kind, _ image: CGImage?, name: String, hash: String, _ context: Context) -> Item {
        var item = Item(kind: kind, originalFilename: name, pixelWidth: image?.width ?? 4, pixelHeight: image?.height ?? 3, contentHash: hash)
        writeThumbnail(image, item.id, context)
        if image == nil { item.pixelWidth = 4; item.pixelHeight = 3 }
        return item
    }

    static func writeThumbnail(_ image: CGImage?, _ id: UUID, _ context: Context, version: Int = 0) {
        guard let image else { return }
        Thumbnailer.writeJPEG(image, to: thumbnailURL(context.thumbnailsDir, id: id, version: version))
    }

    private static func pixelSize(_ source: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 are rotated 90°, so the displayed size is swapped.
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return (w, h)
    }

    private static func readText(_ url: URL, type: UTType) -> String? {
        if type.conforms(to: .plainText) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16))
        }
        let docType: NSAttributedString.DocumentType = type.conforms(to: .html) ? .html : .rtf
        return (try? NSAttributedString(url: url, options: [.documentType: docType], documentAttributes: nil))?.string
    }

    private static func string(_ meta: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first else { return nil }
        let value = try? await item.load(.stringValue)
        return value?.isEmpty == false ? value : nil
    }

    /// Peak levels in `bars` slices of the first two minutes, 0…1.
    private static func waveform(_ asset: AVURLAsset, bars: Int) async -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset),
              let track = try? await asset.loadTracks(withMediaType: .audio).first else { return Array(repeating: 0.1, count: bars) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8000,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 120, preferredTimescale: 600))
        guard reader.startReading() else { return Array(repeating: 0.1, count: bars) }
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer {
                pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) {
                    samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 2))
                }
            }
        }
        guard !samples.isEmpty else { return Array(repeating: 0.1, count: bars) }
        let chunk = max(samples.count / bars, 1)
        var peaks: [Float] = (0..<bars).map { b in
            let slice = samples[min(b * chunk, samples.count - 1)..<min((b + 1) * chunk, samples.count)]
            return Float(slice.map { abs(Int32($0)) }.max() ?? 0) / Float(Int16.max)
        }
        let top = max(peaks.max() ?? 1, 0.01)
        peaks = peaks.map { max($0 / top, 0.04) }
        return peaks
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same page, different spellings: drop the fragment and a trailing slash.
    static func normalized(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        var s = c?.string ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
