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

    func applicationDidFinishLaunching(_ note: Notification) {
        registerFont()

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
        // SIDY_FLOATING=1 keeps the panel above windows, handy while developing.
        panel.level = ProcessInfo.processInfo.environment["SIDY_FLOATING"] != nil
            ? .floating : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Size the panel first: a layout at zero size would make the opening animation fly in from a corner.
        placePanel()
        panel.contentView = NSHostingView(rootView: sidebar())

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
    }

    /// A full-height transparent strip on the chosen edge; empty areas pass clicks through.
    private func placePanel() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let width = Sidebar.maxWidth
        let x = prefs.edge == .left ? area.minX : area.maxX - width
        panel.setFrame(NSRect(x: x, y: area.minY, width: width, height: area.height), display: true)
        if prefs.sidebar { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func showSettings(_ page: SettingsPage) {
        prefs.settingsPage = page
        openSettings()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView().environment(prefs))
            // The General and Notch pages differ in height; the window follows whichever is showing.
            hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
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
    /// A small gauge, like the compact tiles: twelve evenly spaced ticks, the unfilled ones dimmed.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9), ticks = 12, lit = 8
            for tick in 0..<ticks {
                let angle = Double(tick) / Double(ticks) * 2 * .pi
                let direction = NSPoint(x: sin(angle), y: cos(angle))
                let line = NSBezierPath()
                line.move(to: NSPoint(x: center.x + direction.x * 5, y: center.y + direction.y * 5))
                line.line(to: NSPoint(x: center.x + direction.x * 7.5, y: center.y + direction.y * 7.5))
                line.lineWidth = 2
                line.lineCapStyle = .round
                NSColor.black.withAlphaComponent(tick < lit ? 1 : 0.35).setStroke()
                line.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sidy"
        return image
    }()
}
