import Darwin
import Foundation
import TTYBuildKit

/// Client end of an upgraded `attach` connection
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §4): sends the NDJSON attach request,
/// reads the one-line reply, then speaks length-prefixed plaintext frames
/// (`u32 LE length || frame`) both ways. Used by the attach CLI and tests.
public final class AttachStream: @unchecked Sendable {
    public enum StreamError: Error, CustomStringConvertible {
        case rejected(String)
        case framingViolation

        public var description: String {
            switch self {
            case .rejected(let message): message
            case .framingViolation: "malformed attach stream"
            }
        }
    }

    /// The daemon's attach acknowledgement.
    public struct Handshake: Sendable {
        public let sessionId: Int
        public let title: String
        public let alive: Bool
        /// This connection's arbiter identity: a `takeover` whose holder
        /// principal equals `"attach:\(connectionID)"` means *we* hold.
        public let connectionID: Int
    }

    private let fd: Int32
    /// Bytes read past the handshake newline are already stream frames.
    private var buffer: Data
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    private init(fd: Int32, remainder: Data) {
        self.fd = fd
        self.buffer = remainder
    }

    /// Connects, requests the attach (`{"cmd":"attach","id":N}` or
    /// `{"new":true,...}`), and returns the streaming handle. `readTimeout`
    /// bounds each blocking `readFrame` (nil: block indefinitely — the CLI's
    /// read loop must survive an idle overnight session).
    public static func connect(
        socketPath: String,
        request: [String: Any],
        readTimeout: TimeInterval? = nil
    ) throws -> (stream: AttachStream, handshake: Handshake) {
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlClient.ClientError.ioFailure(String(cString: strerror(errno)))
        }
        var success = false
        defer { if !success { Darwin.close(fd) } }

        if let readTimeout {
            var timeout = timeval(
                tv_sec: Int(readTimeout),
                tv_usec: Int32((readTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlClient.ClientError.daemonNotRunning(socketPath: socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw ControlClient.ClientError.daemonNotRunning(socketPath: socketPath)
        }

        try line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else {
                    throw ControlClient.ClientError.ioFailure(
                        String(cString: strerror(errno))
                    )
                }
                offset += n
            }
        }

        // Read the single reply line; keep everything after it — the daemon
        // starts streaming frames immediately.
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while !response.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ControlClient.ClientError.badResponse }
            response.append(contentsOf: chunk[0..<n])
            if response.count > 1 << 20 {
                throw ControlClient.ClientError.badResponse
            }
        }
        let newline = response.firstIndex(of: 0x0A)!
        let replyLine = response.prefix(upTo: newline)
        let remainder = Data(response.suffix(from: response.index(after: newline)))

        guard let object = try? JSONSerialization.jsonObject(with: replyLine)
            as? [String: Any]
        else { throw ControlClient.ClientError.badResponse }
        guard object["ok"] as? Bool == true else {
            throw StreamError.rejected(
                object["err"] as? String ?? "attach rejected"
            )
        }
        guard let sessionId = object["id"] as? Int else {
            throw ControlClient.ClientError.badResponse
        }
        let handshake = Handshake(
            sessionId: sessionId,
            title: object["title"] as? String ?? "",
            alive: object["alive"] as? Bool ?? true,
            connectionID: object["conn"] as? Int ?? 0
        )
        success = true
        return (AttachStream(fd: fd, remainder: remainder), handshake)
    }

    /// Serialized; safe from any thread.
    public func send(_ frame: Frame) throws {
        let body = frame.encoded()
        let length = UInt32(body.count).littleEndian
        var wire = withUnsafeBytes(of: length) { Data($0) }
        wire.append(body)
        try writeLock.withLock {
            try wire.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 {
                        if errno == EINTR { continue }
                        throw ControlClient.ClientError.ioFailure(
                            String(cString: strerror(errno))
                        )
                    }
                    offset += n
                }
            }
        }
    }

    /// Blocking; single-reader. Returns nil on a clean EOF (daemon gone or
    /// stream ended). Throws on a framing violation or socket error.
    public func readFrame() throws -> Frame? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if buffer.count >= 4 {
                let start = buffer.startIndex
                let length = Int(
                    UInt32(buffer[start])
                        | UInt32(buffer[start + 1]) << 8
                        | UInt32(buffer[start + 2]) << 16
                        | UInt32(buffer[start + 3]) << 24
                )
                guard length >= 5, length <= AttachServer.maximumFrameBytes else {
                    throw StreamError.framingViolation
                }
                if buffer.count >= 4 + length {
                    let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
                    buffer.removeSubrange(start..<(start + 4 + length))
                    guard let frame = try? Frame.decode(body) else {
                        throw StreamError.framingViolation
                    }
                    return frame
                }
            }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                throw ControlClient.ClientError.ioFailure(
                    String(cString: strerror(errno))
                )
            }
        }
    }

    /// Half-closes the write side so the daemon observes EOF (detach) while
    /// pending daemon frames can still drain.
    public func finishSending() {
        shutdown(fd, SHUT_WR)
    }

    public func close() {
        stateLock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    deinit {
        close()
    }
}
