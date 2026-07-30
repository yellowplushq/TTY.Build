import Darwin
import Foundation
import PedalsKit

/// Event emitted by `SessionManager`. Offsets are cumulative output byte counts
/// so a consumer can splice a replay snapshot and the live stream without
/// duplicating bytes (see `RelayHostClient`).
public enum SessionEvent: Sendable {
    /// The session list changed (create / close / exit / cwd / size).
    /// Titles have their own sampled event and do not rebroadcast the list.
    case sessionsChanged([SessionInfo])
    /// The PTY accepted a new grid size. Emitted before any output produced by
    /// the resulting SIGWINCH, so remote renderers can resize before parsing
    /// the application's redraw.
    case resized(id: Int, cols: UInt16, rows: UInt16)
    /// Raw PTY output. `offset` is the total number of bytes output before this chunk.
    case output(id: Int, data: Data, offset: UInt64)
    case title(id: Int, title: String)
    case exit(id: Int, code: Int)
}

/// Owns all PTY sessions (PROTOCOL.md §6): spawn, ring buffers, titles, teardown.
/// Thread-safe; events are delivered on an internal serial queue.
public final class SessionManager: @unchecked Sendable {
    public enum SessionError: Error, CustomStringConvertible, Equatable {
        case capacityReached(Int)
        case idSpaceExhausted

        public var description: String {
            switch self {
            case .capacityReached(let limit):
                "terminal limit reached (\(limit))"
            case .idSpaceExhausted:
                "terminal ID space exhausted"
            }
        }
    }

    public struct Options: Sendable {
        /// Shell binary. Default: `$SHELL`, fallback `/bin/zsh`.
        public var shell: String
        /// Arguments after the shell path. Default: interactive login shell.
        public var shellArguments: [String]
        public var extraEnvironment: [String: String]
        public var defaultCols: UInt16 = 120
        public var defaultRows: UInt16 = 40
        /// The Durable Object directory is deliberately bounded so a host
        /// cannot amplify an unbounded metadata snapshot to every client.
        public var maximumSessions = 255
        /// First session id to allocate. Session-channel keys are derived from
        /// (secret, sid), so ids must never be reused across daemon restarts
        /// while the pairing persists — pass a persisted high-water mark + 1
        /// (see PROTOCOL.md §3).
        public var firstSessionId = 1
        /// Called (on the manager's queue) with each allocated id, so the
        /// caller can persist the high-water mark.
        public var onIdAllocated: (@Sendable (Int) throws -> Void)?
        /// Sampling floor for volatile terminal metadata. Codex and similar
        /// TUIs animate OSC titles several times per second; only the newest
        /// title in each interval is published.
        public var metadataSampleInterval: TimeInterval = 2

        public init(
            shell: String? = nil,
            shellArguments: [String] = ["-il"],
            extraEnvironment: [String: String] = [:]
        ) {
            let env = ProcessInfo.processInfo.environment["SHELL"]
            self.shell = shell ?? (env?.isEmpty == false ? env! : "/bin/zsh")
            self.shellArguments = shellArguments
            self.extraEnvironment = extraEnvironment
        }
    }

    private final class Session {
        let id: Int
        /// Live working directory: seeded with the spawn cwd, refreshed by the
        /// 2 s poll from the shell process (PROTOCOL.md §4).
        var cwd: String
        let createdAt: Date
        let pty: PTYProcess
        var cols: UInt16
        var rows: UInt16
        var ring = RingBuffer()
        var oscParser = OSCTitleParser()
        var outputOffset: UInt64 = 0
        var title: String
        /// Once an OSC 0/2 title arrives it wins over the process-name fallback.
        var titleFromOSC = false
        /// Latest uncommitted OSC title. Animated spinners overwrite this
        /// value instead of flooding the control channel.
        var pendingOSCTitle: String?
        var alive = true
        var exitCode: Int?

        init(id: Int, cwd: String, pty: PTYProcess, cols: UInt16, rows: UInt16, title: String) {
            self.id = id
            self.cwd = cwd
            self.createdAt = Date()
            self.pty = pty
            self.cols = cols
            self.rows = rows
            self.title = title
        }

        var info: SessionInfo {
            SessionInfo(
                id: id, title: title, cwd: cwd, rows: Int(rows), cols: Int(cols),
                createdAt: createdAt.timeIntervalSince1970, alive: alive
            )
        }
    }

    /// Serial queue on which all state mutation and event delivery happens.
    private let queue = DispatchQueue(label: "air.build.pedals.sessions")
    private let options: Options
    private var sessions: [Int: Session] = [:]
    /// PTYs whose session was closed but whose child hasn't exited yet. Held so
    /// their `exitSource` stays alive to `waitpid` the child (else it lingers as
    /// a zombie); dropped in the exit callback.
    private var reaping: [ObjectIdentifier: PTYProcess] = [:]
    private var nextId: Int
    private var titleTimer: DispatchSourceTimer?

    /// Delivered on the manager's serial queue. Handlers may call back into the
    /// manager (its public API only dispatches async or reads on the same queue).
    public var onEvent: (@Sendable (SessionEvent) -> Void)? {
        get { queue.sync { _onEvent } }
        set { queue.sync { _onEvent = newValue } }
    }
    private var _onEvent: (@Sendable (SessionEvent) -> Void)?

    public init(options: Options = Options()) {
        self.options = options
        nextId = max(options.firstSessionId, 1)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let sampleInterval = max(options.metadataSampleInterval, 0.05)
        timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
        timer.setEventHandler { [weak self] in
            self?.pollLiveCwds()
            self?.pollFallbackTitles()
            self?.flushPendingOSCTitles()
        }
        timer.resume()
        titleTimer = timer
    }

    deinit {
        titleTimer?.cancel()
    }

    // MARK: - Public API

    @discardableResult
    public func create(cwd: String? = nil, cols: Int? = nil, rows: Int? = nil) throws -> Int {
        try queue.sync {
            let limit = min(max(options.maximumSessions, 0), 255)
            guard sessions.count < limit else {
                throw SessionError.capacityReached(limit)
            }
            let cols = UInt16(clamping: cols ?? Int(options.defaultCols))
            let rows = UInt16(clamping: rows ?? Int(options.defaultRows))
            let directory = Self.resolveCwd(cwd)
            let id = nextId
            guard id <= Int(UInt32.max) else {
                throw SessionError.idSpaceExhausted
            }
            // Persist before any PTY exists. A failed spawn burns an id, which
            // is safe; a failed persistence prevents key/sid reuse entirely.
            try options.onIdAllocated?(id)
            nextId += 1
            let pty = try PTYProcess(
                shell: options.shell,
                arguments: options.shellArguments,
                cwd: directory,
                cols: max(cols, 2),
                rows: max(rows, 2),
                extraEnvironment: options.extraEnvironment,
                queue: queue
            )
            let shellName = (options.shell as NSString).lastPathComponent
            let session = Session(
                id: id, cwd: directory, pty: pty, cols: max(cols, 2), rows: max(rows, 2),
                title: "\(shellName) — \(Self.abbreviate(path: directory))"
            )
            sessions[id] = session

            pty.onOutput = { [weak self] data in
                self?.handleOutput(id: id, data: data)
            }
            pty.onExit = { [weak self] code in
                self?.handleExit(id: id, code: code)
            }

            emitSessionsChangedLocked()
            return id
        }
    }

    /// Closes (kills) a session and removes it from the list.
    @discardableResult
    public func close(id: Int) -> Bool {
        queue.sync {
            guard let session = sessions.removeValue(forKey: id) else { return false }
            if session.alive { terminateAndReapLocked(session.pty) }
            emitSessionsChangedLocked()
            return true
        }
    }

    public func write(id: Int, data: Data) {
        queue.async { [self] in
            guard let session = sessions[id], session.alive else { return }
            session.pty.write(data)
        }
    }

    public func resize(id: Int, cols: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard let session = sessions[id], session.alive,
                  cols > 0, rows > 0,
                  session.cols != cols || session.rows != rows
            else { return }
            session.cols = cols
            session.rows = rows
            session.pty.resize(cols: cols, rows: rows)
            self._onEvent?(.resized(id: id, cols: cols, rows: rows))
            emitSessionsChangedLocked()
        }
    }

    public func list() -> [SessionInfo] {
        queue.sync { sessions.values.sorted { $0.id < $1.id }.map(\.info) }
    }

    /// Ring-buffer snapshot + the output offset it covers, for replay-on-attach.
    public func replaySnapshot(
        id: Int
    ) -> (data: Data, coversUpTo: UInt64, cols: UInt16, rows: UInt16)? {
        queue.sync {
            guard let session = sessions[id] else { return nil }
            return (
                session.ring.snapshot(), session.outputOffset,
                session.cols, session.rows
            )
        }
    }

    /// Snapshot for coding-agent ownership matching (AgentMonitor,
    /// docs/AGENT_MONITORING_DESIGN.md §4): the slave tty path and shell pid
    /// of every live session. A hook-reported tty equal to `ttyPath`, or a
    /// hook lineage containing `shellPid`, proves the agent runs inside that
    /// session.
    public struct AgentMatchTarget: Equatable, Sendable {
        public let sessionId: Int
        public let sessionName: String
        public let ttyPath: String?
        public let shellPid: pid_t

        public init(
            sessionId: Int, sessionName: String = "",
            ttyPath: String?, shellPid: pid_t
        ) {
            self.sessionId = sessionId
            self.sessionName = sessionName
            self.ttyPath = ttyPath
            self.shellPid = shellPid
        }
    }

    public func agentMatchTargets() -> [AgentMatchTarget] {
        queue.sync {
            sessions.values
                .filter(\.alive)
                .sorted { $0.id < $1.id }
                .map {
                    AgentMatchTarget(
                        sessionId: $0.id, sessionName: $0.title,
                        ttyPath: $0.pty.ttyPath, shellPid: $0.pty.pid
                    )
                }
        }
    }

    public func closeAll() {
        queue.sync {
            for session in sessions.values where session.alive {
                terminateAndReapLocked(session.pty)
            }
            sessions.removeAll()
            emitSessionsChangedLocked()
        }
    }

    /// SIGHUP the child but keep the PTYProcess alive until its exit fires, so
    /// its `exitSource` runs `waitpid` and the child doesn't become a zombie.
    private func terminateAndReapLocked(_ pty: PTYProcess) {
        let key = ObjectIdentifier(pty)
        reaping[key] = pty
        pty.onExit = { [weak self] _ in
            self?.finishReaping(key: key)
        }
        pty.terminate()
    }

    private func finishReaping(key: ObjectIdentifier) {
        queue.async { [weak self] in
            self?.reaping.removeValue(forKey: key)
        }
    }

    // MARK: - PTY callbacks (on `queue`)

    private func handleOutput(id: Int, data: Data) {
        guard let session = sessions[id] else { return }
        let offset = session.outputOffset
        session.ring.append(data)
        session.outputOffset += UInt64(data.count)
        _onEvent?(.output(id: id, data: data, offset: offset))

        if let title = session.oscParser.consume(data).last {
            session.titleFromOSC = true
            session.pendingOSCTitle = title
        }
    }

    private func handleExit(id: Int, code: Int32) {
        guard let session = sessions[id] else { return }
        session.alive = false
        session.exitCode = Int(code)
        _onEvent?(.exit(id: id, code: Int(code)))
        emitSessionsChangedLocked()
    }

    // MARK: - Live cwd

    private func pollLiveCwds() {
        var changed = false
        for session in sessions.values where session.alive {
            guard let cwd = session.pty.currentWorkingDirectory(),
                  cwd != session.cwd
            else { continue }
            session.cwd = cwd
            changed = true
        }
        if changed { emitSessionsChangedLocked() }
    }

    // MARK: - Titles

    private func flushPendingOSCTitles() {
        for session in sessions.values where session.alive {
            guard let title = session.pendingOSCTitle else { continue }
            session.pendingOSCTitle = nil
            setTitleLocked(session: session, title: title)
        }
    }

    private func pollFallbackTitles() {
        for session in sessions.values where session.alive && !session.titleFromOSC {
            // Title fallback: prefer a foreground process that isn't the shell
            // (the command the user is running), else the shell itself.
            let names = session.pty.foregroundProcessNames()
            let shellName = (options.shell as NSString).lastPathComponent
            guard let name = names.first(where: { $0 != shellName }) ?? names.first
            else { continue }
            setTitleLocked(
                session: session,
                title: "\(name) — \(Self.abbreviate(path: session.cwd))"
            )
        }
    }

    private func setTitleLocked(session: Session, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        session.title = trimmed
        _onEvent?(.title(id: session.id, title: trimmed))
    }

    private func emitSessionsChangedLocked() {
        _onEvent?(.sessionsChanged(sessions.values.sorted { $0.id < $1.id }.map(\.info)))
    }

    // MARK: - Helpers

    private static func resolveCwd(_ cwd: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let cwd, !cwd.isEmpty else { return home }
        let expanded = (cwd as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return home }
        return expanded
    }

    private static func abbreviate(path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
