import ServiceManagement
import SwiftUI

/// A narrow column of pages on the left and the chosen page on the right, so each page stays short enough to read.
struct SettingsView: View {
    static let size = CGSize(width: 680, height: 600)
    private static let navWidth: CGFloat = 196
    private static let rowHeight: CGFloat = 34

    @Environment(Preferences.self) private var prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hookError: String?

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            page
        }
        .toggleStyle(DotToggleStyle())
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(white: 0.055))
        .preferredColorScheme(.dark)
    }

    // MARK: Navigation

    private var navigation: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SIDY").font(Theme.display(30)).kerning(3).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    Text("Settings").font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 26)

            VStack(spacing: 12) {
                navGroup("Sidebar", isOn: $prefs.sidebar, pages: SettingsPage.sidebarPages)
                navGroup("Notch", isOn: $prefs.notch, pages: SettingsPage.notchPages)
            }

            Spacer()

            navItem(.general).padding(.horizontal, 6).padding(.bottom, 14)

            Text("VERSION \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "DEV")")
                .font(Theme.label)
                .foregroundStyle(Theme.muted.opacity(0.6))
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 20)
        .frame(width: Self.navWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.035))
    }

    /// The sidebar and the notch each get a framed group, headed by the switch that turns them on.
    private func navGroup(_ title: String, isOn: Binding<Bool>, pages: [SettingsPage]) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(isOn.wrappedValue ? Theme.accent : Theme.muted.opacity(0.5)).frame(width: 5, height: 5)
                Text(title.uppercased()).font(Theme.label).foregroundStyle(isOn.wrappedValue ? Theme.ink : Theme.muted)
                Spacer()
                Toggle("", isOn: isOn)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            ForEach(pages, id: \.self) { navItem($0).opacity(isOn.wrappedValue ? 1 : 0.5) }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.6))
        )
    }

    private func navItem(_ page: SettingsPage) -> some View {
        let selected = prefs.settingsPage == page
        return HStack(spacing: 10) {
            Image(systemName: page.icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(selected ? Theme.accent : Theme.muted)
            Text(page.title).font(Theme.body).foregroundStyle(selected ? Theme.ink : Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { prefs.settingsPage = page }
    }

    /// The switch a page's group hangs on: the sidebar's or the notch's.
    private func groupSwitch(_ page: SettingsPage) -> Binding<Bool>? {
        @Bindable var prefs = prefs
        if SettingsPage.sidebarPages.contains(page) { return $prefs.sidebar }
        if SettingsPage.notchPages.contains(page) { return $prefs.notch }
        return nil
    }

    /// A page whose sidebar or notch is switched off. Modules stay editable: the notch's modules tab uses them too.
    private func pageOff(_ page: SettingsPage) -> Bool {
        switch page {
        case .sidebar: !prefs.sidebar
        case .notch, .tabs, .gestures, .activities, .agents: !prefs.notch
        case .modules, .general: false
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        let current = prefs.settingsPage
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let group = current.group {
                    Text(group.uppercased()).font(Theme.label).foregroundStyle(Theme.accent)
                }
                Text(current.title).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                Text(current.subtitle).font(Theme.body).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 20)

            if pageOff(current), let group = current.group, let isOn = groupSwitch(current) {
                offNotice(group, isOn: isOn)
            }

            if current == .modules {
                // The list scrolls and reorders on its own.
                modules
            } else {
                ScrollView {
                    content(for: current).padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                .dimmed(pageOff(current))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(for page: SettingsPage) -> some View {
        switch page {
        case .sidebar: sidebar
        case .modules: EmptyView()
        case .notch: notch
        case .tabs: tabs
        case .gestures: featureSection("On the notch", NotchFeature.gestures)
        case .activities: activities
        case .agents: agents
        case .general: general
        }
    }

    private var sidebar: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 22) {
            section("Placement") {
                row("Screen edge", "The side of the screen the sidebar sits on") {
                    SegmentedPicker(selection: $prefs.edge, options: [(.left, "Left"), (.right, "Right")])
                }
                divider
                row("Auto-hide", "Tucks it off the edge, like the Dock. Push the pointer against the edge to bring it back") {
                    Toggle("", isOn: $prefs.autoHide)
                }
            }
            section("Look") {
                if glassAvailable {
                    row("Liquid glass", "Glass in place of the dark pill and cards") { Toggle("", isOn: $prefs.glass) }
                    divider
                }
                row("Detailed style", "Every module as a full card instead of the slim pill") { Toggle("", isOn: $prefs.detailed) }
                if prefs.detailed {
                    divider
                    row("Show header", "The SIDY title above the cards", nested: true) { Toggle("", isOn: $prefs.showHeader) }
                }
            }
        }
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("\(prefs.visible.count) of \(prefs.order.count) on", trailing: "drag to reorder")
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
            .scrollIndicators(.never)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .padding(.vertical, 6)
            .panel()
            .padding(.bottom, 24)
        }
    }

    private var notch: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 22) {
            section("Display") {
                row("Display", "Built-in uses the main display while the lid is closed") {
                    SegmentedPicker(selection: $prefs.notchDisplay, options: [(.notched, "Built-in"), (.main, "Main"), (.all, "All")])
                }
            }
            featureSection("Opening", NotchFeature.behavior)
        }
    }

    /// Music is the notch's home and always there; the other tabs join it as icons beside the camera.
    private var tabs: some View {
        section("In the open notch", trailing: "icons beside the camera") {
            row("Music", "The player, where the notch opens. Always there") {
                Text("ALWAYS").font(Theme.label).foregroundStyle(Theme.muted)
            }
            ForEach(NotchFeature.tabs, id: \.self) { feature in
                divider
                featureRow(feature)
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 22) {
            featureSection("Agents", NotchFeature.agents, trailing: "chats in your terminal")
            if let hookError {
                Text(hookError).font(Theme.body).foregroundStyle(Theme.accent).padding(.horizontal, 4)
            }
        }
    }

    /// Every alert the notch drops down with. Agent replies come with their agent's switch, so they link there.
    private var activities: some View {
        VStack(alignment: .leading, spacing: 22) {
            featureSection("Music & clocks", NotchFeature.musicAndClocks)
            featureSection("Mac", NotchFeature.system)
            section("AI") {
                featureRow(.limits)
                divider
                row("Agent replies", "When Claude Code or Codex finishes or needs you. Comes with each agent's switch") {
                    Text("AI AGENTS ›")
                        .font(Theme.label)
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                        .onTapGesture { prefs.settingsPage = .agents }
                }
            }
        }
    }

    private var general: some View {
        group {
            row("Launch at login", "Opens Sidy when you log in to your Mac") {
                Toggle("", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            divider
            row("Quit Sidy", "Closes the sidebar, the notch and the menu bar icon until you open Sidy again") {
                pillButton("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Pieces

    private func featureSection(_ title: String, _ features: [NotchFeature], trailing: String? = nil) -> some View {
        section(title, trailing: trailing) {
            ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                if index > 0 { divider }
                featureRow(feature)
            }
        }
    }

    private func featureRow(_ feature: NotchFeature) -> some View {
        row(feature.title, feature.detail) {
            Toggle("", isOn: Binding(get: { prefs.notchFeatures.contains(feature) }, set: { _ in toggle(feature) }))
        }
    }

    /// Says why the page is faded, with a shortcut to the switch in the list.
    private func offNotice(_ group: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "power").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            Text("The \(group.lowercased()) is off").font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            pillButton("Turn on") {
                withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue = true }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.1)))
        .padding(.bottom, 18)
    }

    /// Agent switches also add or remove Sidy's hooks; if that fails the switch goes back and says why.
    private func toggle(_ feature: NotchFeature) {
        prefs.toggle(feature)
        guard let agent = Agent.allCases.first(where: { $0.feature == feature }) else { return }
        hookError = AgentHooks.set(agent, enabled: prefs.notchFeatures.contains(feature))
        if hookError != nil { prefs.toggle(feature) }
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title.uppercased())
            .font(Theme.label)
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(Capsule().fill(Theme.ink))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }

    private func section(_ title: String, trailing: String? = nil, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(title, trailing: trailing)
            group(rows: rows)
        }
    }

    private func group(@ViewBuilder rows: () -> some View) -> some View {
        VStack(spacing: 0) { rows() }
            .padding(.vertical, 4)
            .panel()
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.05)).frame(height: 1).padding(.horizontal, 14)
    }

    private func sectionLabel(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 4, height: 4)
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

    /// A setting with its explanation under it. `nested` marks one that only matters while the one above it is on.
    private func row(_ title: String, _ detail: String, nested: Bool = false,
                     @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 14) {
            if nested {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.body).foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 11)
        .padding(.leading, nested ? 18 : 14)
        .padding(.trailing, 14)
    }
}

private extension View {
    /// Faded and out of reach while the switch it depends on is off.
    func dimmed(_ off: Bool) -> some View {
        opacity(off ? 0.4 : 1).disabled(off)
    }

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
