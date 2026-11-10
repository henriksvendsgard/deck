// Draws the app icon and builds Resources/AppIcon.icns.
// Run: swift Tools/make-icon.swift
import AppKit

let size: CGFloat = 1024
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)

func drawIcon(_ ctx: CGContext) {
    // macOS icon template: 824×824 body centered on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Shadow under the icon
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: blue → indigo
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.29, green: 0.62, blue: 1.00, alpha: 1),
        CGColor(red: 0.36, green: 0.29, blue: 0.93, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // Shine at the top
    let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    func window(_ r: CGRect, fill: CGColor, bar: CGColor, dots: Bool) {
        let p = CGPath(roundedRect: r, cornerWidth: 44, cornerHeight: 44, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(gray: 0, alpha: 0.30))
        ctx.addPath(p)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
        // Title bar
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        ctx.setFillColor(bar)
        ctx.fill(CGRect(x: r.minX, y: r.maxY - 74, width: r.width, height: 74))
        ctx.restoreGState()
        guard dots else { return }
        let colors = [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1),
                      CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                      CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: r.minX + 38 + CGFloat(i) * 50, y: r.maxY - 55, width: 34, height: 34))
        }
    }

    // Back window (translucent) and front window
    window(CGRect(x: 210, y: 400, width: 470, height: 360),
           fill: CGColor(gray: 1, alpha: 0.38), bar: CGColor(gray: 1, alpha: 0.25), dots: false)
    window(CGRect(x: 344, y: 250, width: 470, height: 360),
           fill: CGColor(gray: 1, alpha: 0.97), bar: CGColor(red: 0.90, green: 0.92, blue: 0.97, alpha: 1), dots: true)

    // Switch arrow in the front window
    ctx.setStrokeColor(CGColor(red: 0.36, green: 0.36, blue: 0.93, alpha: 1))
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 470, y: 390)); ctx.addLine(to: CGPoint(x: 690, y: 390))
    ctx.move(to: CGPoint(x: 620, y: 455)); ctx.addLine(to: CGPoint(x: 690, y: 390)); ctx.addLine(to: CGPoint(x: 620, y: 325))
    ctx.strokePath()
}

func png(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)
    drawIcon(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try png(px: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(px: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(px: 1024).write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Created Resources/AppIcon.icns" : "iconutil failed")
