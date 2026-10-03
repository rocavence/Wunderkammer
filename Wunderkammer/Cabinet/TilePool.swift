import AppKit
import QuartzCore

/// Image tiles as plain CALayers, shared by Grid, Canvas and Infinity. The
/// owning view says which items sit where; the pool creates, moves, animates
/// and recycles layers and keeps each one at the resolution it's shown at.
@MainActor
final class TilePool {
    static let animation: CFTimeInterval = 0.32
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    let library: Library
    let thumbnailer: Thumbnailer
    weak var host: CALayer?
    var cornerRadius: CGFloat = 6

    /// Keyed by an arbitrary string so Infinity can show one item many times.
    private(set) var tiles: [String: CALayer] = [:]
    private var tileItem: [String: Item] = [:]
    /// What each tile shows or is loading: "bucket|path".
    private var tileSource: [String: String] = [:]
    private var tileRequests: [String: [Thumbnailer.Request]] = [:]
    private var pruneWork: DispatchWorkItem?

    init(library: Library, thumbnailer: Thumbnailer) {
        self.library = library
        self.thumbnailer = thumbnailer
    }

    struct Placement {
        var key: String
        var item: Item
        var frame: CGRect
        var selected = false
        var z: CGFloat = 0
    }

    /// Lays out exactly these tiles. Others leave: deleted items shrink away,
    /// the rest are dropped once any running animation is done.
    func apply(_ placements: [Placement], animated: Bool, scale: CGFloat, duration: CFTimeInterval = animation,
               spring: Bool = false) {
        // While the preview is open the neighbours are pushed aside; leave them be.
        guard let host, !isScattered else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(Self.curve)
        }

        var keep = Set<String>()
        for p in placements {
            keep.insert(p.key)
            tileItem[p.key] = p.item
            let tile: CALayer
            if let existing = tiles[p.key] {
                tile = existing
            } else {
                tile = makeTile()
                tiles[p.key] = tile
                if animated {
                    // New tile: grow out of its destination instead of popping in.
                    withoutAnimation {
                        tile.frame = p.frame
                        tile.opacity = 0
                        tile.transform = CATransform3DMakeScale(0.85, 0.85, 1)
                    }
                }
                host.addSublayer(tile)
            }
            // Only touch what changed: re-setting a value would restart a running
            // animation with this transaction's timing.
            // Transform first: `frame` is only meaningful with an identity transform.
            if !CATransform3DIsIdentity(tile.transform) { tile.transform = CATransform3DIdentity }
            if tile.frame != p.frame {
                if animated && spring && tile.superlayer != nil && tile.opacity > 0 {
                    springFrame(tile, to: p.frame)
                } else {
                    tile.frame = p.frame
                }
            }
            if tile.opacity != 1 { tile.opacity = 1 }
            if tile.zPosition != p.z { tile.zPosition = p.z }
            let border: CGFloat = p.selected ? 3 : 0
            if tile.borderWidth != border { withoutAnimation { tile.borderWidth = border } }
            updateBadge(tile, item: p.item, size: p.frame.size, scale: scale)
            loadImage(key: p.key, item: p.item, into: tile, pixels: max(p.frame.width, p.frame.height) * scale)
        }

        for (key, tile) in tiles where !keep.contains(key) {
            if let item = tileItem[key], library.item(item.id) == nil {
                tile.opacity = 0
                tile.transform = CATransform3DMakeScale(0.6, 0.6, 1)
            }
        }
        CATransaction.commit()

        pruneWork?.cancel()
        let prune = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.prune(keeping: keep) }
        }
        pruneWork = prune
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? max(duration, Self.animation) : 0), execute: prune)
    }

    /// Freezes every tile where it is on screen right now (mid-animation
    /// included), shifted by `dy`. Called when the scroll position jumps, so the
    /// next animation starts from what the user sees instead of jumping.
    func rebase(dy: CGFloat) {
        withoutAnimation {
            for tile in tiles.values {
                let now = tile.presentation() ?? tile
                let position = now.position, bounds = now.bounds
                let opacity = now.opacity, transform = now.transform
                tile.removeAllAnimations()
                tile.transform = transform
                tile.bounds = bounds
                tile.position = CGPoint(x: position.x, y: position.y + dy)
                tile.opacity = opacity
            }
        }
        // Implicit animations start from what's on screen, not from the model,
        // so put the shifted positions on screen before anything animates.
        CATransaction.flush()
    }

    // MARK: Ripple

    /// Frames the scattered tiles came from, to spring back to.
    private var homes: [String: CGRect] = [:]
    private var hiddenKey: String?
    var isScattered: Bool { !homes.isEmpty || hiddenKey != nil }

    /// Pushes every tile away from `center`: the nearest fly farthest, the push
    /// fading with distance. Both scale with tile size, like Atlas's Push/Reach.
    /// The tile under `key` is hidden: the preview flies in its place.
    func scatter(from center: CGPoint, hiding key: String?) {
        homes = [:]
        hiddenKey = key
        let sizes = tiles.values.map { max($0.bounds.width, $0.bounds.height) }.sorted()
        let tileSize = sizes.isEmpty ? 156 : sizes[sizes.count / 2]
        let push = tileSize * 3.2
        let reach = tileSize * 4
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.2, 1))
        for (k, tile) in tiles {
            if k == key {
                withoutAnimation { tile.opacity = 0 }
                continue
            }
            let f = tile.frame
            var v = CGVector(dx: f.midX - center.x, dy: f.midY - center.y)
            var d = hypot(v.dx, v.dy)
            if d < 1 { v = CGVector(dx: 0, dy: 1); d = 1 }
            let amount = push * exp(-d / reach) + tileSize * 0.3
            homes[k] = f
            tile.position = CGPoint(x: tile.position.x + v.dx / d * amount, y: tile.position.y + v.dy / d * amount)
            tile.opacity = 0
        }
        CATransaction.commit()
    }

    /// Puts everything back home as the preview closes. Nothing flies back in:
    /// the tiles fade in where they belong, and when the image lands on
    /// `landing` the neighbours get a small outward nudge and spring back,
    /// strongest next to it and fading with distance.
    func gather(landing: String?) {
        if let old = hiddenKey, old != landing, let tile = tiles[old], homes[old] == nil {
            fadeIn(tile)
        }
        let center = landing.flatMap { homes[$0] ?? tiles[$0]?.frame }.map { CGPoint(x: $0.midX, y: $0.midY) }
        let sizes = homes.values.map { max($0.width, $0.height) }.sorted()
        let tileSize = sizes.isEmpty ? 156 : sizes[sizes.count / 2]
        for (k, home) in homes {
            guard let tile = tiles[k] else { continue }
            tile.removeAllAnimations()
            withoutAnimation {
                tile.frame = home
                tile.opacity = k == landing ? 0 : 1
            }
            guard k != landing else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            tile.add(fade, forKey: "opacity")
            if let center { nudge(tile, awayFrom: center, tileSize: tileSize) }
        }
        homes = [:]
        hiddenKey = landing
    }

    /// Additive push-out-and-spring-back, timed to the image landing.
    private func nudge(_ tile: CALayer, awayFrom center: CGPoint, tileSize: CGFloat) {
        let f = tile.frame
        var v = CGVector(dx: f.midX - center.x, dy: f.midY - center.y)
        let d = max(hypot(v.dx, v.dy), 1)
        v = CGVector(dx: v.dx / d, dy: v.dy / d)
        let amount = tileSize * 0.22 * exp(-d / (tileSize * 2.5))
        guard amount > 0.5 else { return }
        let offset = NSValue(point: CGPoint(x: v.dx * amount, y: v.dy * amount))
        let zero = NSValue(point: .zero)
        let landing: CFTimeInterval = 0.2

        let out = CABasicAnimation(keyPath: "position")
        out.fromValue = zero
        out.toValue = offset
        out.duration = 0.09
        out.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let back = CASpringAnimation(perceptualDuration: 0.45, bounce: 0.35)
        back.keyPath = "position"
        back.fromValue = offset
        back.toValue = zero
        back.beginTime = 0.09
        back.duration = back.settlingDuration

        let group = CAAnimationGroup()
        group.animations = [out, back]
        out.isAdditive = true
        back.isAdditive = true
        group.duration = 0.09 + back.settlingDuration
        group.beginTime = CACurrentMediaTime() + landing
        tile.add(group, forKey: "nudge")
    }

    private func fadeIn(_ tile: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (tile.presentation() ?? tile).opacity
        fade.toValue = 1
        fade.duration = 0.28
        withoutAnimation { tile.opacity = 1 }
        tile.add(fade, forKey: "opacity")
    }

    /// Shows the tile the preview landed on and ends the scattered state.
    func revealHidden() {
        if let k = hiddenKey, let tile = tiles[k] { withoutAnimation { tile.opacity = 1 } }
        hiddenKey = nil
    }

    func removeAll() {
        pruneWork?.cancel()
        prune(keeping: [])
    }

    func setSelected(_ keys: Set<String>) {
        withoutAnimation {
            for (key, tile) in tiles { tile.borderWidth = keys.contains(key) ? 3 : 0 }
        }
    }

    func image(_ key: String) -> CGImage? {
        (tiles[key]?.contents).map { $0 as! CGImage }
    }

    private func prune(keeping keep: Set<String>) {
        withoutAnimation {
            for (key, tile) in tiles where !keep.contains(key) {
                tile.removeFromSuperlayer()
                tiles[key] = nil
                tileSource[key] = nil
                for request in tileRequests.removeValue(forKey: key) ?? [] { thumbnailer.cancel(request) }
                tileItem[key] = nil
            }
        }
    }

    /// What a tile is, when the picture doesn't say: a site, a duration, pages.
    static func badgeText(_ item: Item) -> String? {
        switch item.kind {
        case .web: return item.domain
        case .video, .audio: return item.duration.map(InspectorViewController.duration)
        case .pdf: return item.pageCount.map { "PDF · \($0) 頁" } ?? "PDF"
        case .file: return (item.originalFilename as NSString).pathExtension.uppercased().nilIfEmpty
        case .image: return item.fileType == "com.compuserve.gif" ? "GIF" : nil
        case .text: return nil
        }
    }

    private func updateBadge(_ tile: CALayer, item: Item, size: CGSize, scale: CGFloat) {
        let text = Self.badgeText(item)
        let badge = tile.sublayers?.first { $0.name == "badge" }
        guard let text, size.width >= 90, size.height >= 50 else {
            withoutAnimation { badge?.isHidden = true }
            return
        }
        // A dark pill with the text centred in it.
        let pill = badge ?? {
            let b = CALayer()
            b.name = "badge"
            b.cornerRadius = 4
            b.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            let t = CATextLayer()
            t.alignmentMode = .center
            t.truncationMode = .end
            b.addSublayer(t)
            tile.addSublayer(b)
            return b
        }()
        let label = pill.sublayers!.first as! CATextLayer
        withoutAnimation {
            pill.isHidden = false
            label.contentsScale = scale
            let font = NSFont.systemFont(ofSize: 10, weight: .medium)
            if (label.string as? NSAttributedString)?.string != text {
                label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            }
            let w = min((text as NSString).size(withAttributes: [.font: font]).width + 12, size.width - 16)
            pill.frame = CGRect(x: 8, y: size.height - 26, width: w, height: 18)
            label.frame = CGRect(x: 4, y: 2.5, width: w - 8, height: 14)
        }
    }

    private func makeTile() -> CALayer {
        let tile = CALayer()
        tile.contentsGravity = .resizeAspectFill
        tile.masksToBounds = true
        tile.cornerRadius = cornerRadius
        tile.cornerCurve = .continuous
        tile.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        tile.borderColor = NSColor.controlAccentColor.cgColor
        tile.minificationFilter = .trilinear
        return tile
    }

    /// Small sizes come from the representation. Large pictures from the
    /// original; everything else only has its representation.
    private func imageURL(_ item: Item, bucket: Int) -> URL {
        guard bucket > Library.thumbnailSize, item.hasFullImage, let original = library.originalURL(item) else {
            return library.thumbnailURL(item)
        }
        return original
    }

    /// Shows whatever resolution is ready now, then upgrades when the right one decodes.
    private func loadImage(key: String, item: Item, into tile: CALayer, pixels: CGFloat) {
        let bucket = Thumbnailer.bucket(for: pixels)
        let url = imageURL(item, bucket: bucket)
        let wanted = "\(bucket)|\(url.path)"
        guard tileSource[key] != wanted else { return }
        tileSource[key] = wanted
        // A new size replaces whatever this tile was still waiting for.
        for request in tileRequests.removeValue(forKey: key) ?? [] { thumbnailer.cancel(request) }
        if let image = thumbnailer.cached(url, maxPixel: bucket) {
            setContents(tile, image)
            return
        }
        var requests: [Thumbnailer.Request] = []
        if tile.contents == nil, bucket != Library.thumbnailSize {
            // Nothing on screen yet: show the small thumbnail first.
            let r = thumbnailer.load(library.thumbnailURL(item), maxPixel: Library.thumbnailSize) { [weak self, weak tile] image in
                guard let self, let tile, self.tiles[key] === tile, tile.contents == nil else { return }
                self.setContents(tile, image, fade: true)
            }
            if let r { requests.append(r) }
        }
        let r = thumbnailer.load(url, maxPixel: bucket) { [weak self, weak tile] image in
            guard let self, let tile, self.tiles[key] === tile, self.tileSource[key] == wanted else { return }
            self.setContents(tile, image, fade: true)
        }
        if let r { requests.append(r) }
        tileRequests[key] = requests
    }

    private func setContents(_ tile: CALayer, _ image: CGImage, fade: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(!fade || tile.contents != nil)
        tile.contents = image
        CATransaction.commit()
    }
}

/// Springs a layer's frame from wherever it is on screen now. A touch of
/// overshoot, then it settles, like Atlas.
@MainActor
func springFrame(_ layer: CALayer, to frame: CGRect, bounce: CGFloat = 0.18, response: CGFloat = 0.42) {
    let now = layer.presentation() ?? layer
    let fromPosition = now.position, fromBounds = now.bounds
    layer.removeAnimation(forKey: "position")
    layer.removeAnimation(forKey: "bounds")
    withoutAnimation { layer.frame = frame }
    for (key, from, to) in [("position", NSValue(point: fromPosition), NSValue(point: layer.position)),
                            ("bounds", NSValue(rect: fromBounds), NSValue(rect: layer.bounds))] {
        let a = CASpringAnimation(perceptualDuration: response, bounce: bounce)
        a.keyPath = key
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        layer.add(a, forKey: key)
    }
}

@MainActor
func withoutAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
