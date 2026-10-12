import SwiftUI

/// Watches the battery, AI limits and thermals, and peeks a message out of the notch when one crosses a line.
struct NotchAlerts: ViewModifier {
    let show: (NotchMessage) -> Void
    @Environment(Preferences.self) private var prefs
    @Environment(SystemMonitor.self) private var system
    @Environment(AIUsage.self) private var usage

    func body(content: Content) -> some View {
        content
            .onChange(of: system.battery?.pluggedIn) { old, new in
                guard prefs.has(.battery), let old, let new, old != new, let battery = system.battery else { return }
                let level = Format.percent(battery.level) + "%"
                if new {
                    show(NotchMessage(icon: .symbol("bolt.fill"), title: "Charging", detail: level, tab: .modules))
                } else {
                    let left = battery.minutesRemaining.map { " · " + Format.duration(Double($0) * 60) } ?? ""
                    show(NotchMessage(icon: .symbol("battery.75percent"), title: "On battery", detail: level + left, tab: .modules))
                }
            }
            .onChange(of: lowBattery) { old, new in
                guard prefs.has(.lowBattery), new > old, let battery = system.battery else { return }
                show(NotchMessage(icon: .symbol("battery.25percent"), title: "Battery low",
                                  detail: Format.percent(battery.level) + "% left", alert: true, tab: .modules))
            }
            .onChange(of: usage.claude.windows.map(\.used)) { old, new in
                limit("Claude", icon: .asset("claude"), state: usage.claude, old: old, new: new)
            }
            .onChange(of: usage.codex.windows.map(\.used)) { old, new in
                limit("Codex", icon: .asset("openai"), state: usage.codex, old: old, new: new)
            }
            .onChange(of: system.thermal) { old, new in
                guard prefs.has(.heat), new.rawValue >= 2, old.rawValue < 2 else { return }
                show(NotchMessage(icon: .symbol("thermometer.high"), title: "Running hot", detail: new.name, alert: true, tab: .modules))
            }
    }

    /// 0 fine, 1 under 20%, 2 under 10%; only counts while on battery.
    private var lowBattery: Int {
        guard let battery = system.battery, !battery.pluggedIn else { return 0 }
        return battery.level < 0.1 ? 2 : battery.level < 0.2 ? 1 : 0
    }

    /// Speaks up once when a window's remaining share drops under 20% and again under 10%.
    /// The first load after launch has nothing to compare against, so it stays quiet.
    private func limit(_ name: String, icon: Icon, state: LimitState, old: [Double], new: [Double]) {
        guard prefs.has(.limits), old.count == new.count else { return }
        for (index, (before, after)) in zip(old, new).enumerated() where [0.8, 0.9].contains(where: { before < $0 && after >= $0 }) {
            let label = state.windows.indices.contains(index) ? state.windows[index].label : ""
            return show(NotchMessage(icon: icon, title: "\(name) \(label) limit", detail: Format.percent(1 - after) + "% left", alert: true, tab: .ai))
        }
    }
}
