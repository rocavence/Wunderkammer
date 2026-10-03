// App icon: the Reicon "cabinet" in ink on a sheet of paper.
// 用法：swift scripts/icon/make-icon.swift <輸出的 1024 PNG>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024
let glyphURL = URL(fileURLWithPath: "Wunderkammer/Resources/Assets.xcassets/Reicon/cabinet.filled.imageset/cabinet.filled.svg")
guard let glyph = NSImage(contentsOf: glyphURL),
      let mask = glyph.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 40)]) else {
    fatalError("Reicon cabinet missing: run python3 scripts/reicon/generate.py")
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// macOS icon grid: 824 pt body centred in 1024, continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(shape)
ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Paper: lighter at the top, a touch warmer at the bottom.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let paper = CGGradient(colorsSpace: srgb, colors: [
    CGColor(srgbRed: 0.975, green: 0.962, blue: 0.935, alpha: 1),
    CGColor(srgbRed: 0.918, green: 0.890, blue: 0.835, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
// A faint inner edge, like the rim of a card.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
ctx.setLineWidth(4)
ctx.strokePath()

// The cabinet, in ink, with a soft shadow on the paper.
let g: CGFloat = 470
let glyphRect = CGRect(x: (size - g) / 2, y: (size - g) / 2 - 6, width: g, height: g)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(srgbRed: 0.25, green: 0.18, blue: 0.1, alpha: 0.28))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.clip(to: glyphRect, mask: mask)
let ink = CGGradient(colorsSpace: srgb, colors: [
    CGColor(srgbRed: 0.20, green: 0.17, blue: 0.14, alpha: 1),
    CGColor(srgbRed: 0.11, green: 0.09, blue: 0.08, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: glyphRect.maxY), end: CGPoint(x: 0, y: glyphRect.minY), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("寫入 \(out.path)")
