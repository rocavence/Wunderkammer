import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decodes images off the main thread at the size they're actually shown,
/// and keeps recent decodes in memory.
@MainActor
final class Thumbnailer {
    /// Decoded images, least recently used dropped first. NSCache's limits
    /// are only hints (3,000 thumbnails stayed resident); this one is strict.
    private let cache = ImageCache(limit: 384 * 1024 * 1024)
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()
    /// One decode per key; several views may wait on it. Each wait has a token
    /// so one view giving up doesn't cancel the image for another.
    private var pending: [NSString: (op: Operation, waiters: [Int: @MainActor (CGImage) -> Void])] = [:]
    private var nextToken = 0

    struct Request: Hashable {
        fileprivate let key: NSString
        fileprivate let token: Int
    }

    init() {}

    /// Size buckets so nearby zoom levels share one decode. Small tiles get
    /// small decodes: a zoomed-out wall of thousands stays light.
    static func bucket(for pixels: CGFloat) -> Int {
        if pixels <= 160 { return 160 }
        if pixels <= 320 { return 320 }
        if pixels <= CGFloat(Library.thumbnailSize) { return Library.thumbnailSize }
        if pixels <= 1200 { return 1200 }
        return 2400
    }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache[Self.key(url, maxPixel)]
    }

    /// Calls `completion` on the main actor once decoded (right away if cached).
    /// Returns a request to cancel, or nil when it was already answered.
    @discardableResult
    func load(_ url: URL, maxPixel: Int, completion: @escaping @MainActor (CGImage) -> Void) -> Request? {
        let key = Self.key(url, maxPixel)
        let keyString = key as String
        if let image = cache[key] { completion(image); return nil }
        nextToken += 1
        let request = Request(key: key, token: nextToken)
        if pending[key] != nil {
            pending[key]!.waiters[request.token] = completion
            return request
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, weak self] in
            guard op?.isCancelled == false,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = Self.decode(source: source, maxPixel: maxPixel) else { return }
            let box = ImageBox(image: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(keyString as NSString, box.image) }
            }
        }
        pending[key] = (op, [request.token: completion])
        queue.addOperation(op)
        return request
    }

    private func finish(_ key: NSString, _ image: CGImage) {
        cache.insert(image, for: key)
        // A newer decode may own this key if ours was cancelled mid-flight; its waiters still want the image.
        let waiters = pending.removeValue(forKey: key)?.waiters ?? [:]
        for waiter in waiters.values { waiter(image) }
    }

    /// Stops waiting; the decode itself is dropped once nobody waits for it.
    func cancel(_ request: Request) {
        guard var entry = pending[request.key] else { return }
        entry.waiters[request.token] = nil
        if entry.waiters.isEmpty {
            entry.op.cancel()
            pending[request.key] = nil
        } else {
            pending[request.key] = entry
        }
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(url.path)" as NSString
    }

    nonisolated static func decode(source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// JPEG has no transparency: transparent areas sit on paper, not black.
    nonisolated static func writeJPEG(_ image: CGImage, to url: URL) {
        var image = image
        if hasAlpha(image),
           let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.setFillColor(CardRenderer.paper)
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let flat = ctx.makeImage() { image = flat }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

private struct ImageBox: @unchecked Sendable { let image: CGImage }

/// A strict LRU of decoded images by byte cost.
@MainActor
final class ImageCache {
    private let limit: Int
    private var images: [NSString: (image: CGImage, cost: Int, tick: Int)] = [:]
    private var total = 0
    private var tick = 0

    init(limit: Int) { self.limit = limit }

    var bytes: Int { total }

    subscript(key: NSString) -> CGImage? {
        guard var entry = images[key] else { return nil }
        tick += 1
        entry.tick = tick
        images[key] = entry
        return entry.image
    }

    func insert(_ image: CGImage, for key: NSString) {
        let cost = image.bytesPerRow * image.height
        if let old = images[key] { total -= old.cost }
        tick += 1
        images[key] = (image, cost, tick)
        total += cost
        guard total > limit else { return }
        // Evict the oldest quarter at once rather than one by one.
        let target = limit * 3 / 4
        for (k, v) in images.sorted(by: { $0.value.tick < $1.value.tick }) {
            guard total > target else { break }
            images[k] = nil
            total -= v.cost
        }
    }
}
