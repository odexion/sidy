import Foundation
import Observation

enum Module: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, storage, network, claude, codex, battery, media, system

    var id: String { rawValue }

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
        }
    }

    var icon: Icon {
        switch self {
        case .cpu: .symbol("cpu")
        case .gpu: .symbol("cube.transparent")
        case .memory: .symbol("memorychip")
        case .storage: .symbol("internaldrive")
        case .network: .symbol("arrow.up.arrow.down")
        case .claude: .brand("claude")
        case .codex: .brand("openai")
        case .battery: .symbol("battery.75percent")
        case .media: .symbol("music.note")
        case .system: .symbol("thermometer.medium")
        }
    }
}

enum Icon {
    case symbol(String)
    case brand(String)
}

enum SidebarEdge: String, CaseIterable {
    case left, right
}

@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var order: [Module] { didSet { defaults.set(order.map(\.rawValue), forKey: "order") } }
    var hidden: Set<Module> { didSet { defaults.set(hidden.map(\.rawValue), forKey: "hidden") } }
    var edge: SidebarEdge { didSet { defaults.set(edge.rawValue, forKey: "edge"); onLayoutChange?() } }
    var showHeader: Bool { didSet { defaults.set(showHeader, forKey: "showHeader") } }
    var detailed: Bool { didSet { defaults.set(detailed, forKey: "detailed") } }

    @ObservationIgnored var onLayoutChange: (() -> Void)?

    var visible: [Module] { order.filter { !hidden.contains($0) } }

    init() {
        let saved = (defaults.stringArray(forKey: "order") ?? []).compactMap(Module.init)
        order = saved + Module.allCases.filter { !saved.contains($0) }
        hidden = Set((defaults.stringArray(forKey: "hidden") ?? []).compactMap(Module.init))
        edge = SidebarEdge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .right
        showHeader = defaults.object(forKey: "showHeader") as? Bool ?? true
        detailed = defaults.bool(forKey: "detailed")
    }

    func toggle(_ module: Module) {
        if hidden.contains(module) { hidden.remove(module) } else { hidden.insert(module) }
    }
}
