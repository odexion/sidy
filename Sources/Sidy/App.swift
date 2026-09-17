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

    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
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
        statusItem.button?.image = NSImage(systemSymbolName: "circle.grid.3x3", accessibilityDescription: "Sidy")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Refresh AI Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func sidebar(animated: Bool = true) -> some View {
        Sidebar(openSettings: { [weak self] in self?.openSettings() }, pinned: snapshotPinned, animated: animated)
            .environment(prefs)
            .environment(system)
            .environment(usage)
            .environment(media)
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
