import AppKit
import CryptoKit

/// Checks GitHub for a newer release and installs it in place of the running app.
final class Updater {
    enum State: Equatable {
        case idle
        case available(version: String)
        case installing
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/odexion/sidy/releases/latest")!
    /// Releases are signed with the matching private key (scripts/sign-update.swift), and anything else is refused,
    /// so a tampered release or download can't replace the app.
    static let publicKey = "GnKRzUqmkLoUTiAdntN4MK6ti25Gh14eTesiLxaAHHg="

    private(set) var state = State.idle { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?

    private var release: Release?
    private var timer: Timer?

    private var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// Only a real app bundle can be replaced; `swift run` builds have none.
    private var bundle: URL? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil }

    func start() {
        guard bundle != nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// `manual` checks come from the menu and always report back, even when there is nothing new.
    func check(manual: Bool = false) {
        Task { @MainActor in
            guard state != .installing else { return }
            guard let release = await Self.fetchLatest() else {
                if manual { alert("Couldn't check for updates", "GitHub could not be reached. Try again in a moment.") }
                return
            }
            let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            guard Self.isNewer(version, than: current) else {
                state = .idle
                if manual { alert("Sidy is up to date", "You have the latest version, \(current).") }
                return
            }
            self.release = release
            state = .available(version: version)
            if manual, alert("Sidy \(version) is available", "You have \(current). Sidy will restart to finish updating.",
                             buttons: ["Restart to Update", "Later"]) {
                install()
            }
        }
    }

    /// Shows a dialog and returns whether the first button was chosen.
    @discardableResult
    private func alert(_ title: String, _ message: String, buttons: [String] = []) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Downloads the release, then quits; a detached script swaps the bundle once Sidy has exited and relaunches it.
    func install() {
        guard case .available = state, let release, let bundle else { return }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(URL(string: "https://github.com/odexion/sidy/releases/latest")!)
            return
        }
        let previous = state
        state = .installing
        Task { @MainActor in
            do {
                let work = FileManager.default.temporaryDirectory.appending(path: "sidy-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let (signature, _) = try await URLSession.shared.data(from: release.signature)
                let (download, _) = try await URLSession.shared.download(from: release.asset)
                let zip = work.appending(path: "Sidy.zip")
                try FileManager.default.moveItem(at: download, to: zip)
                guard Self.verify(try Data(contentsOf: zip), signature: signature) else {
                    throw Failure("The download didn't match Sidy's signature, so it wasn't installed.")
                }
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appending(path: "unpacked").path])
                let fresh = work.appending(path: "unpacked/Sidy.app")
                guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
                try Self.relaunch(replacing: bundle, with: fresh, work: work)
                NSApp.terminate(nil)
            } catch {
                state = previous
                alert("Couldn't update Sidy", error.localizedDescription)
            }
        }
    }

    private static func relaunch(replacing app: URL, with fresh: URL, work: URL) throws {
        // Keeps the old bundle until the new one is in place, and puts it back if the copy fails.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$2" "$4/old.app" || exit 1
        if /usr/bin/ditto "$3" "$2"; then
            /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        else
            rm -rf "$2"; mv "$4/old.app" "$2"
        fi
        open "$2"
        rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, fresh.path, work.path]
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    struct Release {
        var tag: String
        var asset: URL
        var signature: URL
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let key = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
              let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(raw, for: data)
    }

    private static func fetchLatest() async -> Release? {
        var request = URLRequest(url: latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let release = release(tag: tag, links: assets.compactMap { $0["browser_download_url"] as? String })
        else { return nil }
        return release
    }

    /// The app's zip and its signature. A release without a signature is skipped.
    static func release(tag: String, links: [String]) -> Release? {
        guard let link = links.first(where: { $0.hasSuffix("-arm64.zip") }), links.contains(link + ".sig"),
              let asset = URL(string: link), let signature = URL(string: link + ".sig") else { return nil }
        return Release(tag: tag, asset: asset, signature: signature)
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
