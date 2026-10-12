import SwiftUI

/// The AI tab's icon: a hexagon of dots in the dot-matrix style, the dots shrinking from the center out.
struct DotHex: Shape {
    func path(in rect: CGRect) -> Path {
        // Neighboring dots sit `step` apart; the outer ring's corners are two steps out.
        let step = min(rect.width, rect.height) / 4.5
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        func dot(angle: Double, distance: CGFloat, radius: CGFloat) {
            let a = angle * .pi / 180
            let x = center.x + cos(a) * distance, y = center.y - sin(a) * distance
            path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        dot(angle: 0, distance: 0, radius: step * 0.36)
        for i in 0..<6 {
            let corner = 90 + Double(i) * 60
            dot(angle: corner, distance: step, radius: step * 0.28)
            dot(angle: corner, distance: step * 2, radius: step * 0.2)
            dot(angle: corner + 30, distance: step * sqrt(3), radius: step * 0.2)
        }
        return path
    }
}

/// The notch outline: shoulders that curve out into the menu bar at the top, rounded corners at the bottom.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { (top, bottom) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(top, rect.width / 4, rect.height / 2)
        let bottom = max(0, min(bottom, rect.height - top, rect.width / 2 - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The notch outline turned on its side, for the sidebar docked against a screen edge: shoulders curve out
/// into the edge above and below, and the far corners are rounded.
struct SideNotchShape: Shape {
    var edge: SidebarEdge
    var shoulder: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        // Drawn upright with the screen edge on top, then turned so the top lies along the side.
        let upright = NotchShape(top: shoulder, bottom: corner).path(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
        let turn = edge == .left
            ? CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: rect.minX, ty: rect.minY)
            : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.maxX, ty: rect.minY)
        return upright.applying(turn)
    }
}
