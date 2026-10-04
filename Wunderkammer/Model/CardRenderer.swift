import AppKit
import CoreText

/// Draws the cabinet representation for things that aren't pictures: text,
/// web pages without a preview image, audio without artwork, generic files.
/// Quiet, editorial cards: paper, ink, a serif. Pure CoreGraphics/CoreText so
/// it runs off the main thread.
enum CardRenderer {
    static let paper = CGColor(srgbRed: 0.953, green: 0.937, blue: 0.902, alpha: 1)
    static let ink = CGColor(srgbRed: 0.13, green: 0.12, blue: 0.10, alpha: 1)
    static let muted = CGColor(srgbRed: 0.45, green: 0.42, blue: 0.37, alpha: 1)
    static let rule = CGColor(srgbRed: 0.80, green: 0.77, blue: 0.71, alpha: 1)
    static let night = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)

    /// Pixels per point: cards are drawn at 2× so they stay crisp when large.
    private static let scale: CGFloat = 2

    // MARK: Cards

    /// A quote-like card. Short text gets large type; long text a page.
    static func text(_ text: String, source: String?) -> CGImage? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = body.count < 140
        var size = short ? CGSize(width: 480, height: 360) : CGSize(width: 420, height: 525)
        if short {
            // As tall as the words need (within reason), not a fixed sheet of empty paper.
            let fontSize = Self.shortSize(body)
            let words = serif(body, size: fontSize, lineHeight: 1.25)
            let height = words.boundingRect(with: CGSize(width: 480 - 72, height: 1000), options: [.usesLineFragmentOrigin]).height
            size.height = min(360, max(220, ceil(height) + 34 * 2 + (source == nil ? 0 : 34) + 24))
        }
        return draw(size) { ctx, rect in
            fill(ctx, rect, paper)
            let inset = rect.insetBy(dx: 36, dy: 34)
            var footer: CGFloat = 0
            if let source, !source.isEmpty {
                // Large enough to read once the card is a tile.
                footer = 34
                let site = source.hasPrefix("www.") ? String(source.dropFirst(4)) : source
                drawText(ctx, label(site, size: 13, color: muted, tracking: 0.2),
                         in: CGRect(x: inset.minX, y: inset.maxY - 17, width: inset.width, height: 18))
            }
            let fontSize: CGFloat = short ? Self.shortSize(body) : 14
            let clipped = String(body.prefix(short ? 140 : 900))
            drawText(ctx, serif(clipped, size: fontSize, lineHeight: short ? 1.25 : 1.45),
                     in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height - footer),
                     fadeBottom: !short)
        }
    }

    /// A short note is set large, but a two-word phrase doesn't become a poster.
    static func shortSize(_ body: String) -> CGFloat { min(26, max(20, 30 - CGFloat(body.count) / 12)) }

    /// A page without a preview image: site, title, description.
    static func web(title: String, domain: String, description: String?, favicon: CGImage?) -> CGImage? {
        let size = CGSize(width: 480, height: 300)
        return draw(size) { ctx, rect in
            fill(ctx, rect, paper)
            let inset = rect.insetBy(dx: 32, dy: 28)
            var x = inset.minX
            if let favicon {
                drawImage(ctx, favicon, in: CGRect(x: x, y: inset.minY, width: 16, height: 16))
                x += 24
            }
            drawText(ctx, label(domain.uppercased(), size: 10, color: muted, tracking: 1.2),
                     in: CGRect(x: x, y: inset.minY + 1, width: inset.maxX - x, height: 16))
            ctx.setFillColor(rule)
            ctx.fill(CGRect(x: inset.minX, y: inset.minY + 30, width: inset.width, height: 0.5))
            let titleRect = CGRect(x: inset.minX, y: inset.minY + 46, width: inset.width, height: 120)
            drawText(ctx, heading(title, size: 24, lineHeight: 1.18), in: titleRect)
            if let description, !description.isEmpty {
                drawText(ctx, sans(description, size: 12, color: muted, lineHeight: 1.4),
                         in: CGRect(x: inset.minX, y: inset.minY + 172, width: inset.width, height: inset.maxY - inset.minY - 172),
                         fadeBottom: true)
            }
        }
    }

    /// A page with no picture of its own: the top of the page as a plate,
    /// then its name and site below on paper, like a catalogue entry —
    /// not a whole browser window shrunk to grey.
    static func pageShot(_ shot: CGImage, title: String, domain: String, favicon: CGImage?) -> CGImage? {
        let plate = CGRect(x: 0, y: 0, width: 600, height: 340)
        // As tall as the name needs: one line or two.
        let name = heading(title, size: 24, lineHeight: 1.15)
        let nameHeight = min(64, ceil(name.boundingRect(with: CGSize(width: 600 - 64, height: 200), options: [.usesLineFragmentOrigin]).height))
        let size = CGSize(width: 600, height: plate.maxY + 22 + 26 + nameHeight + 26)
        // The top of the page, as wide as the card.
        let cropHeight = min(CGFloat(shot.height), CGFloat(shot.width) * plate.height / plate.width)
        let top = shot.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(shot.width), height: cropHeight)) ?? shot
        return draw(size) { ctx, rect in
            fill(ctx, rect, paper)
            drawImage(ctx, top, in: plate)
            ctx.setFillColor(rule)
            ctx.fill(CGRect(x: 0, y: plate.maxY, width: size.width, height: 0.5))
            let inset = CGRect(x: 32, y: plate.maxY + 22, width: size.width - 64, height: size.height - plate.maxY - 44)
            var x = inset.minX
            if let favicon {
                drawImage(ctx, favicon, in: CGRect(x: x, y: inset.minY + 1, width: 14, height: 14))
                x += 22
            }
            let site = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
            drawText(ctx, label(site, size: 13, color: muted, tracking: 0.2), in: CGRect(x: x, y: inset.minY, width: inset.maxX - x, height: 18))
            drawText(ctx, name, in: CGRect(x: inset.minX, y: inset.minY + 26, width: inset.width, height: nameHeight + 4))
        }
    }

    /// Audio without artwork: title, artist, and the waveform.
    static func audio(title: String, artist: String?, waveform: [Float]) -> CGImage? {
        let size = CGSize(width: 400, height: 400)
        return draw(size) { ctx, rect in
            fill(ctx, rect, night)
            let inset = rect.insetBy(dx: 32, dy: 32)
            let bars = max(waveform.count, 1)
            let w = inset.width / CGFloat(bars)
            let mid = rect.midY + 20
            ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.90, blue: 0.84, alpha: 0.9))
            for (i, v) in waveform.enumerated() {
                let h = max(2, CGFloat(v) * 120)
                ctx.fill(CGRect(x: inset.minX + CGFloat(i) * w + w * 0.2, y: mid - h / 2, width: w * 0.6, height: h))
            }
            let paperText = CGColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 1)
            drawText(ctx, heading(title, size: 22, color: paperText, lineHeight: 1.2),
                     in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 60))
            if let artist {
                drawText(ctx, label(artist.uppercased(), size: 10, color: CGColor(gray: 0.6, alpha: 1), tracking: 1.2),
                         in: CGRect(x: inset.minX, y: inset.maxY - 14, width: inset.width, height: 16))
            }
        }
    }

    /// Any other file: its kind in large type, then the name.
    static func file(name: String, ext: String, detail: String?) -> CGImage? {
        let size = CGSize(width: 360, height: 450)
        return draw(size) { ctx, rect in
            fill(ctx, rect, paper)
            let inset = rect.insetBy(dx: 30, dy: 30)
            let tag = ext.isEmpty ? "FILE" : ext.uppercased()
            drawText(ctx, serif(tag, size: 64, lineHeight: 1), in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 90))
            ctx.setFillColor(rule)
            ctx.fill(CGRect(x: inset.minX, y: inset.maxY - 70, width: inset.width, height: 0.5))
            drawText(ctx, sans(name, size: 13, color: ink, lineHeight: 1.3),
                     in: CGRect(x: inset.minX, y: inset.maxY - 60, width: inset.width, height: 40))
            if let detail {
                drawText(ctx, label(detail.uppercased(), size: 9, color: muted, tracking: 1),
                         in: CGRect(x: inset.minX, y: inset.maxY - 12, width: inset.width, height: 14))
            }
        }
    }

    /// Puts a picture on the card background (favicon-sized logos, odd aspect art).
    static func framed(_ image: CGImage, size: CGSize = CGSize(width: 400, height: 300)) -> CGImage? {
        draw(size) { ctx, rect in
            fill(ctx, rect, paper)
            let s = min(rect.width * 0.5 / CGFloat(image.width), rect.height * 0.5 / CGFloat(image.height), 4)
            let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
            drawImage(ctx, image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        }
    }

    // MARK: Drawing

    /// A top-left-origin context of `size` points at 2×.
    private static func draw(_ size: CGSize, _ body: (CGContext, CGRect) -> Void) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        body(ctx, CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// Draws a bitmap into a top-left rect (CGContext.draw would flip it).
    private static func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    /// Draws text into a rect given in top-left coordinates.
    private static func drawText(_ ctx: CGContext, _ text: NSAttributedString, in rect: CGRect, fadeBottom: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        // CoreText wants a bottom-left origin: flip back locally.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: local, transform: nil), nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
        if fadeBottom {
            // Fade into the paper instead of cutting a line in half.
            let fade = CGRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 36)
            let colors = [paper.copy(alpha: 0)!, paper] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: fade)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: fade.minY), end: CGPoint(x: 0, y: fade.maxY), options: [])
                ctx.restoreGState()
            }
        }
    }

    /// Titles on cards: the app's display face (Chinese in PingFang, not Songti).
    private static func heading(_ s: String, size: CGFloat, color: CGColor = ink, lineHeight: CGFloat) -> NSAttributedString {
        attributed(s, font: Typography.display(size) ?? .systemFont(ofSize: size), color: color, lineHeight: lineHeight)
    }

    /// New York for Latin; Chinese in Songti TC, whose punctuation sits right.
    /// (Left to the system, CJK falls back to a font with gaps around ，。)
    private static func serif(_ s: String, size: CGFloat, color: CGColor = ink, lineHeight: CGFloat) -> NSAttributedString {
        let ideographs = s.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let letters = max(s.unicodeScalars.filter { $0.properties.isAlphabetic }.count, 1)
        if Double(ideographs) / Double(letters) > 0.3, let song = NSFont(name: "STSongti-TC-Regular", size: size) {
            return attributed(s, font: song, color: color, lineHeight: lineHeight + 0.15)
        }
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        descriptor = descriptor.addingAttributes([.cascadeList: [NSFontDescriptor(name: "STSongti-TC-Regular", size: size)]])
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        return attributed(s, font: font, color: color, lineHeight: lineHeight)
    }

    private static func sans(_ s: String, size: CGFloat, color: CGColor, lineHeight: CGFloat) -> NSAttributedString {
        attributed(s, font: .systemFont(ofSize: size), color: color, lineHeight: lineHeight)
    }

    private static func label(_ s: String, size: CGFloat, color: CGColor, tracking: CGFloat) -> NSAttributedString {
        let a = NSMutableAttributedString(attributedString: attributed(s, font: .systemFont(ofSize: size, weight: .medium),
                                                                       color: color, lineHeight: 1))
        a.addAttribute(.kern, value: tracking, range: NSRange(location: 0, length: a.length))
        return a
    }

    private static func attributed(_ s: String, font: NSFont, color: CGColor, lineHeight: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: style,
        ])
    }
}
