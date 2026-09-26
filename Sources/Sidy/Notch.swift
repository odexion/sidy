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

    /// A normal window covering a whole display, menu bar included, means an app is full screen there.
    /// Window bounds can be read without the screen recording permission.
    private func checkFullScreen() {
        let windows = prefs.has(.hideInFullScreen)
            ? CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            : []
        let own = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let entry = entries[id] else { continue }
            // Window bounds have their origin at the top left of the primary display.
            let bounds = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                width: screen.frame.width, height: screen.frame.height)
            let covered = windows.contains { window in
                guard window[kCGWindowLayer as String] as? Int == 0,
                      window[kCGWindowOwnerPID as String] as? pid_t != own,
                      let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
                return rect == bounds
            }
            if covered { entry.panel.orderOut(nil) } else { entry.panel.orderFrontRegardless() }
        }
    }
}

// MARK: - View

/// A short note that peeks out under the notch: a charger plugged in, an agent finishing its reply.
struct NotchMessage {
    var icon: Icon
    var title: String
    var detail: String
    /// A second, quieter line, like the start of the agent's reply.
    var body: String?
    var alert = false
    /// Overrides the alert color, e.g. green for a finished agent.
    var tint: Color?
    /// What clicking the notch does while the note shows.
    var action: (() -> Void)?
}

/// Music in the notch. Closed it hugs the camera housing, widening for the track, a running timer or a working agent.
/// New tracks, alerts and finished agent replies peek out underneath, a ringing timer or alarm drops down with Stop,
/// and hovering (or clicking) opens a full player, with tabs for the timer and alarm and for agent sessions.
struct NotchView: View {
    enum Phase { case closed, peek, open }
    enum Tab { case music, modules, clocks, ai }
    private enum Look { case closed, peek, ringing, open }

    /// Room around the open notch for its shadow.
    static let margin: CGFloat = 30
    private static let peekHeight: CGFloat = 26
    /// A peek with a second line.
    private static let peekTallHeight: CGFloat = 42
    private static let ringHeight: CGFloat = 40
    /// Keeps the ears' contents clear of the shoulders and bottom corners.
    private static let earInset: CGFloat = 14
    /// Space between the open notch's straight sides and its contents, so nothing crowds the bottom curves.
    private static let openInset: CGFloat = 32
    /// Springy on the way out, settled on the way back so it tucks into the notch without bouncing.
    private static let opening = Animation.spring(response: 0.42, dampingFraction: 0.78)
    private static let closing = Animation.spring(response: 0.38, dampingFraction: 1)

    /// `tall` gives the timer and alarm controls the extra room they need.
    static func openSize(_ notch: CGSize, tall: Bool = false) -> CGSize {
        CGSize(width: max(440, notch.width + 240), height: notch.height + (tall ? 126 : 112))
    }

    static func windowSize(_ notch: CGSize) -> CGSize {
        let open = openSize(notch, tall: true)
        return CGSize(width: open.width + margin * 2, height: open.height + margin)
    }

    let notch: CGSize
    let events: NotchEvents
    var openSettings: () -> Void = {}
    @Environment(NowPlaying.self) private var media
    @Environment(Preferences.self) private var prefs
    @Environment(Clocks.self) private var clocks
    @Environment(AIUsage.self) private var usage
    @Environment(Agents.self) private var agents
    @State private var phase: Phase
    @State private var tab: Tab
    @State private var message: NotchMessage?
    @State private var volume: Float?
    @State private var hoverWork: DispatchWorkItem?
    @State private var peekWork: DispatchWorkItem?
    @State private var volumeWork: DispatchWorkItem?
    @State private var inside = false
    @State private var swipe = CGSize.zero
    @State private var swiped = false

    init(notch: CGSize, events: NotchEvents = NotchEvents(), openSettings: @escaping () -> Void = {},
         phase: Phase = .closed, tab: Tab = .music) {
        self.notch = notch
        self.events = events
        self.openSettings = openSettings
        _phase = State(initialValue: phase)
        _tab = State(initialValue: tab)
    }

    var body: some View {
        let size = self.size
        let shape = self.shape
        ZStack(alignment: .top) {
            switch look {
            case .open: expanded.transition(.notchContent)
            case .ringing: ringingPanel.transition(.notchContent)
            case .closed, .peek: compact.transition(.notchContent)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.black)
        .clipShape(shape)
        .shadow(color: .black.opacity(look == .open || look == .ringing ? 0.55 : 0), radius: 14, y: 6)
        .contentShape(shape)
        .onHover(perform: hover)
        .onTapGesture(perform: click)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(look == .open ? Self.opening : Self.closing, value: look)
        .animation(Self.closing, value: ear)
        .modifier(NotchAlerts(show: { peek($0) }))
        .onChange(of: media.title) { _, title in
            if title != nil, prefs.has(.trackPeek) { peek() }
        }
        .onChange(of: agents.announcement) { _, announcement in
            guard let session = announcement.flatMap({ agents.session($0.session) }), prefs.has(session.agent.feature) else { return }
            peek(message(for: session), for: 6)
        }
        .onAppear {
            events.scroll = scroll
            // Clicking away from a time being typed ends the typing, which lets the notch close.
            events.resigned = { if clocks.editing != nil { clocks.editing = nil } }
        }
        // Typing held the notch open; once it ends, close if the pointer has already left.
        .onChange(of: clocks.editing) { _, editing in
            if editing == nil, !inside, phase == .open { hover(false) }
        }
    }

    // MARK: State

    /// A track is loaded, playing or paused.
    private var playing: Bool { media.title != nil }
    private var timing: Bool { prefs.has(.clocks) && clocks.timerActive }
    private var ringing: Clocks.Ringing? { prefs.has(.clocks) ? clocks.ringing : nil }
    /// An agent is busy and nothing else needs the closed notch's sides.
    private var agentWorking: AgentSession? {
        guard let session = agents.working, prefs.has(session.agent.feature) else { return nil }
        return session
    }
    /// The AI tab has more sessions than its two rows show, so two-finger scrolls belong to its list.
    private var agentsScroll: Bool { phase == .open && page == .ai && agents.sessions.count > 4 }

    /// The timer controls and the session tiles need a little more height than the player.
    private var tallPage: Bool { page == .clocks || (page == .ai && !agents.sessions.isEmpty) }

    /// The open notch's tab, falling back to music when a tab's feature is off.
    private var page: Tab {
        switch tab {
        case .modules where prefs.has(.modulesTab): .modules
        case .clocks where prefs.has(.clocks): .clocks
        case .ai where prefs.has(.usageTab): .ai
        default: .music
        }
    }

    private var look: Look {
        if ringing != nil { return .ringing }
        switch phase {
        case .closed: return .closed
        case .peek: return .peek
        case .open: return .open
        }
    }

    /// Width of each side of the closed notch, the same for music and a countdown so it never grows past that.
    private var ear: CGFloat { playing || timing || agentWorking != nil ? notch.height + 12 : 0 }
    /// Art, timer ring and equalizer size, so they fit menu-bar-high stand-ins too.
    private var glyph: CGFloat { min(20, notch.height - 10) }

    private var size: CGSize {
        let compact = CGSize(width: notch.width + ear * 2, height: notch.height)
        let roomy = max(compact.width, notch.width + 2 * (notch.height + 12)) + 60
        switch look {
        case .open: return Self.openSize(notch, tall: tallPage)
        case .ringing: return CGSize(width: max(roomy, 320), height: notch.height + Self.ringHeight)
        case .peek:
            let tall = message?.body != nil
            return CGSize(width: roomy + (tall ? 40 : 0), height: notch.height + (tall ? Self.peekTallHeight : Self.peekHeight))
        case .closed: return compact
        }
    }

    private var shape: NotchShape {
        switch look {
        case .open: NotchShape(top: 16, bottom: 26)
        case .ringing: NotchShape(top: 8, bottom: 18)
        case .peek: NotchShape(top: 8, bottom: 16)
        case .closed: NotchShape(top: 6, bottom: notch.height * 0.4)
        }
    }

    // MARK: Closed and peeking

    private var compact: some View {
        VStack(spacing: 0) {
            ears
            if phase == .peek {
                peekLine.transition(.notchContent)
            }
        }
        .frame(width: size.width)
    }

    /// Art (or the timer's ring) left of the camera; the countdown (or equalizer) right of it.
    private var ears: some View {
        HStack(spacing: 0) {
            Group {
                if playing {
                    NowPlayingArt(grid: Int(glyph / 2))
                } else if timing {
                    DotRing(fraction: clocks.timeLeft / max(clocks.duration, 1), ticks: 24, tickLength: 3, innerDots: false)
                } else if let agent = agentWorking?.agent {
                    IconView(icon: agent.icon).padding(3).foregroundStyle(Theme.ink)
                }
            }
            .frame(width: glyph, height: glyph)
            .transition(.notchContent)
            .padding(.leading, Self.earInset)
            .frame(width: max(ear, 1), alignment: .leading)

            Spacer(minLength: notch.width)

            Group {
                if timing {
                    // Inset like the art; a long time spills toward the camera housing, which is black anyway.
                    Text(Format.clock(clocks.timeLeft.rounded(.up)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(clocks.timerRunning ? Theme.accent : Theme.muted)
                        .fixedSize()
                        .padding(.trailing, Self.earInset)
                } else if playing {
                    DotEqualizer(playing: media.isPlaying).frame(width: 18, height: min(14, glyph - 4))
                        .padding(.trailing, Self.earInset)
                } else if agentWorking != nil {
                    DotSpinner(color: Theme.accent).frame(width: glyph - 2, height: glyph - 2).padding(.trailing, Self.earInset)
                }
            }
            .transition(.notchContent)
            .frame(width: max(ear, 1), alignment: .trailing)
        }
        .frame(height: notch.height)
    }

    private var peekLine: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if let message {
                    let color = message.tint ?? (message.alert ? Theme.accent : Theme.ink)
                    IconView(icon: message.icon).frame(width: 11, height: 11).foregroundStyle(color)
                    Text(message.title).font(Theme.body).foregroundStyle(color).layoutPriority(1)
                    Text(message.detail).font(Theme.label).foregroundStyle(Theme.muted)
                } else {
                    Text(media.title ?? "").font(Theme.body).foregroundStyle(Theme.ink).layoutPriority(1)
                    Text(media.artist ?? "").font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
            if let body = message?.body {
                Text(body).font(Theme.label).foregroundStyle(Theme.muted)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: (message?.body == nil ? Self.peekHeight : Self.peekTallHeight) - 4)
    }

    // MARK: Ringing

    private var ringingPanel: some View {
        let alarm = ringing == .alarm
        return VStack(spacing: 0) {
            ears
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                Text(alarm ? "ALARM" : "TIMER DONE").font(Theme.label.weight(.bold)).foregroundStyle(Theme.accent)
                Text(alarm ? clocks.alarmTime : Format.clock(clocks.duration)).font(Theme.body).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                if alarm { Chip(text: "Snooze 5M", action: clocks.snooze) }
                StopButton(action: alarm ? clocks.stop : clocks.resetTimer)
            }
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(height: Self.ringHeight - 6)
        }
        .frame(width: size.width)
    }

    // MARK: Open

    private var expanded: some View {
        let open = Self.openSize(notch, tall: tallPage)
        return VStack(spacing: 0) {
            header.frame(height: notch.height)
            Group {
                switch page {
                case .music: musicPage
                case .modules: modulesPage
                case .clocks: clocksPage
                case .ai: aiPage
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, Self.openInset)
        .frame(width: open.width, height: open.height, alignment: .top)
    }

    /// The row beside the camera: tabs (or a title) on the left, and on the right the volume, the source,
    /// or what the tab is showing.
    private var header: some View {
        HStack(spacing: 6) {
            if prefs.has(.modulesTab) || prefs.has(.clocks) || prefs.has(.usageTab) {
                // Icons, since words wouldn't fit beside the camera.
                HStack(spacing: 10) {
                    tabButton("music.note", "Music", .music)
                    if prefs.has(.modulesTab) { tabButton("gauge.with.dots.needle.50percent", "Modules", .modules) }
                    if prefs.has(.clocks) { tabButton("timer", "Timer & alarm", .clocks) }
                    if prefs.has(.usageTab) { tabButton("terminal", "AI", .ai) }
                }
            } else {
                Text("NOW PLAYING").foregroundStyle(Theme.muted)
            }
            Spacer(minLength: notch.width)
            if let volume {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.ink)
                DotMeter(fraction: Double(volume), count: 10).frame(width: 48, height: 5)
            } else {
                switch page {
                case .music:
                    if let source = media.source {
                        let color = media.isPlaying ? Theme.accent : Theme.muted
                        Circle().fill(color).frame(width: 4, height: 4)
                        Text(source.uppercased()).foregroundStyle(color)
                    }
                case .modules, .clocks:
                    EmptyView()
                case .ai:
                    sessionsSummary
                }
            }
            NotchSettingsDots {
                phase = .closed
                openSettings()
            }
        }
        .font(Theme.label)
        .lineLimit(1)
    }

    /// A colored dot and count per pending state ("● 1  ● 2"), "ALL DONE", or "LIMITS" with no sessions to list.
    /// Words wouldn't fit beside the camera; the rows below spell the states out.
    @ViewBuilder private var sessionsSummary: some View {
        let pending = [AgentSession.State.working, .waiting, .failed].compactMap { state -> (AgentSession.State, Int)? in
            let count = agents.sessions.filter { $0.state == state }.count
            return count > 0 ? (state, count) : nil
        }
        if agents.sessions.isEmpty {
            Text("LIMITS").foregroundStyle(Theme.muted)
        } else if pending.isEmpty {
            Circle().fill(Theme.done).frame(width: 4, height: 4)
            Text("ALL DONE").foregroundStyle(Theme.done)
        } else {
            HStack(spacing: 8) {
                ForEach(pending, id: \.0) { state, count in
                    HStack(spacing: 4) {
                        Circle().fill(state.color).frame(width: 4, height: 4)
                        Text("\(count)").foregroundStyle(state.color)
                    }
                    .help("\(count) \(state.label)")
                }
            }
        }
    }

    /// The selected tab's icon turns orange.
    private func tabButton(_ symbol: String, _ name: String, _ value: Tab) -> some View {
        let selected = page == value
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(selected ? Theme.accent : Theme.muted)
            .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .help(name)
        .onTapGesture {
            withAnimation(Self.opening) { tab = value }
            if value == .ai { usage.refreshIfStale() }
        }
    }

    private var musicPage: some View {
        HStack(spacing: 16) {
            NowPlayingArt(grid: 40).frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.title ?? "Nothing playing")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                        Text(media.artist ?? "Spotify · YT Music").font(Theme.label).foregroundStyle(Theme.muted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if playing {
                        DotEqualizer(playing: media.isPlaying).frame(width: 16, height: 12)
                    }
                }
                Spacer(minLength: 0)
                SeekBar()
                MediaControls()
            }
        }
    }

    /// The sidebar's gauges in one row, in the sidebar's order. Modules with their own tab, or no gauge, are left out.
    private var modulesPage: some View {
        let modules = prefs.visible.filter { ![.media, .timer, .alarm, .notes].contains($0) }
        let spacing: CGFloat = 4
        let room = Self.openSize(notch).width - Self.openInset * 2
        let width = min(46, (room - spacing * CGFloat(max(modules.count - 1, 0))) / CGFloat(max(modules.count, 1)))
        return Group {
            if modules.isEmpty {
                Text("Turn modules on in Settings → General").font(Theme.body).foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: spacing) {
                    ForEach(modules) { module in
                        ModuleTile(module: module, width: width)
                            .help(module.title)
                            .contextMenu {
                                if module.showsUsage { Button("Refresh Usage", action: usage.refresh) }
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clocksPage: some View {
        HStack(alignment: .top, spacing: 24) {
            clockColumn("Timer", badge: clocks.timerBadge) { TimerControls() }
            clockColumn("Alarm", badge: clocks.alarmBadge) { AlarmControls() }
        }
    }

    private func clockColumn(_ title: String, badge: Badge?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased()).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if let badge {
                    Circle().fill(badge.color).frame(width: 4, height: 4)
                    Text(badge.text.uppercased()).foregroundStyle(badge.color)
                }
            }
            .font(Theme.label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var aiPage: some View {
        if agents.sessions.isEmpty {
            usagePage
        } else {
            // Two rows show at a time; more scroll, with a fade at the bottom edge saying so.
            let scrolls = agentsScroll
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 8) {
                        ForEach(agents.ordered) { sessionTile($0) }
                    }
                    .padding(.bottom, scrolls ? 12 : 0)
                }
                .scrollIndicators(.never)
                .scrollDisabled(!scrolls)
                .mask(
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: scrolls ? 0.82 : 1),
                                           .init(color: scrolls ? .clear : .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }

    /// A small card per session: the project on top, the colored status and its age underneath.
    /// Hovering shows the start of the reply; clicking brings the terminal forward.
    private func sessionTile(_ session: AgentSession) -> some View {
        let age = -session.since.timeIntervalSinceNow
        let color = session.state.color
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconView(icon: session.agent.icon).frame(width: 11, height: 11).foregroundStyle(Theme.ink)
                Text(session.project.isEmpty ? session.agent.name : session.project)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                if session.state == .working {
                    DotSpinner(color: color).frame(width: 9, height: 9)
                } else {
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(session.state.label).foregroundStyle(color)
                Spacer(minLength: 4)
                if age >= 60 {
                    Text(Format.duration(age)).foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        // Barely lifted off the black, so the tiles group the text without looking like buttons.
        // A session waiting on you gets a faint wash of its color instead.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(session.state == .waiting ? color.opacity(0.07) : .white.opacity(0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(session.summary ?? session.agent.name)
        .onTapGesture { agents.focus(session) }
        .contextMenu {
            Button("Remove") { withAnimation(.easeOut(duration: 0.15)) { agents.remove(session) } }
            Button("Clear All") { withAnimation(.easeOut(duration: 0.15)) { agents.clear() } }
        }
    }

    private func message(for session: AgentSession) -> NotchMessage {
        let (title, alert): (String, Bool) = switch session.state {
        case .waiting: ("\(session.agent.name) needs you", true)
        case .failed: ("\(session.agent.name) stopped", true)
        default: ("\(session.agent.name) finished", false)
        }
        return NotchMessage(icon: session.agent.icon, title: title, detail: session.project, body: session.summary,
                            alert: alert, tint: session.state.color, action: { [agents] in agents.focus(session) })
    }

    private var usagePage: some View {
        HStack(alignment: .top, spacing: 24) {
            usageColumn("Claude", icon: .asset("claude"), state: usage.claude)
            usageColumn("Codex", icon: .asset("openai"), state: usage.codex)
        }
    }

    private func usageColumn(_ title: String, icon: Icon, state: LimitState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconView(icon: icon).frame(width: 10, height: 10).foregroundStyle(Theme.ink)
                Text(title.uppercased()).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if state.error != nil, !state.windows.isEmpty {
                    Text("STALE").foregroundStyle(Theme.muted)
                } else if let plan = state.plan {
                    Text(plan.uppercased()).foregroundStyle(Theme.accent)
                }
            }
            .font(Theme.label)
            if state.windows.isEmpty {
                Text(state.error ?? "Loading…").font(Theme.body).foregroundStyle(Theme.muted).lineLimit(2)
            } else {
                ForEach(state.windows.prefix(2), id: \.label) { LimitRow(window: $0, valueSize: 15) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .contextMenu { Button("Refresh Usage", action: usage.refresh) }
    }

    // MARK: Pointer

    /// A short delay before opening lets the pointer cross the notch on its way to the menu bar;
    /// a longer one before closing forgives brief slips off the edge.
    private func hover(_ inside: Bool) {
        self.inside = inside
        hoverWork?.cancel()
        if inside && !prefs.has(.hover) { return }
        let work = DispatchWorkItem { inside ? open(haptic: true) : close() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.3), execute: work)
    }

    private func open(haptic: Bool = false) {
        hoverWork?.cancel()
        guard phase != .open, ringing == nil else { return }
        peekWork?.cancel()
        if haptic { tap() }
        // Every opening starts on the music tab, whichever tab was left open last time.
        tab = .music
        phase = .open
    }

    private func close() {
        // Stay open while a button is held, so a scrub that strays off the edge isn't cut short,
        // and while a time is being typed.
        if NSEvent.pressedMouseButtons != 0 || clocks.editing != nil { return hover(false) }
        phase = .closed
    }

    private func peek(_ message: NotchMessage? = nil, for seconds: Double? = nil) {
        guard phase != .open else { return }
        self.message = message
        phase = .peek
        peekWork?.cancel()
        let work = DispatchWorkItem { if phase == .peek { phase = .closed } }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (seconds ?? (message == nil ? 3 : 4)), execute: work)
    }

    /// Clicking a note acts on it (an agent's note brings its terminal forward); otherwise a click opens the notch.
    private func click() {
        if phase == .peek, let action = message?.action {
            action()
            phase = .closed
        } else if phase != .open {
            open()
        }
    }

    private func tap() {
        if prefs.has(.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// Two-finger swipes: sideways changes tracks, down opens, up closes; up and down on the open music tab
    /// can change the volume instead. Mouse wheels count each notch as its own swipe.
    private func scroll(_ event: NSEvent) {
        // The momentum after the fingers lift would repeat a swipe; a scrolling session list keeps its scrolls.
        guard event.momentumPhase.isEmpty, ringing == nil, !agentsScroll else { return }
        let wheel = !event.hasPreciseScrollingDeltas
        if event.phase == .began || wheel {
            swipe = .zero
            swiped = false
        }
        // In finger terms: positive is right and down, whatever the scroll direction setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let scale: CGFloat = wheel ? 12 : 1
        let dx = event.scrollingDeltaX * sign * scale, dy = event.scrollingDeltaY * sign * scale

        // Music gestures act only where the music is showing: the closed notch (its sides show the track)
        // or the open notch on its music tab.
        let music = phase != .open || page == .music
        let volumeScroll = phase == .open && page == .music && prefs.has(.scrollVolume)
        if volumeScroll, abs(dy) > abs(dx) {
            return changeVolume(by: Float(-dy) / 300)
        }
        swipe.width += dx
        swipe.height += dy
        guard !swiped else { return }
        let sideways = abs(swipe.width) > abs(swipe.height) * 1.5
        let upright = abs(swipe.height) > abs(swipe.width) * 1.5
        if prefs.has(.swipeTracks), music, playing, sideways, abs(swipe.width) > 50 {
            swiped = true
            swipe.width < 0 ? media.next() : media.previous()
            tap()
        } else if prefs.has(.swipeOpen), upright, abs(swipe.height) > 30 {
            if swipe.height > 0, phase != .open {
                swiped = true
                open(haptic: true)
            } else if swipe.height < 0, phase == .open, !volumeScroll {
                swiped = true
                phase = .closed
            }
        }
    }

    private func changeVolume(by delta: Float) {
        guard let current = volume ?? SystemVolume.level, let level = SystemVolume.set(current + delta) else { return }
        volume = level
        volumeWork?.cancel()
        let work = DispatchWorkItem { volume = nil }
        volumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

/// "•••" like the one under the sidebar's pill; opens Sidy's notch settings.
private struct NotchSettingsDots: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(hovering ? Theme.accent : Theme.muted).frame(width: 3, height: 3)
            }
        }
        .frame(width: 20, height: 16)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Notch settings")
        .padding(.leading, 4)
    }
}

/// Watches the battery, AI limits and thermals, and peeks a message out of the notch when one crosses a line.
private struct NotchAlerts: ViewModifier {
    let show: (NotchMessage) -> Void
    @Environment(Preferences.self) private var prefs
    @Environment(SystemMonitor.self) private var system
    @Environment(AIUsage.self) private var usage

    func body(content: Content) -> some View {
        content
            .onChange(of: system.battery?.pluggedIn) { old, new in
                guard prefs.has(.battery), let old, let new, old != new, let battery = system.battery else { return }
                let level = Format.percent(battery.level) + "%"
                if new {
                    show(NotchMessage(icon: .symbol("bolt.fill"), title: "Charging", detail: level))
                } else {
                    let left = battery.minutesRemaining.map { " · " + Format.duration(Double($0) * 60) } ?? ""
                    show(NotchMessage(icon: .symbol("battery.75percent"), title: "On battery", detail: level + left))
                }
            }
            .onChange(of: lowBattery) { old, new in
                guard prefs.has(.battery), new > old, let battery = system.battery else { return }
                show(NotchMessage(icon: .symbol("battery.25percent"), title: "Battery low",
                                  detail: Format.percent(battery.level) + "% left", alert: true))
            }
            .onChange(of: usage.claude.windows.map(\.used)) { old, new in
                limit("Claude", icon: .asset("claude"), state: usage.claude, old: old, new: new)
            }
            .onChange(of: usage.codex.windows.map(\.used)) { old, new in
                limit("Codex", icon: .asset("openai"), state: usage.codex, old: old, new: new)
            }
            .onChange(of: system.thermal) { old, new in
                guard prefs.has(.heat), new.rawValue >= 2, old.rawValue < 2 else { return }
                show(NotchMessage(icon: .symbol("thermometer.high"), title: "Running hot", detail: new.name, alert: true))
            }
    }

    /// 0 fine, 1 under 20%, 2 under 10%; only counts while on battery.
    private var lowBattery: Int {
        guard let battery = system.battery, !battery.pluggedIn else { return 0 }
        return battery.level < 0.1 ? 2 : battery.level < 0.2 ? 1 : 0
    }

    /// Speaks up once when a window's remaining share drops under 20% and again under 10%.
    /// The first load after launch has nothing to compare against, so it stays quiet.
    private func limit(_ name: String, icon: Icon, state: LimitState, old: [Double], new: [Double]) {
        guard prefs.has(.limits), old.count == new.count else { return }
        for (index, (before, after)) in zip(old, new).enumerated() where [0.8, 0.9].contains(where: { before < $0 && after >= $0 }) {
            let label = state.windows.indices.contains(index) ? state.windows[index].label : ""
            return show(NotchMessage(icon: icon, title: "\(name) \(label) limit", detail: Format.percent(1 - after) + "% left", alert: true))
        }
    }
}

/// The notch outline: shoulders that curve out into the menu bar at the top, rounded corners at the bottom.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { (top, bottom) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(top, rect.width / 4, rect.height / 2)
        let bottom = max(0, min(bottom, rect.height - top, rect.width / 2 - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private extension AnyTransition {
    /// Contents fade, sharpen and grow in from the notch, like the sidebar's opening animation.
    static var notchContent: AnyTransition {
        .modifier(active: NotchContentReveal(progress: 0), identity: NotchContentReveal(progress: 1))
    }
}

private struct NotchContentReveal: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
    }
}
