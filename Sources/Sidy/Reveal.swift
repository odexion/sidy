import SwiftUI

/// The opening animation: the pill unfolds from its middle and its contents settle in from the center outward.
extension EnvironmentValues {
    @Entry var revealed = true
}

extension View {
    /// Fades, sharpens and grows the view into place once the sidebar is revealed.
    /// `rank` is the distance from the center item; higher ranks arrive later.
    func reveal(rank: Int, delay: Double = 0.4, scale: CGFloat = 0.7) -> some View {
        modifier(Reveal(rank: rank, delay: delay, scale: scale))
    }
}

/// Distance of `index` from the middle of `count` items, so the middle one (or two) rank 0.
func centerRank(_ index: Int, of count: Int) -> Int {
    abs(2 * index - (count - 1)) / 2
}

struct Reveal: ViewModifier {
    /// easeInOutCubic: the pill gathers speed and glides to a stop instead of snapping open.
    static let unfold = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 1.4)
    /// easeOutCubic: contents drift into place.
    static let settle = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 1.1)

    let rank: Int
    let delay: Double
    let scale: CGFloat
    @Environment(\.revealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let settled = revealed || reduceMotion
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(settled ? 1 : scale)
            .blur(radius: settled ? 0 : 8)
            .animation(Self.settle.delay(delay + Double(rank) * 0.1), value: revealed)
    }
}
