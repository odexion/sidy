import Foundation
import Observation

enum Module: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, storage, network, claude, codex, battery, media, system, timer, alarm, notes

    var id: String { rawValue }

    /// Off until turned on in Settings.
    static let optIn: Set<Module> = [.timer, .alarm, .notes]

    var title: String {
        switch self {
        case .cpu: "CPU Load"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        case .claude: "Claude"
        case .codex: "Codex"
        case .battery: "Battery"
        case .media: "Now Playing"
        case .system: "System"
        case .timer: "Timer"
        case .alarm: "Alarm"
        case .notes: "Notes"
        }
    }

    var icon: Icon {
        switch self {
        case .cpu: .symbol("cpu")
        case .gpu: .asset("gpu")
        case .memory: .symbol("memorychip")
        case .storage: .symbol("internaldrive")
        case .network: .symbol("arrow.up.arrow.down")
        case .claude: .asset("claude")
        case .codex: .asset("openai")
        case .battery: .symbol("battery.75percent")
        case .media: .symbol("music.note")
        case .system: .symbol("thermometer.medium")
        case .timer: .symbol("timer")
        case .alarm: .symbol("alarm")
        case .notes: .symbol("scribble.variable")
        }
    }
}

enum Icon {
    case symbol(String)
    case asset(String)   // SVG in Resources
}

enum SidebarEdge: String, CaseIterable {
    case left, right
}

/// Which displays get a notch panel.
enum NotchDisplay: String, CaseIterable {
    case notched, main, all
}

/// Parts of the notch that can be switched on and off in Settings → Notch.
enum NotchFeature: String, CaseIterable {
    case hover, haptics, hideInFullScreen
    case swipeTracks, swipeOpen, scrollVolume
    case trackPeek, clocks, battery, limits, heat, usageTab, modulesTab
    case claudeCode, codex

    /// Off until turned on in Settings. The agents' hooks edit their settings files, so they wait to be asked.
    static let optIn: Set<NotchFeature> = [.scrollVolume, .claudeCode, .codex]

    static let behavior: [NotchFeature] = [.hover, .haptics, .hideInFullScreen]
    static let gestures: [NotchFeature] = [.swipeTracks, .swipeOpen, .scrollVolume]
    static let activities: [NotchFeature] = [.trackPeek, .modulesTab, .clocks, .battery, .heat]
    static let agents: [NotchFeature] = [.claudeCode, .codex, .usageTab, .limits]

    var title: String {
        switch self {
        case .hover: "Open on hover"
        case .haptics: "Haptic feedback"
        case .hideInFullScreen: "Hide in full screen"
        case .swipeTracks: "Swipe to change tracks"
        case .swipeOpen: "Swipe down to open"
        case .scrollVolume: "Scroll for volume"
        case .trackPeek: "Show new tracks"
        case .clocks: "Timer & alarm"
        case .battery: "Battery & charging"
        case .limits: "AI limit warnings"
        case .heat: "Heat warnings"
        case .usageTab: "AI tab"
        case .modulesTab: "Modules tab"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Shown as a tooltip on the setting.
    var detail: String {
        switch self {
        case .hover: "Off: click the notch to open it"
        case .haptics: "A light tap on the trackpad when the notch opens"
        case .hideInFullScreen: "Tucks the notch away while an app is full screen"
        case .swipeTracks: "Two-finger swipe left for the next track, right for the previous one, on the closed notch or the music tab"
        case .swipeOpen: "Two-finger swipe down on the notch opens it, up closes it"
        case .scrollVolume: "Two-finger scroll up and down on the music tab changes the volume"
        case .trackPeek: "The title peeks out under the notch when the track changes"
        case .clocks: "A Timer tab with the timer and alarm controls, a countdown beside the notch, and Stop when one rings"
        case .battery: "Plugging in, unplugging and low battery"
        case .limits: "When a Claude or Codex limit drops under 20% or 10%"
        case .heat: "When the Mac starts running hot"
        case .modulesTab: "Your sidebar's gauges (CPU, GPU, memory and the rest) in a tab of the open notch"
        case .usageTab: "Your agent sessions in the open notch, or your Claude and Codex limits when none are running"
        case .claudeCode: "Tells you when Claude Code finishes or needs you. Adds Sidy's hooks to ~/.claude/settings.json"
        case .codex: "Tells you when Codex finishes. Adds Sidy's hooks to ~/.codex/hooks.json"
        }
    }
}

@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var order: [Module] { didSet { defaults.set(order.map(\.rawValue), forKey: "order") } }
    var hidden: Set<Module> { didSet { defaults.set(hidden.map(\.rawValue), forKey: "hidden") } }
    var edge: SidebarEdge { didSet { defaults.set(edge.rawValue, forKey: "edge"); onLayoutChange?() } }
    var showHeader: Bool { didSet { defaults.set(showHeader, forKey: "showHeader") } }
    var detailed: Bool { didSet { defaults.set(detailed, forKey: "detailed") } }
    /// Music controls in a panel that grows out of the camera notch.
    var notch: Bool { didSet { defaults.set(notch, forKey: "notch"); onLayoutChange?() } }
    var notchDisplay: NotchDisplay { didSet { defaults.set(notchDisplay.rawValue, forKey: "notch.display"); onLayoutChange?() } }
    var notchFeatures: Set<NotchFeature> {
        didSet { defaults.set(notchFeatures.map(\.rawValue), forKey: "notch.features"); onLayoutChange?() }
    }

    @ObservationIgnored var onLayoutChange: (() -> Void)?

    var visible: [Module] { order.filter { !hidden.contains($0) } }

    init() {
        let saved = (defaults.stringArray(forKey: "order") ?? []).compactMap(Module.init)
        let added = Module.allCases.filter { !saved.contains($0) }
        order = saved + added
        // Modules new to this Mac start hidden if they are opt-in. Saving both lists now marks them as seen.
        hidden = Set((defaults.stringArray(forKey: "hidden") ?? []).compactMap(Module.init)).union(added.filter(Module.optIn.contains))
        edge = SidebarEdge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .right
        showHeader = defaults.object(forKey: "showHeader") as? Bool ?? true
        detailed = defaults.bool(forKey: "detailed")
        notch = defaults.bool(forKey: "notch")
        notchDisplay = NotchDisplay(rawValue: defaults.string(forKey: "notch.display") ?? "") ?? .notched
        // Like modules: features this Mac hasn't seen yet start with their default.
        let seen = Set((defaults.stringArray(forKey: "notch.seen") ?? []).compactMap(NotchFeature.init))
        let enabled = Set((defaults.stringArray(forKey: "notch.features") ?? []).compactMap(NotchFeature.init))
        notchFeatures = enabled.union(NotchFeature.allCases.filter { !seen.contains($0) && !NotchFeature.optIn.contains($0) })
        defaults.set(NotchFeature.allCases.map(\.rawValue), forKey: "notch.seen")
        defaults.set(notchFeatures.map(\.rawValue), forKey: "notch.features")
        defaults.set(order.map(\.rawValue), forKey: "order")
        defaults.set(hidden.map(\.rawValue), forKey: "hidden")
    }

    func has(_ feature: NotchFeature) -> Bool { notchFeatures.contains(feature) }

    func toggle(_ feature: NotchFeature) {
        if notchFeatures.contains(feature) { notchFeatures.remove(feature) } else { notchFeatures.insert(feature) }
    }

    func toggle(_ module: Module) {
        if hidden.contains(module) { hidden.remove(module) } else { hidden.insert(module) }
    }
}
