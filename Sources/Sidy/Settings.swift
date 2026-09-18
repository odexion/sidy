import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 34

    @Environment(Preferences.self) private var prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SIDY").font(Theme.display(30)).kerning(3).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    Text("Settings").font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
            .padding(.bottom, 22)

            sectionLabel("01", "Modules", trailing: "\(prefs.visible.count)/\(prefs.order.count) on · drag to reorder")
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
            .padding(.bottom, 22)

            sectionLabel("02", "Layout")
            VStack(spacing: 0) {
                settingRow("Screen edge") {
                    SegmentedPicker(selection: $prefs.edge, options: [(.left, "Left"), (.right, "Right")])
                }
                settingRow("Detailed style") { Toggle("", isOn: $prefs.detailed) }
                settingRow("Show header", enabled: prefs.detailed) { Toggle("", isOn: $prefs.showHeader) }
                settingRow("Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }
            }
            .padding(.vertical, 6)
            .panel()
        }
        .toggleStyle(DotToggleStyle())
        .padding(.horizontal, 22)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .background(Color(white: 0.055))
        .preferredColorScheme(.dark)
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

    private func settingRow(_ title: String, enabled: Bool = true, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title).font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            control()
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, 12)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
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
