import Darwin
import Foundation

/// Blocking one-shot client for the daemon's unix control socket:
/// connect, write one JSON line, read one JSON line, close.
/// Used by the CLI subcommands and the daemon tests.
public enum ControlClient {
    public enum ClientError: Error, CustomStringConvertible {
        case daemonNotRunning(socketPath: String)
        case ioFailure(String)
        case badResponse

        public var description: String {
            switch self {
            case .daemonNotRunning(let path):
                "daemon is not running (no socket at \(path)) — start it with `ttybuild serve`"
            case .ioFailure(let detail): "socket I/O failed: \(detail)"
            case .badResponse: "malformed response from daemon"
            }
        }
    }

    public static func roundTrip(socketPath: String, request: [String: Any]) throws -> [String: Any] {
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.ioFailure(String(cString: strerror(errno))) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.daemonNotRunning(socketPath: socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.daemonNotRunning(socketPath: socketPath) }

        try line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw ClientError.ioFailure(String(cString: strerror(errno))) }
                offset += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while !response.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                response.append(contentsOf: chunk[0..<n])
            } else {
                break
            }
            if response.count > 1 << 20 { throw ClientError.badResponse }
        }
        if let newline = response.firstIndex(of: 0x0A) {
            response = response.prefix(upTo: newline)
        }
        guard !response.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else { throw ClientError.badResponse }
        return object
    }
}
