import AppKit
import SwiftUI

enum Resource {
    /// Looks in the app bundle, then in ./Resources when running from the command line.
    static func url(_ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private static var images: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = url(name, "svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        images[name] = image
        return image
    }
}

struct IconView: View {
    let icon: Icon

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).resizable().scaledToFit()
        case .asset(let name):
            if let image = Resource.image(name) {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
            }
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.31, blue: 0.16)
    static let ink = Color(white: 0.92)
    static let muted = Color(white: 0.5)
    static let dim = Color(white: 0.2)

    static func display(_ size: CGFloat) -> Font { .custom("Doto", size: size).weight(.black) }
    static let label = Font.system(size: 8.5, weight: .medium, design: .monospaced)
    static let body = Font.system(size: 11, weight: .regular, design: .monospaced)
}

private func dot(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

// MARK: - Card

struct Badge {
    var text: String
    var color: Color = Theme.accent
}

struct Card<Content: View>: View {
    static var size: CGSize { CGSize(width: 184, height: 128) }

    let index: Int
    let title: String
    var badge: Badge?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(String(format: "%02d", index)).foregroundStyle(Theme.ink)
                Text(title.uppercased()).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                if let badge {
                    Circle().fill(badge.color).frame(width: 4, height: 4)
                    Text(badge.text.uppercased()).foregroundStyle(badge.color)
                }
            }
            .font(Theme.label)
            .lineLimit(1)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.145), Color(white: 0.095)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
        )
    }
}

/// A small caption over a value, like "UPTIME / 3d 4h".
struct Stat: View {
    let label: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label.uppercased()).font(Theme.label).foregroundStyle(Theme.muted)
            Text(value).font(Theme.body).foregroundStyle(Theme.ink)
        }
        .lineLimit(1)
    }
}

/// Large dot-matrix number with a small unit, e.g. "42 %".
struct BigValue: View {
    let value: String
    var unit: String = ""
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(Theme.display(size)).foregroundStyle(Theme.ink)
            if !unit.isEmpty {
                Text(unit).font(Theme.label).foregroundStyle(Theme.muted)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

// MARK: - Dot graphics

/// Column-of-dots history chart; the newest column is highlighted.
struct DotBars: View {
    let values: [Double]
    var rows = 7

    var body: some View {
        Canvas { context, size in
            let width = size.width / CGFloat(values.count)
            let height = size.height / CGFloat(rows)
            let radius = min(width, height) * 0.3
            for (column, value) in values.enumerated() {
                let lit = value > 0.005 ? max(1, Int((value * Double(rows)).rounded())) : 0
                let color = column == values.count - 1 ? Theme.accent : Theme.ink
                for row in 0..<rows {
                    let center = CGPoint(x: (CGFloat(column) + 0.5) * width, y: size.height - (CGFloat(row) + 0.5) * height)
                    context.fill(dot(center, radius), with: .color(row < lit ? color : Theme.dim))
                }
            }
        }
    }
}

/// Horizontal dot gauge; the leading edge of the fill is highlighted.
struct DotMeter: View {
    let fraction: Double
    var count = 24
    var rows = 1
    var alert = false

    var body: some View {
        Canvas { context, size in
            let width = size.width / CGFloat(count)
            let height = size.height / CGFloat(rows)
            let radius = min(width, height) * 0.32
            let lit = Int((min(max(fraction, 0), 1) * Double(count)).rounded())
            for column in 0..<count {
                let color: Color = column >= lit ? Theme.dim : (alert || column == lit - 1 ? Theme.accent : Theme.ink)
                for row in 0..<rows {
                    let center = CGPoint(x: (CGFloat(column) + 0.5) * width, y: (CGFloat(row) + 0.5) * height)
                    context.fill(dot(center, radius), with: .color(color))
                }
            }
        }
    }
}

/// Radial tick gauge with a dotted inner ring.
struct DotRing: View {
    let fraction: Double
    var ticks = 48
    var tickLength: CGFloat = 6
    var innerDots = true

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 1
            let lit = Int((min(max(fraction, 0), 1) * Double(ticks)).rounded())
            for tick in 0..<ticks {
                let angle = (Double(tick) / Double(ticks)) * 2 * .pi - .pi / 2
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                var line = Path()
                line.move(to: CGPoint(x: center.x + direction.x * (outer - tickLength), y: center.y + direction.y * (outer - tickLength)))
                line.addLine(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
                let color: Color = tick >= lit ? Theme.dim : (tick == lit - 1 ? Theme.accent : Theme.ink)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

                if innerDots, tick.isMultiple(of: 2) {
                    let inner = outer - 11
                    context.fill(dot(CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner), 0.7),
                                 with: .color(Theme.dim))
                }
            }
        }
    }
}

/// Dotted line chart for one or more normalized (0...1) series; the first series gets an end marker.
struct DotSpark: View {
    let series: [[Double]]
    var colors: [Color] = [Theme.ink, Theme.accent.opacity(0.75)]

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 5
            for (index, values) in series.enumerated().reversed() where values.count > 1 {
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * (size.width - inset * 2) + inset,
                            y: inset + (1 - CGFloat(min(max(v, 0), 1))) * (size.height - inset * 2))
                }
                let color = colors[index % colors.count]
                for (a, b) in zip(points, points.dropFirst()) {
                    let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3.2))
                    for step in 0..<steps {
                        let t = CGFloat(step) / CGFloat(steps)
                        context.fill(dot(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), 0.85), with: .color(color))
                    }
                }
                if index == 0, let last = points.last {
                    context.fill(dot(last, 2.4), with: .color(Theme.accent))
                    context.stroke(dot(last, 4.5), with: .color(Theme.accent.opacity(0.5)), lineWidth: 0.7)
                }
            }
        }
    }
}

/// Concentric dotted "record".
struct DotDisc: View {
    var active: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            for (ring, count) in [(1.0, 30), (0.74, 22), (0.5, 14)] {
                let color = active && ring == 1.0 ? Theme.ink : Theme.muted.opacity(ring == 1.0 ? 0.7 : 0.45)
                for i in 0..<count {
                    let angle = Double(i) / Double(count) * 2 * .pi
                    let r = radius * ring - 1
                    context.fill(dot(CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r), 0.8), with: .color(color))
                }
            }
            context.fill(dot(center, 3), with: .color(active ? Theme.accent : Theme.muted))
        }
    }
}

struct BatteryGlyph: View {
    let level: Double

    var body: some View {
        HStack(spacing: 1.5) {
            DotMeter(fraction: level, count: 8, rows: 2, alert: level < 0.2)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.muted, lineWidth: 1))
            RoundedRectangle(cornerRadius: 1).fill(Theme.muted).frame(width: 2, height: 7)
        }
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ fraction: Double) -> String {
        String(Int((fraction * 100).rounded()))
    }

    /// Returns a compact number and its unit, e.g. ("12.4", "GB").
    static func bytes(_ value: Double, base: Double = 1000) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = value
        var unit = 0
        while value >= base * 0.995, unit < units.count - 1 {
            value /= base
            unit += 1
        }
        let text = value < 10 && unit > 0 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return (text, units[unit])
    }

    static func size(_ value: Double, base: Double = 1000) -> String {
        let (number, unit) = bytes(value, base: base)
        return "\(number) \(unit)"
    }

    /// Tile-sized byte counts, e.g. "14G" or "7.2K".
    static func compact(_ value: Double, base: Double = 1000) -> String {
        let (number, unit) = bytes(value, base: base)
        return number + unit.prefix(1)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let (value, unit) = bytes(bytesPerSecond)
        return "\(value) \(unit)/s"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        switch minutes {
        case ..<60: return "\(minutes)m"
        case ..<1440: return "\(minutes / 60)h \(minutes % 60)m"
        default: return "\(minutes / 1440)d \(minutes / 60 % 24)h"
        }
    }
}
