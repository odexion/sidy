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

    /// Dev helper: renders the notch closed, peeking, open and on its AI tab, with live data, to a PNG and exits.
    private func snapshotNotch(to path: String) {
        system.start()
        usage.refresh()
        media.poll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let notch = CGSize(width: 200, height: 32)
            let window = NotchView.windowSize(notch)
            let states: [(NotchView.Phase, NotchView.Tab)] = [(.closed, .music), (.peek, .music), (.open, .music), (.open, .modules), (.open, .clocks), (.open, .ai)]
            let views = VStack(spacing: 16) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    NotchView(notch: notch, phase: state.0, tab: state.1).frame(width: window.width, height: window.height)
                }
            }
            let renderer = ImageRenderer(content: views
                .environment(prefs).environment(media).environment(clocks).environment(system).environment(usage)
                .environment(agents).environment(notes)
                .background(Color(white: 0.3)))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
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
