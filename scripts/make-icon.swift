// Renders the app icon (1024×1024 PNG) with CoreGraphics so it can be regenerated.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
// Apple's macOS icon grid: 824pt artwork centered on a 1024 canvas.
let artwork: CGFloat = 824
let inset = (canvas - artwork) / 2
let cornerRadius = artwork * 0.2237

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawBackground(in ctx: CGContext, rect: CGRect) {
    let shape = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x2A1FB8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x3B2BD9), color(0x2F6BF2), color(0x16C2F5)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    // Top gloss for depth.
    let gloss = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gloss,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY),
        options: []
    )
    ctx.restoreGState()
}

func drawRefreshRing(in ctx: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
    // Clockwise "refresh" ring with a gap at the top; the arrowhead points into the gap.
    let degree = CGFloat.pi / 180
    let start = 60 * degree   // ring begins right of the gap…
    let end = 130 * degree    // …and runs clockwise all the way round to the left of it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x0A0A40, alpha: 0.30))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    // In CoreGraphics' y-up space `clockwise: true` decreases the angle (visually clockwise).
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end - 2 * .pi, clockwise: true)
    ctx.strokePath()

    // Arrowhead sits on the ring end, pointing along the clockwise direction of travel.
    let base = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
    let travel = CGPoint(x: sin(end), y: -cos(end))
    let radial = CGPoint(x: cos(end), y: sin(end))
    let length = lineWidth * 1.7
    let half = lineWidth * 1.25
    let apex = CGPoint(x: base.x + travel.x * length, y: base.y + travel.y * length)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.move(to: apex)
    ctx.addLine(to: CGPoint(x: base.x + radial.x * half, y: base.y + radial.y * half))
    ctx.addLine(to: CGPoint(x: base.x - radial.x * half, y: base.y - radial.y * half))
    ctx.closePath()
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func drawDownArrow(in ctx: CGContext, center: CGPoint, size: CGFloat) {
    let shaftWidth = size * 0.22
    let headWidth = size * 0.62
    let headHeight = size * 0.40
    let top = center.y + size * 0.48
    let bottom = center.y - size * 0.48
    let headBase = bottom + headHeight

    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - shaftWidth / 2, y: top))
    path.addLine(to: CGPoint(x: center.x + shaftWidth / 2, y: top))
    path.addLine(to: CGPoint(x: center.x + shaftWidth / 2, y: headBase))
    path.addLine(to: CGPoint(x: center.x + headWidth / 2, y: headBase))
    path.addLine(to: CGPoint(x: center.x, y: bottom))
    path.addLine(to: CGPoint(x: center.x - headWidth / 2, y: headBase))
    path.addLine(to: CGPoint(x: center.x - shaftWidth / 2, y: headBase))
    path.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x0A0A40, alpha: 0.30))
    // Fill and soften the corners in one layer so the shadow is cast once.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(size * 0.06)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func renderIcon() -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let tile = CGRect(x: inset, y: inset, width: artwork, height: artwork)
    drawBackground(in: ctx, rect: tile)
    let center = CGPoint(x: tile.midX, y: tile.midY)
    drawRefreshRing(in: ctx, center: center, radius: artwork * 0.30, lineWidth: artwork * 0.065)
    drawDownArrow(in: ctx, center: center, size: artwork * 0.34)
    return ctx.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(64)
}
let bitmap = NSBitmapImageRep(cgImage: renderIcon())
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
