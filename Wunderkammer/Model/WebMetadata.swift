import Foundation
import ImageIO

/// What a web page says about itself: <title>, Open Graph and Twitter cards,
/// structured data (what it is and who made it), favicon. Fetched after
/// capture so capturing a URL is instant.
struct WebMetadata: Sendable {
    var title: String?
    var description: String?
    var siteName: String?
    var author: String?
    var published: Date?
    var imageURL: URL?
    var iconURL: URL?
    /// A book, a film, an album… when the page says so.
    var thing: Item.Thing?
    var credits: [Item.Credit] = []
    var released: String?
    /// If the URL itself is an image (someone copied an image link).
    var isImage = false

    static func fetch(_ url: URL) async -> WebMetadata? {
        guard isWeb(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let base = response.url ?? url
        if let mime = response.mimeType, mime.hasPrefix("image/") {
            return WebMetadata(imageURL: base, isImage: true)
        }
        let html = String(decoding: data.prefix(600_000), as: UTF8.self)
        return parse(html, base: base)
    }

    static func parse(_ html: String, base: URL) -> WebMetadata {
        var meta = WebMetadata()
        var tags: [String: String] = [:]
        for tag in matches(#"<meta\s[^>]*>"#, in: html) {
            guard let content = attribute("content", in: tag) else { continue }
            let key = (attribute("property", in: tag) ?? attribute("name", in: tag) ?? attribute("itemprop", in: tag))?.lowercased()
            if let key, tags[key] == nil { tags[key] = decode(content) }
        }
        let titleTag = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).map(decode)
        meta.title = clean(tags["og:title"] ?? tags["twitter:title"] ?? titleTag)
        meta.description = clean(tags["og:description"] ?? tags["twitter:description"] ?? tags["description"])
        meta.siteName = clean(tags["og:site_name"])
        meta.author = clean(tags["author"] ?? tags["article:author"] ?? tags["twitter:creator"])
        if let p = tags["article:published_time"] ?? tags["datepublished"] { meta.published = ISO8601DateFormatter().date(from: p) }
        if let image = tags["og:image"] ?? tags["og:image:url"] ?? tags["twitter:image"] ?? tags["twitter:image:src"] {
            meta.imageURL = URL(string: image, relativeTo: base)?.absoluteURL
        }
        // The biggest declared icon; /favicon.ico as the fallback.
        var best: (URL, Int)?
        for tag in matches(#"<link\s[^>]*>"#, in: html) {
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag), let u = URL(string: decode(href), relativeTo: base)?.absoluteURL else { continue }
            let size = attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") } ?? (rel.contains("apple") ? 180 : 16)
            if best == nil || size > best!.1 { best = (u, size) }
        }
        meta.iconURL = best?.0 ?? URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL
        structured(html, tags: tags, into: &meta)
        return meta
    }

    // MARK: Structured data

    private static let things: [String: Item.Thing] = [
        "book": .book, "movie": .movie, "tvseries": .show, "tvseason": .show, "tvepisode": .show,
        "musicalbum": .music, "musicrecording": .music, "musicplaylist": .music, "product": .product,
        "place": .place, "localbusiness": .place, "restaurant": .place, "touristattraction": .place,
        "museum": .place, "landmarksorhistoricalbuildings": .place, "hotel": .place, "cafeorcoffeeshop": .place,
    ]
    private static let ogThings: [String: Item.Thing] = [
        "book": .book, "books.book": .book, "video.movie": .movie, "video.tv_show": .show, "video.episode": .show,
        "music.song": .music, "music.album": .music, "music.playlist": .music, "product": .product,
        "og:product": .product, "product.item": .product, "place": .place, "restaurant.restaurant": .place,
    ]

    /// JSON-LD (schema.org) first, Open Graph types as the fallback: what the
    /// page is about, who made it, when it came out.
    static func structured(_ html: String, tags: [String: String], into meta: inout WebMetadata) {
        let scripts = matches(#"<script[^>]*application/ld\+json[^>]*>[\s\S]*?</script>"#, in: html)
        var objects: [[String: Any]] = []
        for script in scripts {
            guard let start = script.firstIndex(of: ">"), let end = script.range(of: "</script>", options: .backwards) else { continue }
            // Only the JSON itself: some sites wrap it in /* <![CDATA[ */ … /* ]]> */.
            let inner = script[script.index(after: start)..<end.lowerBound]
                .replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
            guard let open = inner.firstIndex(where: { $0 == "{" || $0 == "[" }),
                  let close = inner.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close else { continue }
            let body = String(inner[open...close])
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { continue }
            objects += flatten(json)
        }
        if let (object, thing) = objects.lazy.compactMap({ o in types(o).lazy.compactMap { things[$0] }.first.map { (o, $0) } }).first {
            meta.thing = thing
            if let name = (object["name"] as? String).flatMap({ clean(decode($0)) }) { meta.title = name }
            let roles: [(String, Item.Credit.Role)] = thing == .music
                ? [("byArtist", .artist), ("author", .artist), ("creator", .creator)]
                : [("author", .author), ("director", .director), ("byArtist", .artist), ("creator", .creator), ("brand", .brand)]
            for (key, role) in roles {
                for name in names(object[key]) where !meta.credits.contains(where: { $0.name == name }) {
                    meta.credits.append(Item.Credit(role: role, name: name))
                }
            }
            // dateCreated last: on some sites it's when their record was made.
            let event = ((object["releasedEvent"] as? [[String: Any]])?.first ?? object["releasedEvent"] as? [String: Any])?["startDate"]
            meta.released = [object["datePublished"], object["releaseDate"], event, object["startDate"], object["dateCreated"]]
                .lazy.compactMap { ($0 as? String).flatMap(day) }.first
        } else if let type = tags["og:type"]?.lowercased(), let thing = ogThings[type] {
            meta.thing = thing
            let roles: [(String, Item.Credit.Role)] = [("book:author", .author), ("video:director", .director),
                                                       ("music:musician", .artist), ("product:brand", .brand)]
            for (key, role) in roles {
                // These are often profile URLs, not names.
                if let name = tags[key].flatMap(clean), !name.contains("://") {
                    meta.credits.append(Item.Credit(role: role, name: name))
                }
            }
            meta.released = ["book:release_date", "music:release_date", "video:release_date"]
                .lazy.compactMap { tags[$0].flatMap(day) }.first
        }
        if meta.credits.isEmpty, let author = meta.author, meta.thing != nil, !author.contains("://") {
            meta.credits = [Item.Credit(role: meta.thing == .music ? .artist : .author, name: author)]
        }
    }

    /// Top-level objects, arrays and @graph lists, all as plain objects.
    private static func flatten(_ json: Any) -> [[String: Any]] {
        if let list = json as? [Any] { return list.flatMap(flatten) }
        guard let o = json as? [String: Any] else { return [] }
        return [o] + ((o["@graph"] as? [Any])?.flatMap(flatten) ?? [])
    }

    private static func types(_ o: [String: Any]) -> [String] {
        let t = o["@type"]
        return ((t as? [String]) ?? (t as? String).map { [$0] } ?? []).map { $0.lowercased() }
    }

    /// "Name", {"name": "Name"} or a list of either.
    private static func names(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.flatMap(names) }
        let raw = (value as? String) ?? ((value as? [String: Any])?["name"] as? String)
        guard let name = raw.flatMap({ clean(decode($0)) }), !name.contains("://") else { return [] }
        return [name]
    }

    /// The date part of "2021-10-22T00:00:00Z", "2021-10" or "2021".
    private static func day(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let m = firstMatch(#"^(\d{4}(?:-\d{2}(?:-\d{2})?)?)"#, in: t) else { return nil }
        return m
    }

    /// Pages can point og:image anywhere; only ever fetch web addresses.
    static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// Downloads an image and decodes it at most `maxPixel` on the long side.
    static func image(_ url: URL, maxPixel: Int) async -> CGImage? {
        guard isWeb(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return Thumbnailer.decode(source: source, maxPixel: maxPixel)
    }

    static func imageData(_ url: URL) async -> Data? {
        guard isWeb(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceGetCount($0) > 0 ? $0 : nil }) != nil
        else { return nil }
        return data
    }

    // MARK: Tiny HTML helpers (no parser needed for <head> tags)

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch(#"\b"# + name + #"\s*=\s*"([^"]*)""#, in: tag)
            ?? firstMatch(#"\b"# + name + #"\s*=\s*'([^']*)'"#, in: tag)
    }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func decode(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities: &#8217; &#x2019;
        guard let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: hex ? 16 : 10), let scalar = UnicodeScalar(v) {
                result.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
