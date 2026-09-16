import SwiftUI

struct ModuleCard: View {
    let module: Module
    let index: Int
    @Environment(AIUsage.self) private var usage

    var body: some View {
        switch module {
        case .cpu: CPUCard(index: index)
        case .gpu: GPUCard(index: index)
        case .memory: MemoryCard(index: index)
        case .storage: StorageCard(index: index)
        case .network: NetworkCard(index: index)
        case .claude: LimitCard(index: index, title: "Claude", state: usage.claude)
        case .codex: LimitCard(index: index, title: "Codex", state: usage.codex)
        case .battery: BatteryCard(index: index)
        case .media: MediaCard(index: index)
        case .system: SystemCard(index: index)
        }
    }
}

private struct CPUCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        Card(index: index, title: "CPU Load", badge: Badge(text: "\(system.cores) cores", color: Theme.muted)) {
            BigValue(value: Format.percent(system.cpu), unit: "%")
            Spacer(minLength: 0)
            DotBars(values: system.cpuHistory).frame(height: 32)
        }
    }
}

private struct GPUCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let history = system.gpuHistory
        Card(index: index, title: "GPU") {
            HStack(spacing: 14) {
                ZStack {
                    DotRing(fraction: system.gpu)
                    Text(Format.percent(system.gpu) + "%").font(Theme.display(17)).foregroundStyle(Theme.ink)
                }
                .frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 10) {
                    legend("Peak", history.max() ?? 0, Theme.accent)
                    legend("Avg", history.reduce(0, +) / Double(history.count), Theme.ink)
                }
            }
        }
    }

    private func legend(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Circle().fill(color).frame(width: 4, height: 4).padding(.top, 3)
            Stat(label: label, value: Format.percent(value) + "%")
        }
    }
}

private struct MemoryCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let used = Double(system.memoryUsed)
        let total = Double(system.memoryTotal)
        let (value, unit) = Format.bytes(used, base: 1024)
        let fraction = used / total
        Card(index: index, title: "Memory", badge: Badge(text: Format.bytes(total, base: 1024).0 + " GB", color: Theme.muted)) {
            BigValue(value: value, unit: unit)
            Spacer(minLength: 0)
            DotMeter(fraction: fraction, alert: fraction > 0.9).frame(height: 7)
            Spacer(minLength: 0)
            HStack {
                Stat(label: "Used", value: Format.percent(fraction) + "%")
                Spacer()
                Stat(label: "Free", value: Format.size(max(total - used, 0), base: 1024), alignment: .trailing)
            }
        }
    }
}

private struct StorageCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let free = Double(system.diskFree)
        let total = Double(max(system.diskTotal, 1))
        let (value, unit) = Format.bytes(free)
        Card(index: index, title: "Storage", badge: Badge(text: "Macintosh HD", color: Theme.muted)) {
            BigValue(value: value, unit: unit + " free")
            Spacer(minLength: 0)
            DotMeter(fraction: 1 - free / total, alert: free / total < 0.1).frame(height: 7)
            Spacer(minLength: 0)
            HStack {
                Stat(label: "Used", value: Format.size(total - free))
                Spacer()
                Stat(label: "Total", value: Format.size(total), alignment: .trailing)
            }
        }
    }
}

private struct NetworkCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let peak = max((system.downloadHistory + system.uploadHistory).max() ?? 0, 50_000)
        Card(index: index, title: "Network") {
            HStack {
                Stat(label: "↓ Down", value: Format.rate(system.download))
                Spacer()
                Stat(label: "↑ Up", value: Format.rate(system.upload), alignment: .trailing)
            }
            Spacer(minLength: 0)
            DotSpark(series: [system.downloadHistory.map { $0 / peak }, system.uploadHistory.map { $0 / peak }])
                .frame(height: 44)
        }
    }
}

private struct LimitCard: View {
    let index: Int
    let title: String
    let state: LimitState

    var body: some View {
        let badge = state.error == nil ? Badge(text: state.plan ?? "Live") : Badge(text: "Stale", color: Theme.muted)
        Card(index: index, title: title, badge: badge) {
            if state.windows.isEmpty {
                Text(state.error ?? "Loading…").font(Theme.body).foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 12) {
                    ForEach(state.windows.prefix(2), id: \.label) { row($0) }
                }
            }
        }
    }

    private func row(_ window: LimitWindow) -> some View {
        let left = 1 - window.used
        return VStack(spacing: 5) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(window.label) left".uppercased()).font(Theme.label).foregroundStyle(Theme.muted).fixedSize()
                Spacer(minLength: 0)
                if let reset = window.resetsAt {
                    Text("↺ " + Format.duration(reset.timeIntervalSinceNow))
                        .font(Theme.label).foregroundStyle(Theme.muted).fixedSize()
                }
                Text(Format.percent(left) + "%")
                    .font(Theme.display(19))
                    .foregroundStyle(left < 0.2 ? Theme.accent : Theme.ink)
                    .fixedSize()
            }
            DotMeter(fraction: left, alert: left < 0.2).frame(height: 6)
        }
    }
}

private struct BatteryCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let battery = system.battery
        Card(index: index, title: "Battery", badge: battery?.charging == true ? Badge(text: "Charging") : nil) {
            if let battery {
                HStack(alignment: .center) {
                    BigValue(value: Format.percent(battery.level), unit: "%")
                    Spacer()
                    BatteryGlyph(level: battery.level).frame(width: 52, height: 22)
                }
                Spacer(minLength: 0)
                HStack {
                    Stat(label: "Source", value: battery.pluggedIn ? "Power adapter" : "Battery")
                    Spacer()
                    Stat(label: battery.charging ? "Until full" : "Remaining",
                         value: battery.minutesRemaining.map { Format.duration(Double($0) * 60) } ?? "—",
                         alignment: .trailing)
                }
            } else {
                BigValue(value: "AC", size: 30)
                Spacer(minLength: 0)
                Stat(label: "Source", value: "No battery")
            }
        }
    }
}

private struct MediaCard: View {
    let index: Int
    @Environment(NowPlaying.self) private var media

    var body: some View {
        let badge = media.source.map { Badge(text: $0, color: media.isPlaying ? Theme.accent : Theme.muted) }
        Card(index: index, title: "Now Playing", badge: badge) {
            HStack(spacing: 10) {
                DotDisc(active: media.isPlaying).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(media.title ?? "Nothing playing").font(Theme.body).foregroundStyle(Theme.ink)
                    Text(media.artist ?? "Spotify · YT Music").font(Theme.label).foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            SeekBar()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 0) {
                    Text(media.duration == nil ? "" : Format.clock(media.position(at: context.date)))
                        .frame(width: 30, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        control("backward.end.fill", size: 9, action: media.previous)
                        Button(action: media.playPause) {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        control("forward.end.fill", size: 9, action: media.next)
                    }
                    Spacer(minLength: 0)
                    Text(media.duration.map(Format.clock) ?? "")
                        .frame(width: 30, alignment: .trailing)
                }
                .font(Theme.label)
                .foregroundStyle(Theme.muted)
            }
            .padding(.top, 6)
            .disabled(media.source == nil)
            .opacity(media.source == nil ? 0.35 : 1)
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(Theme.ink).padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Dotted progress bar; click or drag anywhere on it to seek.
private struct SeekBar: View {
    @Environment(NowPlaying.self) private var media
    @State private var scrub: Double?

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let progress = media.duration.map { media.position(at: context.date) / $0 } ?? 0
                DotMeter(fraction: scrub ?? progress, count: 30, alert: scrub != nil)
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrub = min(max($0.location.x / proxy.size.width, 0), 1) }
                    .onEnded { _ in
                        if let scrub, let duration = media.duration { media.seek(to: scrub * duration) }
                        scrub = nil
                    }
            )
        }
        .frame(height: 14)
        .disabled(media.duration == nil)
    }
}

private struct SystemCard: View {
    let index: Int
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let level = system.thermal.rawValue
        Card(index: index, title: "System", badge: Badge(text: "Thermal", color: level >= 2 ? Theme.accent : Theme.muted)) {
            BigValue(value: system.thermal.name, size: 26)
            Spacer(minLength: 0)
            DotMeter(fraction: Double(level + 1) / 4, alert: level >= 2).frame(height: 6)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Stat(label: "Uptime", value: Format.duration(Date().timeIntervalSince(system.bootDate)))
                Spacer()
                Stat(label: "Load 1m", value: String(format: "%.2f", system.loadAverage[0]), alignment: .trailing)
            }
        }
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: "COOL"
        case .fair: "WARM"
        case .serious: "HOT"
        case .critical: "CRITICAL"
        @unknown default: "—"
        }
    }
}
