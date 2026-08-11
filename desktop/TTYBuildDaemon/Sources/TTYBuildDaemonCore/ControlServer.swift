import Darwin
import Foundation

/// Newline-delimited JSON request on the daemon's unix control socket
/// (PROTOCOL.md §7): `{"cmd":"ls"|"kill"|"pair"|"cancelPair"|"status"|"new"|
/// "agent-event"|"agents"|"attach", "id":N?}`. `reset` extends `pair` for
/// `ttybuild pair --reset`; the `agent`… fields extend `agent-event` for the
/// ttybuild-hook reporter; `new`/`cwd`/`cols`/`rows` extend `attach` for
/// create-and-attach (docs/EXCLUSIVE_ATTACH_DESIGN.md §4).
public struct ControlRequest: Decodable, Sendable {
    public var cmd: String
    public var id: Int?
    public var reset: Bool?
    // attach
    public var new: Bool?
    public var cols: Int?
    public var rows: Int?
    /// Hook reporters are one-way. Avoid writing an acknowledgement after
    /// their bounded client has already closed the socket.
    public var noReply: Bool?
    // agent-event (AgentMonitor)
    public var agent: String?
    public var event: String?
    public var agentSessionId: String?
    public var sessionName: String?
    public var cwd: String?
    public var prompt: String?
    public var message: String?
    public var action: String?
    public var transcriptPath: String?
    public var agentError: Bool?
    public var lineage: [AgentLineageEntry]?
}

/// Minimal JSON value for building `{"ok":true, ...}` responses without a
/// schema per command.
public enum ControlValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ControlValue])
    case object([String: ControlValue])

    var jsonObject: Any {
        switch self {
        case .string(let v): v
        case .int(let v): v
        case .double(let v): v
        case .bool(let v): v
        case .array(let v): v.map(\.jsonObject)
        case .object(let v): v.mapValues(\.jsonObject)
        }
    }
}

public enum ControlResponse: Sendable {
    case ok([String: ControlValue])
    case error(String)
    /// Reply with the ok form of `fields`, then hand the connection over to
    /// `serve`, which runs on the connection's thread until the streaming
    /// session ends (EXCLUSIVE_ATTACH_DESIGN.md §4). The server stops parsing
    /// NDJSON on the fd and closes it when `serve` returns.
    case upgrade(fields: [String: ControlValue], serve: @Sendable (Int32) -> Void)

    func encoded() -> Data {
        var object: [String: Any]
        switch self {
        case .ok(let fields), .upgrade(let fields, _):
            object = fields.mapValues(\.jsonObject)
            object["ok"] = true
        case .error(let message):
            object = ["ok": false, "err": message]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"err":"encoding failure","ok":false}"#.utf8)
        data.append(0x0A)
        return data
    }
}

/// Unix-domain stream socket server for `~/.tty.build/ttybuild.sock`. Plain BSD
/// sockets: an accept thread plus one short-lived thread per connection
/// (connections are one-shot CLI/menubar requests).
public final class ControlServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case socketFailed(String)
        /// A live daemon already answers on the socket: one TTY.Build per
        /// computer (the menu bar app or `ttybuild serve`, never both).
        case socketBusy

        public var description: String {
            switch self {
            case .socketFailed(let detail): "control socket: \(detail)"
            case .socketBusy:
                "another TTY.Build daemon is already running on this computer"
            }
        }
    }

    private let path: String
    private let handler: @Sendable (ControlRequest) -> ControlResponse
    private let listenFD: Int32
    private let stateLock = NSLock()
    private var stopped = false

    public init(
        path: String,
        handler: @escaping @Sendable (ControlRequest) -> ControlResponse
    ) throws {
        self.path = path
        self.handler = handler

        // A previous daemon instance may have left the socket file behind —
        // but a *live* daemon answering on it means another TTY.Build owns
        // this computer (the app or `ttybuild serve`). Refuse instead of
        // silently stealing its socket while both keep fighting over the
        // relay host identity (single-daemon rule).
        if FileManager.default.fileExists(atPath: path) {
            if let reply = try? ControlClient.roundTrip(
                socketPath: path, request: ["cmd": "status"]
            ), reply["ok"] as? Bool == true {
                throw ServerError.socketBusy
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.socketFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ServerError.socketFailed("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw ServerError.socketFailed(detail)
        }
        chmod(path, 0o600)

        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "ttybuild-control-accept"
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else { return }
        stopped = true
        close(listenFD)
        unlink(path)
    }

    deinit {
        stop()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if isStopped || (errno != EINTR && errno != ECONNABORTED) { return }
                continue
            }
            let thread = Thread { [weak self] in
                self?.serve(fd: fd)
                close(fd)
            }
            thread.name = "ttybuild-control-conn"
            thread.start()
        }
    }

    /// Reads newline-delimited requests until EOF, answering each in order.
    private func serve(fd: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                    let response = handler(request)
                    if case let .upgrade(_, serve) = response {
                        guard writeAll(fd: fd, data: response.encoded()) else { return }
                        // Streaming mode: no NDJSON timeouts; the handler owns
                        // the fd until it returns (then the thread closes it).
                        var off = timeval(tv_sec: 0, tv_usec: 0)
                        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &off,
                                   socklen_t(MemoryLayout<timeval>.size))
                        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &off,
                                   socklen_t(MemoryLayout<timeval>.size))
                        serve(fd)
                        return
                    }
                    if request.noReply == true { continue }
                    guard writeAll(fd: fd, data: response.encoded()) else { return }
                } else {
                    guard writeAll(
                        fd: fd,
                        data: ControlResponse.error("malformed request").encoded()
                    ) else { return }
                }
            }
            if buffer.count > 1 << 20 { return } // oversized garbage; drop connection
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}
