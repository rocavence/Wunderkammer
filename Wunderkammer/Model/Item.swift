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
    /// What a web page is about, from its structured data: a book, a film…
    var thing: Thing?
    /// Who made it, with their role: author, director, artist…
    var credits: [Credit]?
    /// As the page gives it: "2021-10-22", "2021-10" or "2021".
    var released: String?
    /// The city a place is in, or where a work is set ("New York").
    var locality: String?
    /// Which WebMetadata.version last read this page's structured data.
    var webDataVersion: Int?
    /// A web page as it was when collected: the whole page as a PDF in archives/.
    var archiveFilename: String?
    /// The page's own words (the start of them), for search and questions.
    var pageText: String?
    /// When the page was saved, or tried to be (nil: not yet).
    var archivedAt: Date?

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
        // Unknown values from a newer version are dropped, not fatal.
        thing = try? c.decodeIfPresent(Thing.self, forKey: .thing)
        credits = try? c.decodeIfPresent([Credit].self, forKey: .credits)
        released = try c.decodeIfPresent(String.self, forKey: .released)
        locality = try c.decodeIfPresent(String.self, forKey: .locality)
        webDataVersion = try c.decodeIfPresent(Int.self, forKey: .webDataVersion)
        archiveFilename = try c.decodeIfPresent(String.self, forKey: .archiveFilename)
        pageText = try c.decodeIfPresent(String.self, forKey: .pageText)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        colors = try c.decodeIfPresent([String].self, forKey: .colors)
        entities = try? c.decodeIfPresent([Entity].self, forKey: .entities)
        analysisVersion = try c.decodeIfPresent(Int.self, forKey: .analysisVersion) ?? 0
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
        lastViewed = try c.decodeIfPresent(Date.self, forKey: .lastViewed)
    }

    enum Thing: String, Codable, CaseIterable, Sendable {
        case book, movie, show, music, product, place

        var title: String {
            switch self {
            case .book: "書"
            case .movie: "電影"
            case .show: "影集"
            case .music: "音樂"
            case .product: "商品"
            case .place: "地點"
            }
        }
    }

    struct Credit: Codable, Hashable, Sendable {
        enum Role: String, Codable, Sendable {
            case author, director, artist, creator, brand, actor

            var title: String {
                switch self {
                case .author: "作者"
                case .director: "導演"
                case .artist: "演出者"
                case .creator: "創作者"
                case .brand: "品牌"
                case .actor: "演員"
                }
            }
        }
        var role: Role
        var name: String
    }

    /// The names the system found plus the people credited, once each:
    /// credited people link, search and graph like any other name.
    static func merging(_ entities: [Entity], credits: [Credit]?) -> [Entity] {
        var out = entities
        var seen = Set(entities.map { Search.normalize($0.name) })
        for c in credits ?? [] where c.role != .brand && seen.insert(Search.normalize(c.name)).inserted {
            out.append(Entity(kind: .person, name: c.name))
        }
        return out
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
