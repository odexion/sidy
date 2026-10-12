import Darwin
import Foundation

/// Carries hook events from the agents' hook processes to the running Sidy over a Unix socket.
/// It sits in the per-user temporary folder, which only this user can open, and the app also checks
/// that each sender is this user, so other accounts can neither read replies nor post fake events.
enum AgentSocket {
    static var path: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let folder = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0
            ? String(cString: buffer) : NSTemporaryDirectory()
        return (folder as NSString).appendingPathComponent("com.odexion.sidy.agents")
    }

    /// The most a hook sends: a 500-character message plus a few fields.
    private static let limit = 64 * 1024

    /// Sends one event and returns once it is written. Quietly does nothing when Sidy isn't running.
    static func send(_ info: [String: String], to path: String = path) {
        guard let data = try? JSONSerialization.data(withJSONObject: info), let fd = connect(path) else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Listens for events and hands each to `receive` on the main queue. Returns nil when another Sidy
    /// already listens, e.g. while a snapshot render runs beside the real app, or the socket can't be made.
    static func listen(at path: String = path, _ receive: @escaping ([String: String]) -> Void) -> DispatchSourceRead? {
        if let fd = connect(path) {
            close(fd)
            return nil
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var address = address(path),
              withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                  bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
              } }) == 0,
              chmod(path, 0o600) == 0,
              Darwin.listen(fd, 16) == 0
        else {
            close(fd)
            return nil
        }
        let queue = DispatchQueue(label: "com.odexion.sidy.agents")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard let info = read(client) else { return }
            DispatchQueue.main.async { receive(info) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Reads one event from a connection, if it came from this user and is well formed.
    private static func read(_ client: Int32) -> [String: String]? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return nil }
        // A sender that stalls shouldn't hold up the next one.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let count = Darwin.read(client, &chunk, chunk.count)
            if count <= 0 { break }
            data.append(chunk, count: count)
        }
        guard data.count <= limit else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    private static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var address = address(path),
              withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                  Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
              } }) == 0
        else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return address
    }
}
