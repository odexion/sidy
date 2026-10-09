import SwiftUI

struct Sidebar: View {
    static let spacing: CGFloat = 10
    static let margin: CGFloat = 18
    static var maxWidth: CGFloat { margin * 2 + Card<EmptyView>.size.width * 2 + spacing }

    let openSettings: () -> Void
    var pinned: Module?
    /// Plays the opening animation when the sidebar first appears.
    var animated = true
    @Environment(AIUsage.self) private var usage
    @Environment(Preferences.self) private var prefs
    @Environment(AutoHide.self) private var autoHide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        Group {
            if prefs.detailed {
                grid
            } else {
                // Auto-hide docks the pill flush against its edge, like the notch hangs from the top.
                CompactBar(openSettings: openSettings, pinned: pinned)
                    .padding(prefs.autoHide ? [.vertical, prefs.edge == .left ? .trailing : .leading] : .all, Self.margin)
            }
        }
        // Auto-hide keeps the sidebar out while the pointer is on it, not just anywhere in its strip.
        .onHover { autoHide.overContent = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: prefs.edge == .left ? .leading : .trailing)
        .modifier(Tuck(tucked: autoHide.tucked, edge: prefs.edge, reduceMotion: reduceMotion))
        .environment(\.revealed, revealed || !animated)
        .environment(\.glass, prefs.glass)
        .onAppear {
            // A beat after launch, so startup work settles before anything moves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { revealed = true }
        }
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
            if prefs.showHeader { Header().reveal(rank: 0, delay: 0.1, scale: 0.9) }
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: Self.spacing) {
                        ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                            if index % columns == column {
                                ModuleCard(module: module, index: index + 1)
                                    .reveal(rank: centerRank(index, of: modules.count), scale: 0.92)
                                    .contextMenu {
                                        if module.showsUsage {
                                            Button("Refresh Usage", action: usage.refresh)
                                            Divider()
                                        }
                                        Button("Hide \(module.title)") { prefs.toggle(module) }
                                        Button("Settings…", action: openSettings)
                                        Divider()
                                        Button("Quit Sidy") { NSApp.terminate(nil) }
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

/// Auto-hide's slide: out past the screen edge and back in on a soft spring, like the Dock.
private struct Tuck: ViewModifier {
    /// Glides out and settles without overshooting, which would pull it off the edge and show a gap,
    /// then slips away a little quicker than it came.
    static let show = Animation.spring(duration: 0.4, bounce: 0)
    static let hide = Animation.timingCurve(0.4, 0, 0.7, 0.4, duration: 0.3)

    let tucked: Bool
    let edge: SidebarEdge
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        // A little past the panel's width so the pill's shadow goes too.
        let distance = (Sidebar.maxWidth + 30) * (edge == .left ? -1 : 1)
        content
            .offset(x: tucked && !reduceMotion ? distance : 0)
            .opacity(tucked && reduceMotion ? 0 : 1)
            .animation(tucked ? Self.hide : Self.show, value: tucked)
    }
}
