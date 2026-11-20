import Foundation

/// Talks to the Deadbolt app's socket in the shared app-group container: one JSON request line → one reply line.
/// Used by the Chrome native-messaging host and the Safari extension. The app checks the caller's code signature.
enum BridgeClient {
    static let groupID = "4CMN2DUGUL.com.osborne.deadbolt"

    static func socketPath() -> String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("bridge.sock").path
    }

    /// Sends one request; returns the reply, or nil if the app isn't listening.
    static func forward(_ request: Data, timeout: Int = 60) -> Data? {
        guard let path = socketPath() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            p.copyBytes(from: bytes)
            p[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0) // Touch ID may take a while
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = request
        line.append(0x0a)
        guard line.withUnsafeBytes({ write(fd, $0.baseAddress, line.count) }) == line.count else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
            if out.last == 0x0a { out.removeLast(); break }
        }
        return out.isEmpty ? nil : out
    }
}
