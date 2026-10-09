import AppKit
import Observation

/// Dock-style auto-hide: the sidebar waits tucked past its screen edge, slides in when the pointer
/// touches that edge, and slides back out a moment after the pointer leaves it.
@Observable
final class AutoHide {
    /// Off the screen. The sidebar view slides to match.
    private(set) var tucked = false

    /// The pointer is over the sidebar itself, or over a card it opened. Set by the views.
    @ObservationIgnored var overContent = false { didSet { track() } }
    @ObservationIgnored var overCard = false { didSet { track() } }

    /// The strip the sidebar fills, and which of its sides is the screen edge.
    @ObservationIgnored var frame = NSRect.zero
    @ObservationIgnored var edge = SidebarEdge.right
    /// Typing in a note or a timer keeps the sidebar out.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    /// How close to the edge, in points, the pointer has to come.
    private static let reach: CGFloat = 2
    /// The wait after leaving before it tucks away, so a pointer that strays briefly doesn't lose it.
    private static let linger = 0.25

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    private func start() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.track() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] in self?.track(); return $0 }) {
            monitors.append(local)
        }
        set(tucked: true)
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hideWork?.cancel()
        set(tucked: false)
    }

    private func track() {
        if tucked {
            if atEdge { set(tucked: false) }
        } else if staying {
            hideWork?.cancel()
            hideWork = nil
        } else if hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                hideWork = nil
                if !staying { set(tucked: true) }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
        }
    }

    /// Resting against the edge counts too: the views only notice the pointer once it moves over them.
    private var staying: Bool { overContent || overCard || atEdge || isBusy() }

    private var atEdge: Bool {
        let point = NSEvent.mouseLocation
        let touching = edge == .left ? point.x <= frame.minX + Self.reach : point.x >= frame.maxX - Self.reach
        return touching && point.y >= frame.minY && point.y <= frame.maxY
    }

    private func set(tucked: Bool) {
        guard tucked != self.tucked else { return }
        self.tucked = tucked
        onChange?()
    }
}
