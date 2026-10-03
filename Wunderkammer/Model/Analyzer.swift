import AppKit
import ImageIO
import PDFKit
import Vision

/// Quietly understands what's in the cabinet, on this Mac only: words in
/// pictures (OCR), what's in them (labels), their colours, and a visual
/// fingerprint for finding similar things. Runs in the background, newest
/// first, and never asks anything.
enum Analyzer {
    /// Bump when the analysis improves: older results are redone in the background.
    static let version = 2

    struct Result: Sendable {
        var ocrText: String?
        var labels: [String]
        var colors: [String]
        var featurePrint: Data?
    }

    /// The picture to look at: the original for images, else the representation.
    static func analyze(imageAt url: URL, pdf: URL?, knownText: Bool) -> Result {
        var result = Result(ocrText: nil, labels: [], colors: [], featurePrint: nil)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = Thumbnailer.decode(source: source, maxPixel: 1600) else { return result }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let classify = VNClassifyImageRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        // A fixed language list makes the first one dominate (English read
        // badly with Chinese first, Chinese misread with English first).
        text.automaticallyDetectsLanguage = true
        text.usesLanguageCorrection = true
        var requests: [VNRequest] = [classify, print]
        // Text cards and PDFs already know their words.
        if !knownText && pdf == nil { requests.append(text) }
        try? handler.perform(requests)

        result.labels = (classify.results ?? [])
            .filter { $0.confidence > 0.25 }
            .prefix(10)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        if let observation = print.results?.first {
            result.featurePrint = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        }
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.3 }.map(\.string)
        if !lines.isEmpty { result.ocrText = lines.joined(separator: "\n") }
        if let pdf, let doc = PDFDocument(url: pdf) {
            result.ocrText = doc.string.map { String($0.prefix(20_000)) }
        }
        result.colors = dominantColors(image)
        return result
    }

    // MARK: Colour

    /// Names of the colours covering a meaningful part of the picture, most first.
    static func dominantColors(_ image: CGImage) -> [String] {
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var counts: [String: Int] = [:]
        for i in 0..<(side * side) {
            let r = CGFloat(px[i * 4]) / 255, g = CGFloat(px[i * 4 + 1]) / 255, b = CGFloat(px[i * 4 + 2]) / 255
            counts[name(r, g, b), default: 0] += 1
        }
        let total = Double(side * side)
        return counts.filter { Double($0.value) / total > 0.12 }.sorted { $0.value > $1.value }.map(\.key)
    }

    /// A plain colour word for an sRGB value.
    static func name(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        if v < 0.18 { return "black" }
        if s < 0.14 { return v > 0.85 ? "white" : "gray" }
        let deg = h * 360
        // Dark, low-saturation oranges and reds read as brown.
        if (10..<45).contains(deg), v < 0.6 { return "brown" }
        switch deg {
        case ..<14, 345...: return s < 0.45 && v > 0.7 ? "pink" : "red"
        case ..<40: return "orange"
        case ..<68: return "yellow"
        case ..<165: return "green"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }

    // MARK: Similarity

    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard let x = observation(a), let y = observation(b) else { return nil }
        var d: Float = 0
        return (try? x.computeDistance(&d, to: y)) != nil ? d : nil
    }

    static func observation(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}

/// Feeds unanalysed items through the Analyzer one at a time, in the
/// background, and keeps the visual fingerprints for similarity.
@MainActor
final class Understanding {
    private let library: Library
    private var running = false
    private let printsDir: URL
    private var prints: [UUID: VNFeaturePrintObservation] = [:]
    static let didProgress = Notification.Name("UnderstandingDidProgress")

    init(library: Library) {
        self.library = library
        printsDir = library.root.appendingPathComponent("featureprints")
        try? FileManager.default.createDirectory(at: printsDir, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    var pending: Int { library.items.filter { !$0.analyzed }.count }

    /// Picks up wherever it left off; safe to call often.
    func start() {
        guard !running else { return }
        running = true
        Task { await loop() }
    }

    private func loop() async {
        defer { running = false }
        var done = 0
        while let item = library.items.first(where: { !$0.analyzed && isReady($0) }) {
            let image = item.hasFullImage ? (library.originalURL(item) ?? library.thumbnailURL(item)) : library.thumbnailURL(item)
            let pdf = item.kind == .pdf ? library.originalURL(item) : nil
            let knownText = item.kind == .text
            let id = item.id, printsDir = printsDir
            let result = await Task.detached(priority: .utility) {
                let r = autoreleasepool { Analyzer.analyze(imageAt: image, pdf: pdf, knownText: knownText) }
                if let fp = r.featurePrint { try? fp.write(to: printsDir.appendingPathComponent(id.uuidString)) }
                return r
            }.value
            if let fp = result.featurePrint, let o = Analyzer.observation(fp) { prints[id] = o }
            library.update(id, notify: false) {
                $0.ocrText = result.ocrText ?? $0.ocrText
                $0.labels = result.labels
                $0.colors = result.colors
                $0.analysisVersion = Analyzer.version
            }
            done += 1
            if done % 10 == 0 { NotificationCenter.default.post(name: Self.didProgress, object: self) }
        }
        library.save()
        NotificationCenter.default.post(name: Self.didProgress, object: self)
    }

    /// Web pages are looked at once their own preview has arrived.
    private func isReady(_ item: Item) -> Bool {
        item.kind != .web || item.representationVersion > 0 || Date().timeIntervalSince(item.dateAdded) > 60
    }

    // MARK: Related

    private func featurePrint(_ id: UUID) -> VNFeaturePrintObservation? {
        if let p = prints[id] { return p }
        guard let data = try? Data(contentsOf: printsDir.appendingPathComponent(id.uuidString)),
              let p = Analyzer.observation(data) else { return nil }
        prints[id] = p
        return p
    }

    /// Visually closest first. Empty until the item has been looked at.
    func similar(to id: UUID, in items: [Item]? = nil, limit: Int = 40) -> [Item] {
        guard let target = featurePrint(id) else { return [] }
        let pool = items ?? library.items
        let scored: [(Item, Float)] = pool.compactMap { item in
            guard item.id != id, let p = featurePrint(item.id) else { return nil }
            var d: Float = 0
            guard (try? target.computeDistance(&d, to: p)) != nil else { return nil }
            return (item, d)
        }
        let sorted = scored.sorted { $0.1 < $1.1 }
        guard sorted.count > 6 else { return sorted.map(\.0) }
        // Only the ones clearly closer than the rest: under mean − ½σ,
        // but always a handful and never everything.
        let ds = sorted.map { Double($0.1) }
        let mean = ds.reduce(0, +) / Double(ds.count)
        let sd = (ds.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(ds.count)).squareRoot()
        let close = sorted.filter { Double($0.1) <= mean - sd / 2 }.count
        return sorted.prefix(min(max(close, 6), limit, 24)).map(\.0)
    }

    /// Things that belong together: looks alike, same site, same maker, same
    /// source app, shared subjects, collected the same day.
    func related(to item: Item, limit: Int = 8) -> [Item] {
        var score: [UUID: Double] = [:]
        for (rank, other) in similar(to: item.id, limit: 30).enumerated() {
            score[other.id, default: 0] += 3 * (1 - Double(rank) / 30)
        }
        let labels = Set(item.labels ?? [])
        for other in library.items where other.id != item.id {
            var s = 0.0
            if let d = item.domain, d == other.domain { s += 2 }
            if let c = item.creator, c == other.creator { s += 2 }
            if let a = item.sourceApp, a == other.sourceApp, a != "Screenshot" { s += 0.3 }
            if !labels.isEmpty { s += Double(labels.intersection(other.labels ?? []).count) * 0.6 }
            if Calendar.current.isDate(item.dateAdded, inSameDayAs: other.dateAdded) { s += 0.2 }
            if s > 0 { score[other.id, default: 0] += s }
        }
        return score.filter { $0.value > 0.8 }.sorted { $0.value > $1.value }.prefix(limit).compactMap { library.item($0.key) }
    }
}
