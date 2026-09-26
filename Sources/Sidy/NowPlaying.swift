import AppKit
import Observation

/// Reads the system "Now Playing" session, so Spotify, Music and YouTube Music in any browser all work.
/// macOS only exposes MediaRemote to Apple-signed processes, so the MediaBridge dylib runs inside /usr/bin/perl.
/// A long-running bridge process reports changes as they happen; polling takes over if it keeps failing.
@Observable
final class NowPlaying {
    var title: String?
    var artist: String?
    var isPlaying = false
    var duration: Double?
    private(set) var source: String?
    private var storedArtwork: DotArt?
    private var artworkKey: String?
    @ObservationIgnored private var lookupKey: String?
    private var elapsed = 0.0
    private var elapsedAt = Date()

    private let prefs: Preferences
    private var timer: Timer?
    private var polling = false
    @ObservationIgnored private var stream: Process?
    @ObservationIgnored private var streamFailures = 0

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
        startStream()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !wanted { stopStream() } else if stream == nil { startStream(); poll() }
        }
    }

    /// Something on screen shows the track.
    private var wanted: Bool { prefs.visible.contains(.media) || prefs.notch }

    /// Album art for the current track, once the player has sent it.
    var artwork: DotArt? { artworkKey != nil && artworkKey == trackKey ? storedArtwork : nil }

    /// Matches the key MediaBridge builds, so artwork is only sent when the track changes.
    private var trackKey: String? { title.map { $0 + "\u{1F}" + (artist ?? "") } }

    /// One snapshot, for when the stream isn't running.
    func poll() {
        guard wanted, stream == nil, !polling else { return }
        polling = true
        let have = artworkKey ?? ""
        DispatchQueue.global(qos: .utility).async {
            let output = Self.bridgeProcess("mb_info", environment: ["MB_ARTWORK_HAVE": have]).flatMap(Self.run)
            let (info, artwork) = Self.parse(output ?? Data())
            DispatchQueue.main.async {
                self.receive(info, artwork: artwork)
                self.polling = false
            }
        }
    }

    private func startStream() {
        // A bridge that keeps dying (e.g. a future macOS closing the loophole) leaves polling in charge.
        guard wanted, stream == nil, streamFailures < 5, let process = Self.bridgeProcess("mb_stream") else { return }
        let output = Pipe()
        process.standardOutput = output
        // Sidy holds the write end; when Sidy quits it closes and the bridge exits.
        process.standardInput = Pipe()
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let (info, artwork) = Self.parse(Data(line))
                DispatchQueue.main.async {
                    self?.receive(info, artwork: artwork)
                    self?.streamFailures = 0
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.stream === process else { return }
                self.stream = nil
                self.streamFailures += 1
            }
        }
        guard (try? process.run()) != nil else { streamFailures += 1; return }
        stream = process
    }

    private func stopStream() {
        let process = stream
        stream = nil
        process?.terminate()
    }

    private static func parse(_ data: Data) -> ([String: Any], DotArt?) {
        let info = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let artwork = (info["artwork"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(DotArt.init)
        return (info, artwork)
    }

    private func receive(_ info: [String: Any], artwork: DotArt?) {
        apply(info)
        if let artwork {
            storedArtwork = artwork
            artworkKey = trackKey
        } else if self.artwork == nil {
            lookUpArtwork()
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

    /// Browsers publish artwork only briefly, or not at all while their tab is in the background,
    /// so a track without any is looked up once in the iTunes catalog. Only a matching artist counts.
    private func lookUpArtwork() {
        guard let key = trackKey, lookupKey != key, let title, let artist, !artist.isEmpty else { return }
        lookupKey = key
        // "Song (Official Video)" finds nothing; the bare title does.
        let name = title.replacingOccurrences(of: #"\s*[(\[].*?[)\]]"#, with: "", options: .regularExpression)
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(name)"),
                             URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "5")]
        URLSession.shared.dataTask(with: search.url!) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let match = (json?["results"] as? [[String: Any]])?.first { result in
                guard let found = (result["artistName"] as? String)?.lowercased() else { return false }
                return found.contains(artist.lowercased()) || artist.lowercased().contains(found)
            }
            guard let small = match?["artworkUrl100"] as? String,
                  let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "300x300bb")) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let art = data.flatMap(DotArt.init) else { return }
                DispatchQueue.main.async {
                    // The player's own artwork wins if it turned up meanwhile.
                    guard self.trackKey == key, self.artwork == nil else { return }
                    self.storedArtwork = art
                    self.artworkKey = key
                }
            }.resume()
        }.resume()
    }

    private func send(_ command: String, environment: [String: String] = [:]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.bridgeProcess(command, environment: environment).flatMap(Self.run)
            // The stream reports the change by itself; polling needs a nudge.
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

    private static func bridgeProcess(_ function: String, environment: [String: String] = [:]) -> Process? {
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
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs a one-shot bridge call and returns what it printed.
    private static func run(_ process: Process) -> Data? {
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

/// Album art shrunk to a small square grid, for drawing as colored dots.
struct DotArt {
    static let size = 96
    /// Row-major RGB, top-left first.
    let pixels: [SIMD3<Double>]

    init?(data: Data) {
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = Self.size
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Fill the square, cropping the longer side.
            let scale = CGFloat(n) / CGFloat(min(image.width, image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (CGFloat(n) - width) / 2, y: (CGFloat(n) - height) / 2, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        pixels = stride(from: 0, to: bytes.count, by: 4).map {
            SIMD3(Double(bytes[$0]), Double(bytes[$0 + 1]), Double(bytes[$0 + 2])) / 255
        }
    }

    /// The art averaged down to `grid`×`grid` cells.
    func colors(_ grid: Int) -> [SIMD3<Double>] {
        let n = Self.size, grid = min(grid, n)
        // Each cell covers the stored pixels between its edges, so any grid size works.
        let edges = (0...grid).map { $0 * n / grid }
        return (0..<grid * grid).map { cell in
            let xs = edges[cell % grid]..<edges[cell % grid + 1], ys = edges[cell / grid]..<edges[cell / grid + 1]
            var sum = SIMD3<Double>()
            for y in ys { for x in xs { sum += pixels[y * n + x] } }
            return sum / Double(xs.count * ys.count)
        }
    }
}
