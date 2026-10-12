import CryptoKit
import Foundation
import Testing
@testable import Sidy

@Suite struct UpdaterTests {
    @Test func comparesVersions() {
        #expect(Updater.isNewer("1.7.2", than: "1.7.1"))
        #expect(Updater.isNewer("1.10.0", than: "1.9.9"))
        #expect(Updater.isNewer("2", than: "1.99"))
        #expect(!Updater.isNewer("1.7", than: "1.7.0"))
        #expect(!Updater.isNewer("1.7.0", than: "1.7.1"))
    }

    @Test func picksTheSignedZip() {
        let base = "https://github.com/odexion/sidy/releases/download/v1.8.0/Sidy-1.8.0-arm64.zip"
        let release = Updater.release(tag: "v1.8.0", links: [base, base + ".sig"])
        #expect(release?.asset.absoluteString == base)
        #expect(release?.signature.absoluteString == base + ".sig")
        #expect(Updater.release(tag: "v1.8.0", links: [base]) == nil)
    }

    @Test func publicKeyIsValid() throws {
        let raw = try #require(Data(base64Encoded: Updater.publicKey))
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    @Test func refusesUnsignedAndTamperedData() {
        let data = Data("Sidy.zip".utf8)
        #expect(!Updater.verify(data, signature: Data()))
        #expect(!Updater.verify(data, signature: Data("not base64!".utf8)))
        // A valid signature from a different key.
        let signature = try! Curve25519.Signing.PrivateKey().signature(for: data)
        #expect(!Updater.verify(data, signature: Data(signature.base64EncodedString().utf8)))
    }
}

@Suite struct HookTests {
    let command = "\"/Applications/Sidy.app/Contents/MacOS/Sidy\" --sidy-hook claude"

    private func parse(_ text: String?) throws -> [String: Any] {
        let text = try #require(text)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func addsHooksAndKeepsEverythingElse() throws {
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }]
          }
        }
        """
        let updated = try parse(AgentHooks.rewrite(original, command: command, events: Agent.claude.events, enabled: true))
        #expect(updated["model"] as? String == "opus")
        let hooks = try #require(updated["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == Set(Agent.claude.events.map(\.0)))
        let stop = try #require(hooks["Stop"])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
        #expect(hooks["Notification"]?.first?["matcher"] as? String == "permission_prompt|elicitation_dialog")
    }

    @Test func removingRestoresTheOriginal() throws {
        let original = """
        {
          "model": "opus"
        }

        """
        let added = try #require(AgentHooks.rewrite(original, command: command, events: Agent.claude.events, enabled: true))
        let again = try #require(AgentHooks.rewrite(added, command: command, events: Agent.claude.events, enabled: true))
        #expect(added == again)
        #expect(AgentHooks.rewrite(added, command: command, events: Agent.claude.events, enabled: false) == original)
    }

    @Test func startsAnEmptyFile() throws {
        let updated = try parse(AgentHooks.rewrite("", command: command, events: Agent.codex.events, enabled: true))
        #expect((updated["hooks"] as? [String: Any])?.count == Agent.codex.events.count)
    }

    @Test func leavesBrokenFilesAlone() {
        #expect(AgentHooks.rewrite("{ not json", command: command, events: Agent.claude.events, enabled: true) == nil)
        #expect(AgentHooks.rewrite("[1, 2]", command: command, events: Agent.claude.events, enabled: true) == nil)
    }
}

@Suite struct AgentTests {
    private func session(_ state: AgentSession.State, hoursAgo: Double, message: String? = nil) -> AgentSession {
        AgentSession(id: UUID().uuidString, agent: .claude, project: "sidy", state: state,
                     since: Date(timeIntervalSinceNow: -hoursAgo * 3600), message: message)
    }

    @Test func summarizesTheFirstLine() {
        #expect(session(.done, hoursAgo: 0, message: "\n## Done!\nmore").summary == "Done!")
        #expect(session(.done, hoursAgo: 0, message: "- `item`").summary == "item")
        #expect(session(.done, hoursAgo: 0).summary == nil)
    }

    @Test func dropsSessionsStuckForHours() {
        let sessions = [session(.working, hoursAgo: 3), session(.waiting, hoursAgo: 0.5), session(.done, hoursAgo: 30)]
        #expect(Agents.tidy(sessions).map(\.state) == [.waiting, .done])
    }

    @Test func socketCarriesEvents() async throws {
        let path = NSTemporaryDirectory() + "sidy-test-\(getpid())"
        defer { unlink(path) }
        let event = ["agent": "claude", "session": "abc", "event": "Stop", "message": "Finished"]
        let received: [String: String] = await withCheckedContinuation { done in
            var listener: DispatchSourceRead?
            listener = AgentSocket.listen(at: path) { info in
                listener?.cancel()
                done.resume(returning: info)
            }
            #expect(listener != nil)
            DispatchQueue.global().async { AgentSocket.send(event, to: path) }
        }
        #expect(received == event)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite struct UsageTests {
    @Test func readsClaudeLimits() throws {
        let json: [String: Any] = [
            "five_hour": ["utilization": 42.5, "resets_at": "2026-10-11T18:00:00.123456+00:00"],
            "seven_day": ["utilization": 120, "resets_at": NSNull()],
        ]
        let snapshot = try #require(AIUsage.claudeSnapshot(json))
        #expect(snapshot.windows.map(\.label) == ["5h", "7d"])
        #expect(snapshot.windows[0].used == 0.425)
        #expect(snapshot.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-11T18:00:00Z"))
        #expect(snapshot.windows[1].used == 1)
        #expect(snapshot.windows[1].resetsAt == nil)
        #expect(AIUsage.claudeSnapshot(["error": "nope"]) == nil)
    }

    @Test func readsCodexLimits() throws {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": ["used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1_800_000_000],
                "secondary_window": ["used_percent": 55, "limit_window_seconds": 604_800],
            ],
        ]
        let snapshot = try #require(AIUsage.codexSnapshot(json))
        #expect(snapshot.plan == "plus")
        #expect(snapshot.windows.map(\.label) == ["5h", "7d"])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(AIUsage.codexSnapshot([:]) == nil)
    }
}

@Suite struct MonitorTests {
    @Test @MainActor func pacesToWhatIsOnScreen() {
        let system = SystemMonitor()
        system.sidebarWatching = false
        system.start()
        #expect(system.interval == 60)
        system.watch()
        #expect(system.interval == 2)
        system.unwatch()
        #expect(system.interval == 60)
        system.sidebarWatching = true
        #expect(system.interval == 2)
        system.displaysAsleep = true
        #expect(system.interval == nil)
        system.displaysAsleep = false
        #expect(system.interval == 2)
        #expect(system.memoryUsed > 0)
        // Unbalanced unwatching never leaves it stuck slow.
        system.sidebarWatching = false
        system.unwatch()
        system.watch()
        #expect(system.interval == 2)
    }
}
