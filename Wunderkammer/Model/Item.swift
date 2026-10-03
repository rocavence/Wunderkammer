import Foundation
import UniformTypeIdentifiers

/// A curiosity: something worth keeping, with where it came from, how it
/// looks in the cabinet, and what the system knows about it. Wunderkammer
/// doesn't have to own the original: a dropped file stays where it is and is
/// referenced; only content with no home of its own (a copied image, a
/// screenshot) is kept in the library.
struct Item: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case image, video, audio, pdf, web, text, file
    }

    var id: UUID
    var kind: Kind
    /// When it was collected.
    var dateAdded: Date

    // Source
    /// Content the library holds, in originals/.
    var storedFilename: String?
    /// A file that lives elsewhere on disk.
    var filePath: String?
    var fileBookmark: Data?
    /// The web page itself (web) or where the content came from (image, text).
    var url: String?
    /// The text (text), or the page description (web).
    var text: String?
    var title: String?
    var sourceApp: String?
    var originalFilename: String

    // Representation
    var pixelWidth: Int
    var pixelHeight: Int
    /// Bumped whenever the representation image is regenerated.
    var representationVersion: Int
    var contentHash: String

    // Metadata
    var fileType: String?
    var fileSize: Int64?
    var duration: Double?
    var createdDate: Date?
    var creator: String?
    var pageCount: Int?

    // Understanding (filled in the background)
    var ocrText: String?
    var labels: [String]?
    var colors: [String]?
    /// People, places and organisations named in the title, text or picture.
    var entities: [Entity]?
    /// Which version of the Analyzer last looked at it (0 = not yet).
    var analysisVersion: Int
    var analyzed: Bool { analysisVersion >= Analyzer.version }

    // Interaction
    var viewCount: Int
    var lastViewed: Date?

    init(id: UUID = UUID(), kind: Kind, dateAdded: Date = Date(), originalFilename: String,
         pixelWidth: Int, pixelHeight: Int, contentHash: String) {
        self.id = id
        self.kind = kind
        self.dateAdded = dateAdded
        self.originalFilename = originalFilename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentHash = contentHash
        representationVersion = 0
        analysisVersion = 0
        viewCount = 0
    }

    // Libraries written by earlier versions only have the image fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // A kind from a newer version reads as a generic file rather than failing the library.
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? (c.contains(.kind) ? .file : .image)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        storedFilename = try c.decodeIfPresent(String.self, forKey: .storedFilename)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename) ?? ""
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 1
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 1
        representationVersion = try c.decodeIfPresent(Int.self, forKey: .representationVersion) ?? 0
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? id.uuidString
        fileType = try c.decodeIfPresent(String.self, forKey: .fileType)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate)
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        colors = try c.decodeIfPresent([String].self, forKey: .colors)
        entities = try? c.decodeIfPresent([Entity].self, forKey: .entities)
        analysisVersion = try c.decodeIfPresent(Int.self, forKey: .analysisVersion) ?? 0
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
        lastViewed = try c.decodeIfPresent(Date.self, forKey: .lastViewed)
    }

    struct Entity: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case person, place, organization }
        var kind: Kind
        var name: String
    }

    var aspect: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        // Clamp so panoramas and slivers don't wreck a row.
        return min(max(CGFloat(pixelWidth) / CGFloat(pixelHeight), 0.25), 4)
    }

    var domain: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What to call it: a title if known, else the file name, else the site.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if kind == .text, let text { return String(text.prefix(80)) }
        if !originalFilename.isEmpty { return (originalFilename as NSString).deletingPathExtension }
        return domain ?? url ?? "Untitled"
    }

    /// Whether the original is a picture we can show at full resolution.
    var hasFullImage: Bool { kind == .image && (storedFilename != nil || filePath != nil) }
}
