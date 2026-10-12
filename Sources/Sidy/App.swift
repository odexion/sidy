import AppKit
import SwiftUI

@main
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        // Run as an agent's hook: pass the event to the running Sidy and quit without starting the app.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: AgentHooks.marker), i + 1 < args.count {
            return AgentHooks.forward(args[i + 1])
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences()
    let system = SystemMonitor()
    let usage = AIUsage()
    lazy var media = NowPlaying(prefs: prefs)
    let updater = Updater()
    let clocks = Clocks()
    let notes = Notes()
    let agents = Agents()
    let autoHide = AutoHide()

    private var panel: SidebarPanel!
    private lazy var notch = NotchController(prefs: prefs) { [unowned self] size, events in
        AnyView(NotchView(notch: size, events: events, openSettings: { [weak self] in self?.showSettings(.notch) })
            .environment(prefs).environment(media).environment(clocks).environment(system).environment(usage)
            .environment(agents).environment(notes))
    }
    private var statusItem: NSStatusItem!
    private let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()
    private let updateDot = NSView()
    private let sidebarItem = NSMenuItem(title: "Show Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
    private let notchItem = NSMenuItem(title: "Show Notch", action: #selector(toggleNotch), keyEquivalent: "")
    private let replayItem = NSMenuItem(title: "Replay Opening Animation", action: #selector(replayAnimation), keyEquivalent: "")
    private var settingsWindow: NSWindow?
    private var snapshotPinned: Module?
    /// The sidebar is out and holds a live gauge; whether it's covered by windows is checked separately.
    private var sidebarGauges = false

    func applicationDidFinishLaunching(_ note: Notification) {
        registerFont()
        NSApp.mainMenu = Self.mainMenu()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let subject = args.dropFirst(i + 2).first
            snapshotPinned = subject.flatMap(Module.init)
            subject == "notch" ? snapshotNotch(to: args[i + 1]) : snapshot(to: args[i + 1])
            return
        }

        system.start()
        usage.start()
        media.start()
        clocks.start()
        agents.start()
        AgentHooks.refresh(prefs)

        panel = SidebarPanel()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        autoHide.isBusy = { [weak self] in self?.notes.editing == true || self?.clocks.editing != nil }
        // Tucked away, the empty panel shouldn't catch clicks meant for the windows it now floats over.
        autoHide.onChange = { [weak self] in
            guard let self else { return }
            panel.ignoresMouseEvents = autoHide.tucked
        }
        // Size the panel first: a layout at zero size would make the opening animation fly in from a corner.
        placePanel()
        panel.contentView = NSHostingView(rootView: sidebar())
        watchSidebarGauges()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            self?.pace()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.system.displaysAsleep = true
            self?.usage.paused = true
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.system.displaysAsleep = false
            self?.usage.paused = false
        }

        // Clicking away from a note ends editing, which lets its card close.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.notes.editing = false
            self?.clocks.editing = nil
        }
        notch.update()
        prefs.onLayoutChange = { [weak self] in
            self?.placePanel()
            self?.notch.update()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placePanel()
            self?.notch.update()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = .menuBarIcon
        if let button = statusItem.button {
            // An orange badge on the gauge while an update is waiting.
            updateDot.wantsLayer = true
            updateDot.layer?.backgroundColor = NSColor(Theme.accent).cgColor
            updateDot.layer?.cornerRadius = 3
            updateDot.frame = NSRect(x: button.bounds.maxX - 9, y: button.isFlipped ? 3 : button.bounds.maxY - 9, width: 6, height: 6)
            updateDot.autoresizingMask = [.minXMargin, button.isFlipped ? .maxYMargin : .minYMargin]
            updateDot.isHidden = true
            button.addSubview(updateDot)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(updateSeparator)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        sidebarItem.target = self
        menu.addItem(sidebarItem)
        notchItem.target = self
        menu.addItem(notchItem)
        menu.addItem(withTitle: "Refresh AI Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        replayItem.target = self
        menu.addItem(replayItem)
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu

        updater.onChange = { [weak self] in self?.showUpdateState() }
        showUpdateState()
        updater.start()
    }

    /// Follows whether the sidebar shows live gauges, so the system monitor can slow down when it doesn't.
    private func watchSidebarGauges() {
        sidebarGauges = withObservationTracking {
            prefs.sidebar && !autoHide.tucked && prefs.visible.contains(where: \.isLiveGauge)
        } onChange: {
            DispatchQueue.main.async { [weak self] in self?.watchSidebarGauges() }
        }
        pace()
    }

    /// A sidebar under full-screen or maximized windows shows nothing, even with gauges in it.
    private func pace() {
        system.sidebarWatching = sidebarGauges && panel.occlusionState.contains(.visible)
    }

    private func showUpdateState() {
        switch updater.state {
        case .idle:
            updateItem.isHidden = true
        case .available(let version):
            updateItem.isHidden = false
            updateItem.isEnabled = true
            updateItem.title = "Restart to Update to \(version)"
        case .installing:
            updateItem.isHidden = false
            updateItem.isEnabled = false
            updateItem.title = "Downloading Update…"
        }
        updateSeparator.isHidden = updateItem.isHidden
        updateDot.isHidden = updateItem.isHidden
    }

    @objc func installUpdate() { updater.install() }
    @objc func toggleNotch() { prefs.notch.toggle() }
    @objc func toggleSidebar() { prefs.sidebar.toggle() }
    @objc func checkForUpdates() { updater.check(manual: true) }

    private func sidebar(animated: Bool = true) -> some View {
        Sidebar(openSettings: { [weak self] in self?.openSettings() }, pinned: snapshotPinned, animated: animated)
            .environment(prefs)
            .environment(system)
            .environment(usage)
            .environment(media)
            .environment(clocks)
            .environment(notes)
            .environment(autoHide)
    }

    /// A full-height transparent strip on the chosen edge; empty areas pass clicks through.
    private func placePanel() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let width = Sidebar.maxWidth
        let x = prefs.edge == .left ? area.minX : area.maxX - width
        panel.setFrame(NSRect(x: x, y: area.minY, width: width, height: area.height), display: true)
        // Auto-hide pops out over windows like the Dock; otherwise the sidebar sits on the desktop beneath them.
        // SIDY_FLOATING=1 keeps the panel above windows, handy while developing.
        panel.level = prefs.autoHide || ProcessInfo.processInfo.environment["SIDY_FLOATING"] != nil
            ? .floating : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        autoHide.frame = panel.frame
        autoHide.edge = prefs.edge
        autoHide.enabled = prefs.sidebar && prefs.autoHide
        if prefs.sidebar { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func showSettings(_ page: SettingsPage) {
        prefs.settingsPage = page
        openSettings()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView().environment(prefs))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Sidy"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.055, alpha: 1)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func refreshUsage() { usage.refresh() }

    /// Never shown, since Sidy lives in the menu bar, but it gives the Settings window ⌘Q and ⌘W.
    private static func mainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(withTitle: "Quit Sidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let menu = NSMenu()
        for submenu in [app, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    /// A fresh hosting view starts the sidebar over, folded up, so the opening animation plays again.
    @objc func replayAnimation() { panel.contentView = NSHostingView(rootView: sidebar()) }

    private func registerFont() {
        guard let url = Resource.url("Doto", "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Dev helper: renders the sidebar with live data to a PNG and exits.
    private func snapshot(to path: String) {
        system.start()
        usage.refresh()
        media.poll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let renderer = ImageRenderer(content: sidebar(animated: false).frame(width: Sidebar.maxWidth, height: 1000).background(Color(white: 0.05)))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Dev helper: renders each state of the notch to `<path>-<state>.png` and exits. A made-up track stands in
    /// for what's really playing; the gauges, timer and agent sessions are live.
    private func snapshotNotch(to path: String) {
        system.start()
        usage.refresh()
        agents.start()
        media.preview(title: "Low Tide", artist: "The Dot Matrix", source: "Spotify", duration: 214, elapsed: 83,
                      artwork: DotArt(data: Self.sampleArtwork()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let notch = CGSize(width: 200, height: 32)
            let window = NotchView.windowSize(notch)
            // Room under the open notch for its shadow.
            let open = NotchView.openSize(notch).height + 22, tall = NotchView.openSize(notch, tall: true).height + 22
            let finished = NotchMessage(icon: Agent.claude.icon, title: "Claude finished", detail: "sidy",
                                        body: "Added a notch-only mode and typed timer times.", tint: Theme.done)
            let states: [(String, NotchView.Phase, NotchView.Tab, NotchMessage?, CGFloat)] = [
                ("closed", .closed, .music, nil, notch.height + 24),
                ("peek", .peek, .music, finished, notch.height + 70),
                ("music", .open, .music, nil, open),
                ("modules", .open, .modules, nil, open),
                ("timer", .open, .clocks, nil, tall),
                ("ai", .open, .ai, nil, tall),
            ]
            for (name, phase, tab, message, height) in states {
                let view = NotchView(notch: notch, phase: phase, tab: tab, message: message)
                    .frame(width: window.width, height: height, alignment: .top)
                    .environment(prefs).environment(media).environment(clocks).environment(system).environment(usage)
                    .environment(agents).environment(notes)
                    .background(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Stand-in album art: a sunset of soft bands, so renders don't show anyone's real cover.
    private static func sampleArtwork() -> Data {
        let image = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.3, alpha: 1), NSColor(red: 0.55, green: 0.2, blue: 0.55, alpha: 1),
                                NSColor(red: 0.12, green: 0.1, blue: 0.35, alpha: 1)])?.draw(in: rect, angle: 90)
            NSColor(red: 1, green: 0.8, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 36, height: 36)).fill()
            NSColor(red: 0.1, green: 0.08, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 96, height: 34)).fill()
            return true
        }
        return image.tiffRepresentation ?? Data()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The notch can also be switched in Settings, so the checkmark is read fresh each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        sidebarItem.state = prefs.sidebar ? .on : .off
        notchItem.state = prefs.notch ? .on : .off
        replayItem.isEnabled = prefs.sidebar
    }
}

extension NSImage {
    /// A small gauge: a closed ring, two-thirds filled clockwise from the top over a faint track, around a dot.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            for (fraction, alpha) in [(1.0, 0.3), (0.65, 1.0)] as [(CGFloat, CGFloat)] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: 6.5, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sidy"
        return image
    }()
}
