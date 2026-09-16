// Renders Resources/AppIcon.icns: swift scripts/make-icon.swift
import AppKit

func ring(_ ctx: CGContext, center: CGPoint, radius: CGFloat, fraction: Double, ticks: Int, length: CGFloat, width: CGFloat) {
    let lit = Int((fraction * Double(ticks)).rounded())
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    for tick in 0..<ticks {
        let angle = Double(tick) / Double(ticks) * 2 * .pi + .pi / 2   // clockwise from the top in flipped-free coordinates
        let direction = CGPoint(x: -cos(angle), y: sin(angle))
        let color: NSColor = tick >= lit ? NSColor(white: 0.24, alpha: 1)
            : tick == lit - 1 ? NSColor(red: 1, green: 0.31, blue: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        ctx.setStrokeColor(color.cgColor)
        ctx.move(to: CGPoint(x: center.x + direction.x * (radius - length), y: center.y + direction.y * (radius - length)))
        ctx.addLine(to: CGPoint(x: center.x + direction.x * radius, y: center.y + direction.y * radius))
        ctx.strokePath()
    }
}

func draw(_ ctx: CGContext) {
    let accent = NSColor(red: 1, green: 0.31, blue: 0.16, alpha: 1).cgColor

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

    // Dot grid texture.
    ctx.setFillColor(NSColor(white: 1, alpha: 0.045).cgColor)
    for x in stride(from: 124.0, to: 924, by: 28) {
        for y in stride(from: 124.0, to: 924, by: 28) { ctx.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)) }
    }
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // The pill.
    let pill = CGRect(x: 392, y: 190, width: 240, height: 644)
    let pillPath = CGPath(roundedRect: pill, cornerWidth: 120, cornerHeight: 120, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor.black.withAlphaComponent(0.7).cgColor)
    ctx.addPath(pillPath)
    ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.clip()
    let pillGradient = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0.2, alpha: 1).cgColor, NSColor(white: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(pillGradient, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(pillPath)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor)
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Three gauges, the top one highlighted with an orange core.
    let centers = [CGPoint(x: 512, y: 712), CGPoint(x: 512, y: 512), CGPoint(x: 512, y: 312)]
    let fractions = [0.72, 0.45, 0.88]
    for (i, center) in centers.enumerated() {
        ring(ctx, center: center, radius: 78, fraction: fractions[i], ticks: 32, length: 22, width: 9)
    }
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: 512 - 20, y: 712 - 20, width: 40, height: 40))
    ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
    for center in centers.dropFirst() {
        ctx.fillEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))
    }
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
