import Foundation
import Observation

/// Reads the system "Now Playing" session, so Spotify, Music and YouTube Music in any browser all work.
/// macOS only exposes MediaRemote to Apple-signed processes, so the MediaBridge dylib runs inside /usr/bin/perl.
@Observable
final class NowPlaying {
    var title: String?
    var artist: String?
    var isPlaying = false
    var duration: Double?
    private(set) var source: String?
    private var elapsed = 0.0
    private var elapsedAt = Date()

    private let prefs: Preferences
    private var timer: Timer?
    private var polling = false

    private static let bridge: String? = {
        let candidates = [
            Bundle.main.privateFrameworksURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap { $0?.appending(path: "libMediaBridge.dylib").path }
        return candidates.first(where: FileManager.default.fileExists)
    }()

    private static let apps = [
        "com.spotify.client": "Spotify",
        "com.apple.Music": "Music",
        "com.github.th-ch.youtube-music": "YouTube Music",
    ]

    private static let browsers: Set<String> = [
        "app.zen-browser.zen", "org.mozilla.firefox", "com.google.Chrome", "com.microsoft.edgemac",
        "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    init(prefs: Preferences) { self.prefs = prefs }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        guard prefs.visible.contains(.media), !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let output = Self.call("mb_info")
            let info = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            DispatchQueue.main.async {
                self.apply(info)
                self.polling = false
            }
        }
    }

    func playPause() { send("mb_toggle") }
    func next() { send("mb_next") }
    func previous() { send("mb_previous") }

    /// Playback position, extrapolated from the last report while playing.
    func position(at date: Date = Date()) -> Double {
        let position = elapsed + (isPlaying ? date.timeIntervalSince(elapsedAt) : 0)
        return min(max(position, 0), duration ?? position)
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        elapsedAt = Date()
        send("mb_seek", environment: ["MB_SEEK": String(seconds)])
    }

    private func send(_ command: String, environment: [String: String] = [:]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.call(command, environment: environment)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() }
        }
    }

    private func apply(_ info: [String: Any]) {
        let title = (info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.title = title
        artist = info["artist"] as? String
        isPlaying = title != nil && info["playing"] as? Bool == true
        source = title == nil ? nil : Self.sourceName(info)
        duration = (info["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        elapsed = info["elapsed"] as? Double ?? 0
        elapsedAt = (info["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    /// Browsers don't say which site is playing. YouTube Music sends an album, plain YouTube videos don't.
    private static func sourceName(_ info: [String: Any]) -> String? {
        let bundle = info["bundle"] as? String ?? ""
        if let name = apps[bundle] { return name }
        if browsers.contains(bundle), let album = info["album"] as? String, !album.isEmpty { return "YT Music" }
        return info["app"] as? String
    }

    private static func call(_ function: String, environment: [String: String] = [:]) -> Data? {
        guard let bridge else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use DynaLoader;
            my ($path, $name) = @ARGV;
            my $lib = DynaLoader::dl_load_file($path, 0) or exit 1;
            my $symbol = DynaLoader::dl_find_symbol($lib, $name) or exit 1;
            DynaLoader::dl_install_xsub("main::run", $symbol);
            run();
            """, bridge, function]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
