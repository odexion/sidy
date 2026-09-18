// Renders Resources/AppIcon.icns: swift scripts/make-icon.swift
import AppKit

func draw(_ ctx: CGContext) {
    let accent = NSColor(red: 1, green: 0.31, blue: 0.16, alpha: 1).cgColor
    let ink = NSColor(white: 0.92, alpha: 1)

    // Squircle body on Apple's 1024 grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0.17, alpha: 1).cgColor, NSColor(white: 0.05, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // One dotted disc, like the Now Playing tile: three rings of dots around an orange core.
    let center = CGPoint(x: 512, y: 580)
    let radius: CGFloat = 230
    for (ring, count) in [(1.0, 30), (0.74, 22), (0.5, 14)] {
        let color = ring == 1.0 ? ink : NSColor(white: 0.5, alpha: 0.6)
        ctx.setFillColor(color.cgColor)
        let r = radius * ring
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi
            let dot = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            ctx.fillEllipse(in: CGRect(x: dot.x - 11, y: dot.y - 11, width: 22, height: 22))
        }
    }
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80))

    // The name underneath, set like a tile's label.
    let label = NSAttributedString(string: "SIDY", attributes: [
        .font: NSFont.systemFont(ofSize: 124, weight: .bold),
        .foregroundColor: ink,
        .kern: 10,
    ])
    let size = label.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    label.draw(at: CGPoint(x: 512 - (size.width - 10) / 2, y: 190))
    NSGraphicsContext.restoreGraphicsState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: root.appending(path: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
