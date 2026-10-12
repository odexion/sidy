import AppKit
import SwiftUI

extension NSScreen {
    /// The built-in display with a camera housing, if it is connected (the lid can be closed).
    static var notched: NSScreen? { screens.first { $0.safeAreaInsets.top > 0 } }

    /// Size of the camera housing. Displays without one get a menu-bar-high stand-in.
    var notchSize: CGSize {
        if safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
        }
        // With the menu bar set to hide automatically there is nothing to measure.
        let menuBar = frame.maxY - visibleFrame.maxY
        return CGSize(width: 185, height: menuBar > 0 ? min(max(menuBar, 24), 40) : 24)
    }

    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Panels

/// Hands events the notch view can't get from SwiftUI (two-finger scrolls) to it.
final class NotchEvents {
    var scroll: ((NSEvent) -> Void)?
    /// The panel gave up the keyboard, e.g. after a click in another app.
    var resigned: (() -> Void)?
}

/// A transparent panel over the menu bar, centered on the notch. Like the sidebar, its empty areas pass clicks through.
final class NotchPanel: NSPanel {
    let events = NotchEvents()
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = NSWindow.Level(NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Windows are normally kept below the menu bar; this one belongs on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        events.resigned?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { events.scroll?(event) }
        super.sendEvent(event)
    }
}

/// Keeps a notch panel on each chosen display, rebuilds them when displays change,
/// and tucks them away while an app is full screen.
final class NotchController {
    private struct Entry {
        let panel = NotchPanel()
        var notch = CGSize.zero
    }

    private let prefs: Preferences
    private let content: (CGSize, NotchEvents) -> AnyView
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var observers: [NSObjectProtocol] = []

    init(prefs: Preferences, content: @escaping (CGSize, NotchEvents) -> AnyView) {
        self.prefs = prefs
        self.content = content
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullScreenSoon()
            })
        }
    }

    func update() {
        let screens = prefs.notch ? targetScreens : []
        let wanted = Set(screens.compactMap(\.displayID))
        for (id, entry) in entries where !wanted.contains(id) {
            entry.panel.orderOut(nil)
            entries[id] = nil
        }
        for screen in screens {
            guard let id = screen.displayID else { continue }
            var entry = entries[id] ?? Entry()
            let notch = screen.notchSize
            let size = NotchView.windowSize(notch)
            // Size the panel before its content, so the first layout isn't at zero size.
            entry.panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                        width: size.width, height: size.height), display: true)
            if entry.notch != notch {
                entry.notch = notch
                entry.panel.contentView = NSHostingView(rootView: content(notch, entry.panel.events))
            }
            entries[id] = entry
        }
        checkFullScreen()
    }

    private var targetScreens: [NSScreen] {
        switch prefs.notchDisplay {
        case .notched: [NSScreen.notched ?? NSScreen.screens.first].compactMap { $0 }
        case .main: Array(NSScreen.screens.prefix(1))
        case .all: NSScreen.screens
        }
    }

    /// Going full screen animates for a moment, so look again once it settles.
    private func checkFullScreenSoon() {
        for delay in [0.15, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkFullScreen() }
        }
    }

    /// Hides the panels on displays showing a full-screen space. Matching window bounds can't tell: on a notched
    /// display a full-screen window stops at the camera housing, and a zoomed one can fill as much.
    private func checkFullScreen() {
        let fullScreen = prefs.has(.hideInFullScreen) ? Self.fullScreenDisplays() : []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let entry = entries[id] else { continue }
            // With one set of spaces across all displays, they're listed as a single "Main" display.
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
            let covered = fullScreen.contains("Main") || uuid.map(fullScreen.contains) == true
            if covered { entry.panel.orderOut(nil) } else { entry.panel.orderFrontRegardless() }
        }
    }

    /// The UUIDs of the displays whose current space is an app's full-screen space (type 4).
    private static func fullScreenDisplays() -> Set<String> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { display in
            let space = display["Current Space"] as? [String: Any]
            return space?["type"] as? Int == 4 ? display["Display Identifier"] as? String : nil
        })
    }
}

/// Private SkyLight calls: macOS has no public way to tell a full-screen space from a desktop.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?
