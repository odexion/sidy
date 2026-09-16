import SwiftUI

/// Slim pill of icon tiles. Hovering a tile shows its detailed card beside the pill; clicking pins it.
struct CompactBar: View {
    let openSettings: () -> Void
    @Environment(Preferences.self) private var prefs

    @State private var hovered: Module?
    @State private var pinned: Module?
    @State private var hideWork: DispatchWorkItem?
    @State private var drag: TileDrag?

    private static let gap: CGFloat = 12
    private static let spacing: CGFloat = 6
    private static var pitch: CGFloat { ModuleTile.height + spacing }

    init(openSettings: @escaping () -> Void, pinned: Module? = nil) {
        self.openSettings = openSettings
        _pinned = State(initialValue: pinned)
    }

    var body: some View {
        let modules = prefs.visible
        VStack(spacing: 10) {
            VStack(spacing: Self.spacing) {
                ForEach(modules) { module in
                    let isDragged = drag?.module == module
                    ModuleTile(module: module, highlighted: shown == module || isDragged, pinned: pinned == module)
                        .anchorPreference(key: TileBounds.self, value: .bounds) { [module: $0] }
                        .scaleEffect(isDragged ? 1.08 : 1)
                        .shadow(color: .black.opacity(isDragged ? 0.5 : 0), radius: 8, y: 4)
                        .offset(y: isDragged ? drag?.offset ?? 0 : 0)
                        .zIndex(isDragged ? 1 : 0)
                        .onHover { $0 ? show(module) : scheduleHide() }
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { pinned = pinned == module ? nil : module }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { dragChanged(module, translation: $0.translation.height) }
                                .onEnded { _ in withAnimation(.spring(duration: 0.25)) { drag = nil } }
                        )
                        .contextMenu {
                            Button("Hide \(module.title)") { prefs.toggle(module) }
                            Button("Settings…", action: openSettings)
                        }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(pill)

            SettingsDots(action: openSettings)
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

    private var shown: Module? { drag == nil ? hovered ?? pinned : nil }

    private var pill: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
    }

    /// The tile follows the pointer; crossing half a slot swaps it with its neighbour.
    private func dragChanged(_ module: Module, translation: CGFloat) {
        if drag?.module != module {
            drag = TileDrag(module: module)
            hovered = nil
        }
        guard var current = drag else { return }
        current.offset = translation - current.shift

        let visible = prefs.visible
        if let index = visible.firstIndex(of: module) {
            let step = current.offset > Self.pitch / 2 ? 1 : current.offset < -Self.pitch / 2 ? -1 : 0
            if step != 0, visible.indices.contains(index + step) {
                let neighbour = visible[index + step]
                withAnimation(.easeInOut(duration: 0.18)) {
                    var order = prefs.order
                    order.removeAll { $0 == module }
                    let target = order.firstIndex(of: neighbour)! + (step > 0 ? 1 : 0)
                    order.insert(module, at: target)
                    prefs.order = order
                }
                current.shift += CGFloat(step) * Self.pitch
                current.offset -= CGFloat(step) * Self.pitch
            }
        }
        drag = current
    }

    private func show(_ module: Module) {
        guard drag == nil else { return }
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

private struct TileDrag {
    let module: Module
    var offset: CGFloat = 0     // visual offset from the tile's current slot
    var shift: CGFloat = 0      // distance already absorbed by swaps
}

/// The "•••" under the pill; a generous hit area since it sits on the bare desktop.
private struct SettingsDots: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(hovering ? Theme.accent : Theme.ink).frame(width: 5, height: 5) }
        }
        .frame(width: 56, height: 30)
        .background(Capsule().fill(.black.opacity(hovering ? 0.45 : 0.02)))
        .contentShape(Capsule())
        .shadow(color: .black.opacity(0.6), radius: 4)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Settings")
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
    static let height: CGFloat = 64

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
        .frame(width: 46, height: Self.height)
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
