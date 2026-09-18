import AppKit
import SwiftUI

@main
enum Main {
    static let delegate = AppDelegate()

    static func main() {
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

    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()
    private let updateDot = NSView()
    private var settingsWindow: NSWindow?
    private var snapshotPinned: Module?

    func applicationDidFinishLaunching(_ note: Notification) {
        registerFont()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshotPinned = args.dropFirst(i + 2).first.flatMap(Module.init)
            snapshot(to: args[i + 1])
            return
        }

        system.start()
        usage.start()
        media.start()
        clocks.start()

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        panel.orderFrontRegardless()

        prefs.onLayoutChange = { [weak self] in self?.placePanel() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placePanel()
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
        menu.addItem(withTitle: "Refresh AI Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Replay Opening Animation", action: #selector(replayAnimation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    private func sidebar(animated: Bool = true) -> some View {
        Sidebar(openSettings: { [weak self] in self?.openSettings() }, pinned: snapshotPinned, animated: animated)
            .environment(prefs)
            .environment(system)
            .environment(usage)
            .environment(media)
            .environment(clocks)
    }

    /// A full-height transparent strip on the chosen edge; empty areas pass clicks through.
    private func placePanel() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let width = Sidebar.maxWidth
        let x = prefs.edge == .left ? area.minX : area.maxX - width
        panel.setFrame(NSRect(x: x, y: area.minY, width: width, height: area.height), display: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView().environment(prefs))
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
