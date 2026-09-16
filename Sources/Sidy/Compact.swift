import SwiftUI

/// Slim pill of icon tiles. Hovering a tile shows its detailed card beside the pill; clicking pins it.
struct CompactBar: View {
    let openSettings: () -> Void
    @Environment(Preferences.self) private var prefs

    @State private var hovered: Module?
    @State private var pinned: Module?
    @State private var hideWork: DispatchWorkItem?

    private static let gap: CGFloat = 12

    init(openSettings: @escaping () -> Void, pinned: Module? = nil) {
        self.openSettings = openSettings
        _pinned = State(initialValue: pinned)
    }

    var body: some View {
        let modules = prefs.visible
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                ForEach(modules) { module in
                    ModuleTile(module: module, highlighted: shown == module, pinned: pinned == module)
                        .anchorPreference(key: TileBounds.self, value: .bounds) { [module: $0] }
                        .onHover { $0 ? show(module) : scheduleHide() }
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { pinned = pinned == module ? nil : module }
                        }
                        .contextMenu {
                            Button("Hide \(module.title)") { prefs.toggle(module) }
                            Button("Settings…", action: openSettings)
                        }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(pill)

            Button(action: openSettings) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.ink).frame(width: 5, height: 5) }
                }
                .padding(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.6), radius: 4)
        }
        .overlayPreferenceValue(TileBounds.self) { bounds in
            GeometryReader { proxy in
                if let module = shown, let anchor = bounds[module] {
                    let tile = proxy[anchor]
                    let width = Card<EmptyView>.size.width
                    let x = prefs.edge == .right ? tile.minX - Self.gap - width / 2 : tile.maxX + Self.gap + width / 2
                    ModuleCard(module: module, index: (modules.firstIndex(of: module) ?? 0) + 1)
                        .onHover { $0 ? show(module) : scheduleHide() }
                        .position(x: x, y: tile.midY)
                        .transition(.opacity.combined(with: .offset(x: prefs.edge == .right ? 6 : -6)))
                        .id(module)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown)
    }

    private var shown: Module? { hovered ?? pinned }

    private var pill: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
    }

    private func show(_ module: Module) {
        hideWork?.cancel()
        hovered = module
    }

    /// A short delay lets the pointer cross the gap between the tile and its card.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { hovered = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

private struct TileBounds: PreferenceKey {
    static var defaultValue: [Module: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Module: Anchor<CGRect>], nextValue: () -> [Module: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A dotted progress ring around the module's icon, with a short value underneath.
private struct ModuleTile: View {
    let module: Module
    let highlighted: Bool
    let pinned: Bool

    @Environment(SystemMonitor.self) private var system
    @Environment(AIUsage.self) private var usage
    @Environment(NowPlaying.self) private var media

    var body: some View {
        let metric = self.metric
        VStack(spacing: 4) {
            ZStack {
                if let fraction = metric.fraction {
                    DotRing(fraction: fraction, ticks: 36, tickLength: 3.5, innerDots: false)
                } else {
                    DotDisc(active: media.isPlaying)
                        .opacity(0.8)
                }
                IconView(icon: metric.icon ?? module.icon)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(metric.alert ? Theme.accent : Theme.ink)
                    .opacity(metric.fraction == nil ? 0 : 1)
            }
            .frame(width: 38, height: 38)

            Text(metric.value)
                .font(Theme.display(11))
                .foregroundStyle(metric.alert ? Theme.accent : Theme.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 46)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(highlighted ? 0.07 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(pinned ? 0.8 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private struct Metric {
        var fraction: Double?
        var value: String
        var alert = false
        var icon: Icon?
    }

    private var metric: Metric {
        switch module {
        case .cpu:
            return Metric(fraction: system.cpu, value: Format.percent(system.cpu) + "%", alert: system.cpu > 0.9)
        case .gpu:
            return Metric(fraction: system.gpu, value: Format.percent(system.gpu) + "%", alert: system.gpu > 0.9)
        case .memory:
            let fraction = Double(system.memoryUsed) / Double(system.memoryTotal)
            return Metric(fraction: fraction, value: Format.compact(Double(system.memoryUsed), base: 1024), alert: fraction > 0.9)
        case .storage:
            let free = Double(system.diskFree)
            let fraction = system.diskTotal > 0 ? 1 - free / Double(system.diskTotal) : 0
            return Metric(fraction: fraction, value: Format.compact(free), alert: fraction > 0.9)
        case .network:
            let peak = max((system.downloadHistory + system.uploadHistory).max() ?? 0, 50_000)
            return Metric(fraction: system.download / peak, value: Format.compact(system.download))
        case .claude:
            return limit(usage.claude)
        case .codex:
            return limit(usage.codex)
        case .battery:
            guard let battery = system.battery else { return Metric(fraction: 1, value: "AC", icon: .symbol("powerplug")) }
            let step = battery.charging ? "100percent.bolt" : ["0", "25", "50", "75", "100"][Int((battery.level * 4).rounded())] + "percent"
            return Metric(fraction: battery.level, value: Format.percent(battery.level) + "%",
                          alert: battery.level < 0.2 && !battery.charging, icon: .symbol("battery." + step))
        case .media:
            return Metric(fraction: nil, value: media.isPlaying ? "PLAY" : media.title == nil ? "—" : "PAUSE")
        case .system:
            let level = system.thermal.rawValue
            return Metric(fraction: Double(level + 1) / 4, value: String(system.thermal.name.prefix(4)), alert: level >= 2)
        }
    }

    private func limit(_ state: LimitState) -> Metric {
        guard let window = state.windows.first else { return Metric(fraction: 0, value: "—") }
        let left = 1 - window.used
        return Metric(fraction: left, value: Format.percent(left) + "%", alert: left < 0.2)
    }
}
