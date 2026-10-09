import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 34

    @Environment(Preferences.self) private var prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hookError: String?
    /// The Notch page has more rows; slightly shorter ones keep it on a 13-inch screen.
    private static let notchRowHeight: CGFloat = 30

    var body: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SIDY").font(Theme.display(30)).kerning(3).foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        Text("Settings").font(Theme.label).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                SegmentedPicker(selection: $prefs.settingsPage, options: [(.sidebar, "Sidebar"), (.notch, "Notch")])
            }
            .padding(.bottom, 22)

            switch prefs.settingsPage {
            case .sidebar: sidebar
            case .notch: notch
            }

            // Belongs to the app, not to either page, so it stays when both are switched off.
            settingRow("Launch at login", height: 24) {
                Toggle("", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            .padding(.top, 14)
        }
        .toggleStyle(DotToggleStyle())
        .padding(.horizontal, 22)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .background(Color(white: 0.055))
        .preferredColorScheme(.dark)
    }

    /// Each page starts with its switch; the rest of the page only shows while it is on.
    private var sidebar: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("01", "Sidebar")
            VStack(spacing: 0) {
                settingRow("Show sidebar") { Toggle("", isOn: $prefs.sidebar) }
                    .help("Off: use Sidy from the notch and the menu bar only")
                if prefs.sidebar {
                    settingRow("Screen edge") {
                        SegmentedPicker(selection: $prefs.edge, options: [(.left, "Left"), (.right, "Right")])
                    }
                    settingRow("Auto-hide") { Toggle("", isOn: $prefs.autoHide) }
                        .help("Tucks the sidebar off the screen edge; push the pointer against that edge to slide it back in")
                    if glassAvailable {
                        settingRow("Liquid glass") { Toggle("", isOn: $prefs.glass) }
                            .help("Glass in place of the dark pill and cards")
                    }
                    settingRow("Detailed style") { Toggle("", isOn: $prefs.detailed) }
                    if prefs.detailed {
                        settingRow("Show header", nested: true) { Toggle("", isOn: $prefs.showHeader) }
                    }
                }
            }
            .padding(.vertical, 6)
            .panel()

            if prefs.sidebar {
                sectionLabel("02", "Modules", trailing: "\(prefs.visible.count)/\(prefs.order.count) on · drag to reorder")
                    .padding(.top, 22)
                List {
                    ForEach(prefs.order) { module in
                        moduleRow(module)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 2))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { prefs.order.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, Self.rowHeight)
                .frame(height: CGFloat(prefs.order.count) * Self.rowHeight + 12)
                .panel()
            }
        }
    }

    private var notch: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("01", "Notch", trailing: prefs.notch ? "hover a setting for details" : nil)
            VStack(spacing: 0) {
                settingRow("Show notch", height: Self.notchRowHeight) { Toggle("", isOn: $prefs.notch) }
                    .help("Music, timers and alerts in a panel that grows out of the camera notch")
                if prefs.notch {
                    settingRow("Display", height: Self.notchRowHeight) {
                        SegmentedPicker(selection: $prefs.notchDisplay,
                                        options: [(.notched, "Built-in"), (.main, "Main"), (.all, "All")])
                    }
                    .help("Built-in: the display with the notch, or the main one when the lid is closed")
                    ForEach(NotchFeature.behavior, id: \.self, content: featureRow)
                }
            }
            .padding(.vertical, 6)
            .panel()

            if prefs.notch {
                notchSection("02", "Gestures", trailing: "two fingers on the notch", NotchFeature.gestures)
                notchSection("03", "Live activities", NotchFeature.activities)
                notchSection("04", "AI agents", trailing: "chats in your terminal", NotchFeature.agents)
                if let hookError {
                    Text(hookError).font(Theme.label).foregroundStyle(Theme.accent).padding(.horizontal, 4).padding(.top, 8)
                }
            }
        }
    }

    private func notchSection(_ number: String, _ title: String, trailing: String? = nil, _ features: [NotchFeature]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(number, title, trailing: trailing)
            VStack(spacing: 0) {
                ForEach(features, id: \.self, content: featureRow)
            }
            .padding(.vertical, 6)
            .panel()
        }
        .padding(.top, 22)
    }

    private func featureRow(_ feature: NotchFeature) -> some View {
        settingRow(feature.title, height: Self.notchRowHeight) {
            Toggle("", isOn: Binding(get: { prefs.notchFeatures.contains(feature) }, set: { _ in toggle(feature) }))
        }
        .help(feature.detail)
    }

    /// Agent switches also add or remove Sidy's hooks; if that fails the switch goes back and says why.
    private func toggle(_ feature: NotchFeature) {
        prefs.toggle(feature)
        guard let agent = Agent.allCases.first(where: { $0.feature == feature }) else { return }
        hookError = AgentHooks.set(agent, enabled: prefs.notchFeatures.contains(feature))
        if hookError != nil { prefs.toggle(feature) }
    }

    private func sectionLabel(_ number: String, _ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(number).foregroundStyle(Theme.ink)
            Text(title.uppercased()).foregroundStyle(Theme.muted)
            Spacer()
            if let trailing { Text(trailing.uppercased()).foregroundStyle(Theme.muted.opacity(0.7)) }
        }
        .font(Theme.label)
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func moduleRow(_ module: Module) -> some View {
        let on = !prefs.hidden.contains(module)
        return HStack(spacing: 10) {
            IconView(icon: module.icon)
                .frame(width: 14, height: 14)
                .foregroundStyle(on ? Theme.ink : Theme.muted)
            Text(module.title)
                .font(Theme.body)
                .foregroundStyle(on ? Theme.ink : Theme.muted)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in prefs.toggle(module) }))
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.muted.opacity(0.6))
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }

    /// `nested` marks a setting that only matters while the one above it is on.
    private func settingRow(_ title: String, nested: Bool = false, height: CGFloat = rowHeight,
                            @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            if nested {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Text(title).font(Theme.body).foregroundStyle(nested ? Theme.muted : Theme.ink)
            Spacer()
            control()
        }
        .frame(height: height)
        .padding(.leading, nested ? 18 : 12)
        .padding(.trailing, 12)
    }
}

private extension View {
    /// The widget's card look, reused for settings groups.
    func panel() -> some View {
        background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.085)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
                )
        )
    }
}

/// A slim capsule switch with a dot knob; orange when on.
struct DotToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Theme.accent : Color(white: 0.2))
            .overlay(
                Circle()
                    .fill(configuration.isOn ? .white : Color(white: 0.55))
                    .padding(3)
                    .frame(maxWidth: .infinity, alignment: configuration.isOn ? .trailing : .leading)
            )
            .frame(width: 30, height: 17)
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            }
    }
}

private struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Text(label.uppercased())
                    .font(Theme.label)
                    .foregroundStyle(selected ? .black : Theme.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(Capsule().fill(selected ? Theme.ink : .clear))
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) { selection = value }
                    }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(white: 0.16)))
    }
}
