// App icon: the arch (a doorway into the cabinet), on the macOS icon grid.
// 用法：swift scripts/icon/make-icon.swift <輸出的 1024 PNG>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024
guard let art = NSImage(contentsOf: URL(fileURLWithPath: "scripts/icon/arch-source.png"))?
        .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("scripts/icon/arch-source.png missing")
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt body centred in 1024, continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// The body's shadow, then the artwork (white ground and all) clipped to it.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(art, in: body)
ctx.restoreGState()

// A hairline so the white body holds its edge on a light Dock.
ctx.addPath(shape)
ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
ctx.setLineWidth(2)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
