import ServiceManagement
import SwiftUI

struct Sidebar: View {
    static let spacing: CGFloat = 10
    static let margin: CGFloat = 18
    static var maxWidth: CGFloat { margin * 2 + Card<EmptyView>.size.width * 2 + spacing }

    let openSettings: () -> Void
    var pinned: Module?
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Group {
            if prefs.detailed {
                grid
            } else {
                CompactBar(openSettings: openSettings, pinned: pinned).padding(Self.margin)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: prefs.edge == .left ? .leading : .trailing)
    }

    private var grid: some View {
        // One column when it fits the screen height, otherwise two, otherwise scroll.
        ViewThatFits(in: .vertical) {
            stack(columns: 1)
            stack(columns: 2)
            ScrollView { stack(columns: 2) }.scrollIndicators(.never)
        }
    }

    private func stack(columns: Int) -> some View {
        let modules = prefs.visible
        return VStack(alignment: .leading, spacing: Self.spacing + 4) {
            if prefs.showHeader { Header() }
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: Self.spacing) {
                        ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                            if index % columns == column {
                                ModuleCard(module: module, index: index + 1)
                                    .contextMenu {
                                        Button("Hide \(module.title)") { prefs.toggle(module) }
                                        Button("Settings…", action: openSettings)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .padding(Self.margin)
    }
}

private struct Header: View {
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        let hot = system.thermal.rawValue >= 2
        VStack(alignment: .leading, spacing: 6) {
            Text("SIDY").font(Theme.display(28)).foregroundStyle(Theme.ink).kerning(3)
            HStack(spacing: 6) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                Text(hot ? "System running hot" : "All systems nominal")
                    .font(Theme.label)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.leading, 4)
        .shadow(color: .black.opacity(0.6), radius: 6)
    }
}

struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = prefs
        List {
            Section("Modules · drag to reorder") {
                ForEach(prefs.order) { module in
                    Toggle(module.title, isOn: Binding(
                        get: { !prefs.hidden.contains(module) },
                        set: { _ in prefs.toggle(module) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .onMove { prefs.order.move(fromOffsets: $0, toOffset: $1) }
            }

            Section("Layout") {
                Picker("Screen edge", selection: $prefs.edge) {
                    Text("Left").tag(SidebarEdge.left)
                    Text("Right").tag(SidebarEdge.right)
                }
                .pickerStyle(.segmented)
                Toggle("Detailed style", isOn: $prefs.detailed).toggleStyle(.switch).controlSize(.mini)
                Toggle("Show header", isOn: $prefs.showHeader).toggleStyle(.switch).controlSize(.mini)
                Toggle("Launch at login", isOn: $launchAtLogin).toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }
    }
}
