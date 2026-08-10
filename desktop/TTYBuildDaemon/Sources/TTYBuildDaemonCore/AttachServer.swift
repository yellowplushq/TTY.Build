import Darwin
import Foundation
import TTYBuildHookKit
import TTYBuildKit

/// Serves upgraded `attach` connections on the daemon's control socket
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §4): after the NDJSON ok reply, the
/// connection becomes a length-prefixed plaintext Frame stream (`u32 LE
/// length || frame`) carrying stdin/stdout/resize/replay plus ctl for
/// claim/takeover/exit — the same vocabulary and resize-before-replay
/// ordering as the relay path, without E2EE (same-user 0600 socket).
public final class AttachServer: @unchecked Sendable {
    /// Matches the relay's peer-frame limit; a longer length prefix on this
    /// trusted-but-possibly-buggy local stream drops the connection.
    static let maximumFrameBytes = 1 << 20
    /// Queued-write ceiling. A local reader this far behind is wedged; drop
    /// the connection rather than buffer PTY output without bound.
    static let maximumPendingWriteBytes = 8 << 20

    private let sessions: SessionManager
    private let arbiter: AttachArbiter
    private let connectionCounter = ManagedAtomic()

    public init(sessions: SessionManager, arbiter: AttachArbiter) {
        self.sessions = sessions
        self.arbiter = arbiter
    }

    /// Builds the control response for an `attach` request: resolves (or
    /// creates) the session and hands back the upgrade closure that runs the
    /// streaming connection on the control connection's thread.
    public func response(for request: ControlRequest) -> ControlResponse {
        let sessionId: Int
        if request.new == true {
            do {
                sessionId = try sessions.create(
                    cwd: request.cwd, cols: request.cols, rows: request.rows
                )
            } catch {
                return .error("create failed: \(error)")
            }
        } else if let id = request.id {
            sessionId = id
        } else {
            return .error("attach requires \"id\" or \"new\":true")
        }
        guard let info = sessions.list().first(where: { $0.id == sessionId }) else {
            return .error("no such session \(sessionId)")
        }
        // Allocated pre-upgrade so the handshake can carry the connection's
        // identity; the client compares it against `takeover` principals
        // ("attach:<conn>") to tell its own hold from another terminal's.
        let connectionID = connectionCounter.next()
        return .upgrade(
            fields: [
                "id": .int(sessionId),
                "title": .string(info.title),
                "alive": .bool(info.alive),
                "conn": .int(Int(connectionID)),
            ],
            serve: { [self] fd in
                run(fd: fd, sessionId: sessionId, connectionID: connectionID)
            }
        )
    }

    // MARK: - Connection

    private func run(fd: Int32, sessionId: Int, connectionID: UInt64) {
        let connection = Connection(
            fd: fd, sessionId: sessionId,
            connectionID: connectionID,
            sessions: sessions, arbiter: arbiter
        )
        connection.run() // blocks until the stream ends
    }

    /// Plain atomic counter (avoids importing swift-atomics for one field).
    private final class ManagedAtomic: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 {
            lock.withLock {
                value += 1
                return value
            }
        }
    }
}

/// One upgraded attach connection. Reads frames on the owning control-server
/// thread; all writes and replay bookkeeping serialize on `writeQueue` so a
/// replay snapshot and the live output splice can never interleave.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let sessionId: Int
    private let source: AttachArbiter.Source
    private let sessions: SessionManager
    private let arbiter: AttachArbiter
    private let terminalName: String

    private let writeQueue = DispatchQueue(label: "air.build.pedals.attach.write")
    private let stateLock = NSLock()
    private var closed = false
    private var pendingWriteBytes = 0
    /// Output offset covered by the last replay sent; live stdout at or below
    /// it is trimmed (PROTOCOL.md §4 splice). Touched only on `writeQueue`.
    private var replayedThrough: UInt64 = 0

    init(
        fd: Int32, sessionId: Int, connectionID: UInt64,
        sessions: SessionManager, arbiter: AttachArbiter
    ) {
        self.fd = fd
        self.sessionId = sessionId
        self.source = .attach(connectionID: connectionID)
        self.sessions = sessions
        self.arbiter = arbiter
        self.terminalName = Self.terminalName(peerOf: fd)
    }

    func run() {
        let arbiterToken = arbiter.addObserver { [weak self] id, holder in
            guard let self, id == self.sessionId else { return }
            self.send(frame: try? Frame.control(.takeover(id: id, holder: holder)))
        }
        let eventToken = sessions.addEventObserver { [weak self] event in
            self?.handle(sessionEvent: event)
        }
        defer {
            sessions.removeEventObserver(eventToken)
            arbiter.removeObserver(arbiterToken)
            if case let .attach(connectionID) = source {
                arbiter.releaseAll(attachConnectionID: connectionID)
            }
            // The control server closes the fd when this returns, and the
            // number may be reused immediately. Stop new writes and drain the
            // in-flight one so no job can touch a recycled descriptor.
            stateLock.withLock { closed = true }
            writeQueue.sync {}
        }

        // Attaching claims (the takeover answer arrives via the observer
        // registered above), then replays: size first, then the snapshot.
        arbiter.claim(sessionId: sessionId, source: source, name: terminalName)
        sendReplay()

        readLoop()
    }

    // MARK: - Client-to-daemon (control-server thread)

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !isClosed {
            while let frame = Self.dequeueFrame(from: &buffer) {
                guard let frame else { return } // malformed/oversized stream
                handle(frame: frame)
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return } // EOF or error: detach
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Double-optional: `.some(nil)` means a framing violation (caller must
    /// drop the connection), `nil` means "need more bytes".
    private static func dequeueFrame(from buffer: inout Data) -> Frame?? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer.uint32LE(at: start))
        guard length >= 5, length <= AttachServer.maximumFrameBytes else {
            return .some(nil)
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
        buffer.removeSubrange(start..<(start + 4 + length))
        guard let frame = try? Frame.decode(body) else { return .some(nil) }
        return frame
    }

    private func handle(frame: Frame) {
        switch frame.type {
        case .stdin:
            guard frame.sessionId == UInt32(sessionId),
                  arbiter.isHolder(sessionId: sessionId, source: source)
            else { return }
            sessions.write(id: sessionId, data: frame.payload)
        case .resize:
            guard frame.sessionId == UInt32(sessionId),
                  arbiter.isHolder(sessionId: sessionId, source: source),
                  let size = try? frame.resizeSize()
            else { return }
            sessions.resize(id: sessionId, cols: size.cols, rows: size.rows)
        case .ctl:
            guard let message = try? frame.controlMessage() else { return }
            switch message {
            case .claim(let id, _):
                guard id == sessionId else { return }
                arbiter.claim(sessionId: sessionId, source: source, name: terminalName)
                sendReplay()
            case .requestReplay:
                sendReplay()
            default:
                break
            }
        case .stdout, .replay:
            break // daemon-to-client only
        }
    }

    // MARK: - Daemon-to-client (session queue → writeQueue)

    private func handle(sessionEvent event: SessionEvent) {
        switch event {
        case .output(let id, let data, let offset):
            guard id == sessionId else { return }
            writeOnQueue(estimatedBytes: data.count) { [self] in
                let end = offset + UInt64(data.count)
                guard end > replayedThrough else { return }
                let payload = offset >= replayedThrough
                    ? data : data.suffix(Int(end - replayedThrough))
                writeNow(frame: Frame.stdout(
                    sessionId: UInt32(sessionId), data: payload
                ))
            }
        case .resized(let id, let cols, let rows):
            guard id == sessionId else { return }
            send(frame: Frame.resize(
                sessionId: UInt32(id), cols: cols, rows: rows
            ))
        case .exit(let id, let code):
            guard id == sessionId else { return }
            send(frame: try? Frame.control(.exit(id: id, code: code)))
        case .title(let id, let title):
            guard id == sessionId else { return }
            send(frame: try? Frame.control(.title(id: id, title: title)))
        case .sessionsChanged(let list):
            guard !list.contains(where: { $0.id == sessionId }) else { return }
            // The session was closed (killed): end the attach stream. The
            // shutdown rides the serial write queue so it cannot overtake
            // the closure notice.
            send(frame: try? Frame.control(.err(msg: "session closed")))
            writeOnQueue(estimatedBytes: 16) { [self] in shutdownConnection() }
        }
    }

    /// Size first, then the ring snapshot, with splice bookkeeping — all on
    /// `writeQueue` so a concurrent live-output event cannot interleave
    /// between the coverage update and the replay bytes.
    private func sendReplay() {
        writeOnQueue(estimatedBytes: RingBuffer.sessionCapacity) { [self] in
            guard let snapshot = sessions.replaySnapshot(id: sessionId) else { return }
            replayedThrough = max(replayedThrough, snapshot.coversUpTo)
            writeNow(frame: Frame.resize(
                sessionId: UInt32(sessionId),
                cols: snapshot.cols, rows: snapshot.rows
            ))
            writeNow(frame: Frame.replay(
                sessionId: UInt32(sessionId), data: snapshot.data
            ))
        }
    }

    // MARK: - Write plumbing

    private var isClosed: Bool {
        stateLock.withLock { closed }
    }

    private func shutdownConnection() {
        stateLock.withLock {
            guard !closed else { return }
            closed = true
            // Wakes the blocked read loop; the control server closes the fd.
            shutdown(fd, SHUT_RDWR)
        }
    }

    private func send(frame: Frame?) {
        guard let frame else { return }
        writeOnQueue(estimatedBytes: frame.payload.count + 16) { [self] in
            writeNow(frame: frame)
        }
    }

    private func writeOnQueue(
        estimatedBytes: Int, _ work: @escaping @Sendable () -> Void
    ) {
        let cost = max(estimatedBytes, 16)
        let overloaded: Bool = stateLock.withLock {
            guard !closed else { return true }
            pendingWriteBytes += cost
            return pendingWriteBytes > AttachServer.maximumPendingWriteBytes
        }
        guard !overloaded else {
            shutdownConnection()
            return
        }
        writeQueue.async { [self] in
            work()
            stateLock.withLock { pendingWriteBytes -= cost }
        }
    }

    /// Runs on `writeQueue` only.
    private func writeNow(frame: Frame) {
        guard !isClosed else { return }
        let body = frame.encoded()
        let length = UInt32(body.count).littleEndian
        var wire = withUnsafeBytes(of: length) { Data($0) }
        wire.append(body)
        let ok = wire.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        if !ok { shutdownConnection() }
    }

    // MARK: - Peer terminal identification

    /// Resolves the attaching process's terminal app for the phone-side
    /// placeholder ("In use in iTerm2"), via the socket peer pid's ancestor
    /// walk. Best-effort; falls back to "Terminal".
    private static func terminalName(peerOf fd: Int32) -> String {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0
        else { return "Terminal" }
        for entry in ProcessLineage.walk(from: pid) {
            if let display = AgentMonitor.terminalDisplayName(processName: entry.name) {
                return display
            }
        }
        return "Terminal"
    }
}

extension Data {
    /// `index` is an absolute Data index; caller guarantees bounds.
    fileprivate func uint32LE(at index: Index) -> UInt32 {
        UInt32(self[index])
            | UInt32(self[index + 1]) << 8
            | UInt32(self[index + 2]) << 16
            | UInt32(self[index + 3]) << 24
    }
}
