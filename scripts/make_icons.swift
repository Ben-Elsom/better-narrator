// Draws the Better Narrator logo: lines of text with one word lit up in blue,
// the way the app highlights the word being read.
//
// Usage: make_icons <output dir>
// Writes AppIcon_1024.png, MenuBarIcon.png (18pt) and MenuBarIcon@2x.png (36px).
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func png(_ size: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // Flip so y grows downwards, like a page.
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: 1, y: -1)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func pill(_ cg: CGContext, _ r: CGRect) {
    cg.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: - App icon (1024 × 1024, macOS icon grid)

let app = png(1024) { cg in
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0, 0, 0, 0.28))
    cg.addPath(tilePath)
    cg.setFillColor(rgb(30, 64, 175))
    cg.fillPath()
    cg.restoreGState()

    // Deep blue gradient tile.
    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [rgb(64, 132, 255), rgb(37, 72, 214), rgb(28, 40, 138)] as CFArray,
                        locations: [0, 0.55, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Gentle top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(255, 255, 255, 0.18), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])
    cg.restoreGState()

    // Lines of text.
    let h: CGFloat = 54
    let left: CGFloat = 248
    let rows: [(y: CGFloat, parts: [(x: CGFloat, w: CGFloat, lit: Bool)])] = [
        (292, [(left, 528, false)]),
        (404, [(left, 150, false), (left + 186, 222, true), (left + 444, 84, false)]),
        (516, [(left, 360, false)]),
        (628, [(left, 236, false)]),
    ]
    for row in rows {
        for part in row.parts where !part.lit {
            pill(cg, CGRect(x: part.x, y: row.y, width: part.w, height: h))
            cg.setFillColor(rgb(255, 255, 255, 0.55))
            cg.fillPath()
        }
    }
    // The word being read: bright highlight with a glow.
    let word = CGRect(x: left + 186, y: 404, width: 222, height: h)
    let glow = word.insetBy(dx: -26, dy: -24)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 46, color: rgb(125, 211, 252, 0.95))
    pill(cg, glow)
    cg.setFillColor(rgb(125, 211, 252, 0.92))
    cg.fillPath()
    cg.restoreGState()
    pill(cg, word)
    cg.setFillColor(rgb(255, 255, 255, 1))
    cg.fillPath()

    // Three sound waves coming off the last line.
    cg.setStrokeColor(rgb(255, 255, 255, 0.92))
    cg.setLineCap(.round)
    cg.setLineWidth(30)
    let c = CGPoint(x: left + 268, y: 655)
    for (i, radius) in [CGFloat(52), 104, 156].enumerated() {
        cg.setStrokeColor(rgb(255, 255, 255, 0.92 - CGFloat(i) * 0.2))
        cg.addArc(center: c, radius: radius, startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
        cg.strokePath()
    }
}
try! app.write(to: outDir.appendingPathComponent("AppIcon_1024.png"))

// MARK: - Menu bar icon (template: black on transparent)

func menuIcon(_ px: Int) -> Data {
    png(px) { cg in
        let s = CGFloat(px) / 18
        cg.scaleBy(x: s, y: s)
        cg.setFillColor(rgb(0, 0, 0))
        let h: CGFloat = 2.0
        pill(cg, CGRect(x: 1.5, y: 3.0, width: 13.5, height: h)); cg.fillPath()
        pill(cg, CGRect(x: 1.5, y: 7.9, width: 3.0, height: h)); cg.fillPath()
        // highlighted word: a solid block
        cg.addPath(CGPath(roundedRect: CGRect(x: 6.0, y: 6.7, width: 6.8, height: 4.4), cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        cg.fillPath()
        pill(cg, CGRect(x: 1.5, y: 12.9, width: 6.0, height: h)); cg.fillPath()
        // sound waves
        cg.setStrokeColor(rgb(0, 0, 0))
        cg.setLineCap(.round)
        cg.setLineWidth(1.4)
        for r in [CGFloat(2.3), 4.7] {
            cg.addArc(center: CGPoint(x: 11.4, y: 15.0), radius: r, startAngle: -.pi / 4, endAngle: .pi / 5, clockwise: false)
            cg.strokePath()
        }
    }
}
try! menuIcon(18).write(to: outDir.appendingPathComponent("MenuBarIcon.png"))
try! menuIcon(36).write(to: outDir.appendingPathComponent("MenuBarIcon@2x.png"))
print("icons written to \(outDir.path)")
