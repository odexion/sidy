import Foundation
import Observation

enum Module: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, storage, network, claude, codex, battery, media, system, timer, alarm, notes

    var id: String { rawValue }

    /// Off until turned on in Settings.
    static let optIn: Set<Module> = [.timer, .alarm, .notes]

    /// Shows plan limits that can be refreshed on demand.
    var showsUsage: Bool { self == .claude || self == .codex }

    /// Shows readings that change from second to second, so the system is sampled quickly while it is on screen.
    var isLiveGauge: Bool { [.cpu, .gpu, .memory, .network, .system].contains(self) }

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

/// The page Settings opens on; the notch's settings button asks for the Notch page.
enum SettingsPage: CaseIterable {
    case sidebar, modules, notch, tabs, gestures, activities, agents, general

    static let sidebarPages: [SettingsPage] = [.sidebar, .modules]
    static let notchPages: [SettingsPage] = [.notch, .tabs, .gestures, .activities, .agents]

    /// The part of Sidy a page belongs to, shown above its title.
    var group: String? {
        switch self {
        case .sidebar, .modules: "Sidebar"
        case .notch, .tabs, .gestures, .activities, .agents: "Notch"
        case .general: nil
        }
    }

    var title: String {
        switch self {
        case .sidebar: "Appearance"
        case .modules: "Modules"
        case .notch: "Behavior"
        case .tabs: "Tabs"
        case .gestures: "Gestures"
        case .activities: "Activities"
        case .agents: "AI agents"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .sidebar: "The pill of gauges on the edge of your desktop"
        case .modules: "What the sidebar and the notch's modules tab show"
        case .notch: "Where the notch shows up and how it opens"
        case .tabs: "The pages of the open notch"
        case .gestures: "Two fingers on the notch"
        case .activities: "What drops down from the notch on its own"
        case .agents: "Claude Code and Codex sessions in the notch"
        case .general: "Sidy itself"
        }
    }

    var icon: String {
        switch self {
        case .sidebar: "paintbrush"
        case .modules: "square.grid.2x2"
        case .notch: "cursorarrow.motionlines"
        case .tabs: "rectangle.split.3x1"
        case .gestures: "hand.draw"
        case .activities: "bell"
        case .agents: "sparkles"
        case .general: "gearshape"
        }
    }
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
    case countdown, ringing, lowBattery

    /// Off until turned on in Settings. The agents' hooks edit their settings files, so they wait to be asked;
    /// the modules and AI tabs are extras beyond the music the notch is for.
    static let optIn: Set<NotchFeature> = [.scrollVolume, .claudeCode, .codex, .modulesTab, .usageTab]

    static let behavior: [NotchFeature] = [.hover, .haptics, .hideInFullScreen]
    static let gestures: [NotchFeature] = [.swipeTracks, .swipeOpen, .scrollVolume]
    /// The open notch's tabs beside the music player, which is always there.
    static let tabs: [NotchFeature] = [.modulesTab, .clocks, .usageTab]
    static let musicAndClocks: [NotchFeature] = [.trackPeek, .countdown, .ringing]
    static let system: [NotchFeature] = [.battery, .lowBattery, .heat]
    static let agents: [NotchFeature] = [.claudeCode, .codex]

    /// Alerts split off an older switch; on a Mac that already had that switch, they start the way it was.
    static let splitFrom: [NotchFeature: NotchFeature] = [.countdown: .clocks, .ringing: .clocks, .lowBattery: .battery]

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
        case .countdown: "Timer countdown"
        case .ringing: "Timer & alarm ringing"
        case .battery: "Charging"
        case .lowBattery: "Low battery"
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
        case .clocks: "A tab with the timer and alarm controls"
        case .countdown: "The time left beside the notch while a timer runs"
        case .ringing: "Drops down with Stop when a timer or alarm goes off"
        case .battery: "Plugging in and unplugging"
        case .lowBattery: "When the battery drops under 20% and again under 10%"
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
    /// Off makes Sidy a notch-only (or menu-bar-only) app.
    var sidebar: Bool { didSet { defaults.set(sidebar, forKey: "sidebar"); onLayoutChange?() } }
    var edge: SidebarEdge { didSet { defaults.set(edge.rawValue, forKey: "edge"); onLayoutChange?() } }
    /// Tucks the sidebar past its edge until the pointer touches that edge, like the Dock.
    var autoHide: Bool { didSet { defaults.set(autoHide, forKey: "autoHide"); onLayoutChange?() } }
    /// Liquid glass for the pill and the cards, on macOS 26 and later.
    var glass: Bool { didSet { defaults.set(glass, forKey: "glass") } }
    var showHeader: Bool { didSet { defaults.set(showHeader, forKey: "showHeader") } }
    var detailed: Bool { didSet { defaults.set(detailed, forKey: "detailed") } }
    /// Music controls in a panel that grows out of the camera notch.
    var notch: Bool { didSet { defaults.set(notch, forKey: "notch"); onLayoutChange?() } }
    var notchDisplay: NotchDisplay { didSet { defaults.set(notchDisplay.rawValue, forKey: "notch.display"); onLayoutChange?() } }
    var notchFeatures: Set<NotchFeature> {
        didSet { defaults.set(notchFeatures.map(\.rawValue), forKey: "notch.features"); onLayoutChange?() }
    }

    /// Not saved: Settings shows whichever page was last asked for.
    var settingsPage = SettingsPage.sidebar

    @ObservationIgnored var onLayoutChange: (() -> Void)?

    var visible: [Module] { order.filter { !hidden.contains($0) } }

    init() {
        let saved = (defaults.stringArray(forKey: "order") ?? []).compactMap(Module.init)
        let added = Module.allCases.filter { !saved.contains($0) }
        order = saved + added
        // Modules new to this Mac start hidden if they are opt-in. Saving both lists now marks them as seen.
        hidden = Set((defaults.stringArray(forKey: "hidden") ?? []).compactMap(Module.init)).union(added.filter(Module.optIn.contains))
        sidebar = defaults.object(forKey: "sidebar") as? Bool ?? true
        edge = SidebarEdge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .left
        autoHide = defaults.object(forKey: "autoHide") as? Bool ?? true
        glass = defaults.object(forKey: "glass") as? Bool ?? true
        showHeader = defaults.bool(forKey: "showHeader")
        detailed = defaults.bool(forKey: "detailed")
        notch = defaults.object(forKey: "notch") as? Bool ?? true
        notchDisplay = NotchDisplay(rawValue: defaults.string(forKey: "notch.display") ?? "") ?? .notched
        // Like modules: features this Mac hasn't seen yet start with their default.
        let seen = Set((defaults.stringArray(forKey: "notch.seen") ?? []).compactMap(NotchFeature.init))
        let enabled = Set((defaults.stringArray(forKey: "notch.features") ?? []).compactMap(NotchFeature.init))
        notchFeatures = enabled.union(NotchFeature.allCases.filter { feature in
            guard !seen.contains(feature) else { return false }
            if let parent = NotchFeature.splitFrom[feature], seen.contains(parent) { return enabled.contains(parent) }
            return !NotchFeature.optIn.contains(feature)
        })
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
