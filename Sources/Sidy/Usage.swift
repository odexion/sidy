import Foundation
import Observation

struct LimitWindow {
    var label: String         // e.g. "5h", "7d"
    var used: Double          // 0...1
    var resetsAt: Date?
}

@Observable
final class LimitState {
    var windows: [LimitWindow] = []
    var plan: String?
    var error: String?
}

/// Plan limits for Claude and Codex, read with the sign-in each CLI already keeps on disk.
@Observable
final class AIUsage {
    let claude = LimitState()
    let codex = LimitState()

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        update(claude, with: Self.fetchClaude)
        update(codex, with: Self.fetchCodex)
    }

    private func update(_ state: LimitState, with fetch: @escaping () async -> Result<Snapshot, Failure>) {
        Task.detached {
            let result = await fetch()
            await MainActor.run {
                switch result {
                case .success(let snapshot):
                    state.windows = snapshot.windows
                    state.plan = snapshot.plan
                    state.error = nil
                case .failure(let failure):
                    state.error = failure.message
                }
            }
        }
    }

    private struct Snapshot {
        var windows: [LimitWindow]
        var plan: String?
    }

    private struct Failure: Error { let message: String }

    // MARK: Claude

    private static func fetchClaude() async -> Result<Snapshot, Failure> {
        guard let token = claudeToken() else { return .failure(Failure(message: "Sign in to Claude Code")) }
        let json = await get("https://api.anthropic.com/api/oauth/usage", app: "Claude Code", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ])
        return json.map { json in
            let windows = [("5h", json["five_hour"]), ("7d", json["seven_day"])].compactMap { label, value -> LimitWindow? in
                guard let dict = value as? [String: Any], let used = number(dict["utilization"]) else { return nil }
                return LimitWindow(label: label, used: min(used / 100, 1), resetsAt: parseDate(dict["resets_at"] as? String))
            }
            return Snapshot(windows: windows)
        }
    }

    private static func claudeToken() -> String? {
        // Going through /usr/bin/security avoids a keychain prompt: Claude Code created the item with it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var data = Data()
        if (try? process.run()) != nil {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        }
        if data.isEmpty {
            data = (try? Data(contentsOf: home(".claude/.credentials.json"))) ?? Data()
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }

    // MARK: Codex

    private static func fetchCodex() async -> Result<Snapshot, Failure> {
        guard let data = try? Data(contentsOf: home(".codex/auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String
        else { return .failure(Failure(message: "Sign in to Codex")) }

        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex_cli_rs"]
        headers["ChatGPT-Account-Id"] = tokens["account_id"] as? String
        let json = await get("https://chatgpt.com/backend-api/wham/usage", app: "Codex", headers: headers)
        return json.map { json in
            let limits = json["rate_limit"] as? [String: Any] ?? [:]
            let windows = ["primary_window", "secondary_window"].compactMap { key -> LimitWindow? in
                guard let dict = limits[key] as? [String: Any], let used = number(dict["used_percent"]) else { return nil }
                let reset = number(dict["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                return LimitWindow(label: windowLabel(number(dict["limit_window_seconds"]) ?? 0),
                                   used: min(used / 100, 1), resetsAt: reset)
            }
            return Snapshot(windows: windows, plan: json["plan_type"] as? String)
        }
    }

    private static func windowLabel(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        return hours >= 24 && hours % 24 == 0 ? "\(hours / 24)d" : "\(hours)h"
    }

    // MARK: Helpers

    private static func get(_ url: String, app: String, headers: [String: String]) async -> Result<[String: Any], Failure> {
        var request = URLRequest(url: URL(string: url)!)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .failure(Failure(message: "Offline"))
        }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            return .failure(Failure(message: "Token expired · open \(app)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Failure(message: "Unexpected response"))
        }
        return .success(json)
    }

    private static func home(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: path)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Timestamps carry microseconds, which ISO8601DateFormatter rejects, so drop the fraction.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
