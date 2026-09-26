import AppKit
import JavaScriptCore
import Observation
import SwiftUI

/// A terminal coding agent whose hooks can report to Sidy.
enum Agent: String, CaseIterable, Codable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
    var icon: Icon { .asset(self == .claude ? "claude" : "openai") }
    var feature: NotchFeature { self == .claude ? .claudeCode : .codex }

    /// The file each CLI reads its hooks from.
    var hooksFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: self == .claude ? ".claude/settings.json" : ".codex/hooks.json")
    }

    /// Hook events Sidy listens to, with a matcher where one is needed.
    var events: [(String, String?)] {
        switch self {
        case .claude:
            // Only the prompts that wait on the user; "idle_prompt" would repeat every finish a minute later.
            [("UserPromptSubmit", nil), ("Stop", nil), ("StopFailure", nil),
             ("Notification", "permission_prompt|elicitation_dialog"), ("SessionEnd", nil)]
        case .codex:
            [("UserPromptSubmit", nil), ("Stop", nil), ("SessionEnd", nil)]
        }
    }
}

/// Adds and removes Sidy's hooks in the agents' settings, and forwards hook events to the running app.
enum AgentHooks {
    /// Marks Sidy's own hook commands, so they can be found and removed without touching anyone else's.
    static let marker = "--sidy-hook"
    static let notification = Notification.Name("com.odexion.sidy.agent")

    /// Installs or removes the hooks. Returns a message when that couldn't be done.
    static func set(_ agent: Agent, enabled: Bool) -> String? {
        let file = agent.hooksFile
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else {
            return enabled ? "\(agent.name) isn't set up on this Mac" : nil
        }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !enabled && !text.contains(marker) { return nil }
        guard let path = Bundle.main.executablePath else { return "Couldn't find Sidy" }
        let command = "\"\(path)\" \(marker) \(agent.rawValue)"
        guard let updated = rewrite(text, command: command, events: agent.events, enabled: enabled) else {
            return "Couldn't read \(file.lastPathComponent)"
        }
        if updated == text { return nil }
        // Keep the original once, in case anything about the edit is unwelcome.
        let backup = file.appendingPathExtension("sidy-backup")
        if !text.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try? text.write(to: backup, atomically: true, encoding: .utf8)
        }
        do {
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "Couldn't save \(file.lastPathComponent)"
        }
        return nil
    }

    /// Refreshes installed hooks at launch, so they follow Sidy if the app moved.
    static func refresh(_ prefs: Preferences) {
        for agent in Agent.allCases where prefs.notchFeatures.contains(agent.feature) {
            _ = set(agent, enabled: true)
        }
    }

    /// JSON.parse and JSON.stringify keep the file's key order and match the CLIs' own two-space formatting,
    /// so the edit only shows up as Sidy's entries.
    private static func rewrite(_ text: String, command: String, events: [(String, String?)], enabled: Bool) -> String? {
        guard let context = JSContext() else { return nil }
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        context.evaluateScript("""
            function update(text, command, marker, events, enabled) {
              const settings = text.trim() ? JSON.parse(text) : {};
              if (typeof settings !== 'object' || settings === null || Array.isArray(settings)) throw new Error('not an object');
              const hooks = settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};
              const ours = h => h && typeof h.command === 'string' && h.command.includes(marker);
              for (const event of Object.keys(hooks)) {
                if (!Array.isArray(hooks[event])) continue;
                const groups = hooks[event]
                  .map(g => g && Array.isArray(g.hooks) ? { ...g, hooks: g.hooks.filter(h => !ours(h)) } : g)
                  .filter(g => !(g && Array.isArray(g.hooks)) || g.hooks.length > 0);
                if (groups.length) hooks[event] = groups; else delete hooks[event];
              }
              if (enabled) for (const [event, matcher] of events) {
                const group = matcher ? { matcher } : {};
                group.hooks = [{ type: 'command', command, async: true, timeout: 10 }];
                hooks[event] = [...(hooks[event] || []), group];
              }
              if (Object.keys(hooks).length) settings.hooks = hooks; else delete settings.hooks;
              return JSON.stringify(settings, null, 2) + '\\n';
            }
            """)
        let pairs = events.map { [$0.0, $0.1 ?? NSNull()] as [Any] }
        let result = context.objectForKeyedSubscript("update")?.call(withArguments: [text, command, marker, pairs, enabled])
        guard !failed, let result, result.isString else { return nil }
        return result.toString()
    }

    /// Runs as the hook itself: reads the event from stdin, hands it to the running Sidy, and exits.
    /// It prints nothing, since some hooks' output is shown to the model.
    static func forward(_ agent: String) {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var info = ["agent": agent]
        info["event"] = input["hook_event_name"] as? String
        info["session"] = input["session_id"] as? String
        info["cwd"] = input["cwd"] as? String
        let message = ["last_assistant_message", "message", "error"].lazy.compactMap { input[$0] as? String }.first
        info["message"] = message.map { String($0.prefix(500)) }
        // The terminal the agent runs in, so the notch can bring it forward.
        info["app"] = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        // Hooks run side by side and can arrive out of order; the time lets Sidy drop stale ones.
        info["time"] = String(Date().timeIntervalSince1970)
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: info, deliverImmediately: true)
    }
}

struct AgentSession: Identifiable, Codable {
    enum State: String, Codable {
        case working, waiting, done, failed

        var label: String {
            switch self {
            case .working: "running"
            case .waiting: "needs you"
            case .done: "done"
            case .failed: "stopped"
            }
        }

        /// Sessions waiting on you list first, then busy ones, then stopped, then finished.
        var priority: Int {
            switch self {
            case .waiting: 0
            case .working: 1
            case .failed: 2
            case .done: 3
            }
        }

        var color: Color {
            switch self {
            case .working: Theme.accent
            case .waiting: Theme.attention
            case .done: Theme.done
            case .failed: Theme.failed
            }
        }
    }

    let id: String
    let agent: Agent
    var project: String
    var state: State
    var since: Date
    var message: String?
    var app: String?
    /// When the latest hook for this session ran.
    var updated: Double = 0

    /// The message on one line, without Markdown's leading marks.
    var summary: String? {
        guard let message else { return nil }
        let line = message.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*->` ")) }
            .first { !$0.isEmpty }
        return line
    }
}

/// Claude Code and Codex sessions, as reported by their hooks. Kept across restarts until removed.
@Observable
final class Agents {
    struct Announcement: Equatable {
        let id = UUID()
        let session: String

        static func == (a: Announcement, b: Announcement) -> Bool { a.id == b.id }
    }

    /// Most recent first.
    private(set) var sessions: [AgentSession] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(sessions), forKey: "agents.sessions") }
    }
    /// The latest finish or call for attention, for the notch to announce.
    private(set) var announcement: Announcement?
    @ObservationIgnored private var observer: NSObjectProtocol?

    var working: AgentSession? { sessions.first { $0.state == .working } }

    /// What needs you first, newest first within each state.
    var ordered: [AgentSession] {
        sessions.enumerated()
            .sorted { ($0.element.state.priority, $0.offset) < ($1.element.state.priority, $1.offset) }
            .map(\.element)
    }

    init() {
        let saved = UserDefaults.standard.data(forKey: "agents.sessions")
        sessions = Self.tidy(saved.flatMap { try? JSONDecoder().decode([AgentSession].self, from: $0) } ?? [])
    }

    func remove(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
    }

    func clear() {
        sessions = []
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(forName: AgentHooks.notification, object: nil, queue: .main) { [weak self] note in
            self?.receive(note.userInfo ?? [:])
        }
    }

    func session(_ id: String) -> AgentSession? { sessions.first { $0.id == id } }

    /// Brings the session's terminal to the front.
    func focus(_ session: AgentSession) {
        guard let app = session.app, let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else { return }
        running.activate()
    }

    /// Keeps finished replies until they're removed, but drops sessions stuck "working" or "waiting" for hours,
    /// e.g. a terminal closed mid-reply, which never sends its finish.
    private static func tidy(_ sessions: [AgentSession]) -> [AgentSession] {
        Array(sessions.filter { $0.state == .done || $0.state == .failed || $0.since.timeIntervalSinceNow > -2 * 3600 }.prefix(12))
    }

    private func receive(_ info: [AnyHashable: Any]) {
        guard let agent = (info["agent"] as? String).flatMap(Agent.init),
              let id = info["session"] as? String, let event = info["event"] as? String else { return }
        let cwd = info["cwd"] as? String
        var session = self.session(id) ?? AgentSession(id: id, agent: agent, project: "", state: .working, since: Date())
        let time = (info["time"] as? String).flatMap(Double.init) ?? Date().timeIntervalSince1970
        guard time >= session.updated else { return }
        session.updated = time
        if let cwd { session.project = URL(fileURLWithPath: cwd).lastPathComponent }
        session.app = info["app"] as? String ?? session.app
        session.since = Date()
        session.message = info["message"] as? String
        var announce = true
        switch event {
        case "UserPromptSubmit":
            session.state = .working
            session.message = nil
            announce = false
        case "Stop": session.state = .done
        case "StopFailure": session.state = .failed
        case "Notification": session.state = .waiting
        case "SessionEnd":
            sessions.removeAll { $0.id == id }
            return
        default: return
        }
        sessions.removeAll { $0.id == id }
        sessions.insert(session, at: 0)
        sessions = Self.tidy(sessions)
        if announce { announcement = Announcement(session: id) }
    }
}
