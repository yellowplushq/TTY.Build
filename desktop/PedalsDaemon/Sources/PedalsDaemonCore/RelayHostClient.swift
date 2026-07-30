import Foundation
import PedalsKit

/// Host end of the relay: one `control` RelayLink (session list, create/close)
/// plus one `session` RelayLink per listed session (replay + stdout out,
/// stdin/resize in, authoritative resize out). Each link is its own encrypted WebSocket with reconnect
/// (PROTOCOL.md §1); a client `hello` on a session link triggers a fresh
/// `replay` broadcast.
public final class RelayHostClient: @unchecked Sendable {
    public enum State: String, Sendable {
        case stopped
        case connecting
        case connected
    }

    private let queue = DispatchQueue(label: "air.build.pedals.relay")
    private let sessions: SessionManager
    private let hostName: String

    private var identity: HostIdentity
    private var started = false
    private var control: RelayLink?
    private var heartbeatTimer: DispatchSourceTimer?
    private var sessionLinks: [Int: RelayLink] = [:]
    /// Output offset already covered by the last `replay` sent per session;
    /// live stdout at or below it is not re-sent (bytes would double after the
    /// splice, see PROTOCOL.md §4).
    private var replayedThrough: [Int: UInt64] = [:]
    private var lastReportedDirectory: [RelayMetadata.DirectoryEntry]?
    private var lastReportedAgentCounts: RelayMetadata.AgentCounts?
    private var lastReportedActivity: AgentActivity.Content?
    private var lastActivitySentAt = Date.distantPast
    private var pendingActivityReport: DispatchWorkItem?
    /// Latest AgentMonitor snapshot; replayed to late-joining clients right
    /// after the sessions list. Rich agent content is E2EE-only — it travels
    /// exclusively in ctl frames, never in relay metadata; the host snapshot
    /// carries only the per-state counts.
    private var lastAgents: [AgentInfo] = []
    /// Client-requested agent dismissal, forwarded to the AgentMonitor.
    public var onDismissAgent: (@Sendable (String) -> Void)?

    private var _state: State = .stopped
    /// A client hello arrived on the current control connection.
    private var _clientSeen = false

    public var state: State { queue.sync { _state } }
    public var clientConnected: Bool { queue.sync { _clientSeen } }
    public var computerID: String { queue.sync { identity.computer.computerID } }
    public var serviceURL: URL { queue.sync { identity.computer.serviceURL } }

    public init(identity: HostIdentity, sessions: SessionManager) {
        self.identity = identity
        self.sessions = sessions
        self.hostName = Self.sanitizedHostName(
            Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
    }

    private static func sanitizedHostName(_ value: String) -> String {
        let cleaned = value.filter { character in
            !character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = cleaned.isEmpty ? "Mac" : cleaned
        var result = ""
        var utf16Count = 0
        for character in candidate {
            let width = String(character).utf16.count
            guard utf16Count + width <= 128 else { break }
            result.append(character)
            utf16Count += width
        }
        return result.isEmpty ? "Mac" : result
    }

    // MARK: - Lifecycle

    public func start() {
        sessions.onEvent = { [weak self] event in
            self?.enqueue(sessionEvent: event)
        }
        queue.async { [self] in
            guard !started else { return }
            started = true
            connectAllLocked()
        }
    }

    private func enqueue(sessionEvent: SessionEvent) {
        queue.async { [weak self] in
            self?.handle(sessionEvent: sessionEvent)
        }
    }

    public func stop() {
        queue.sync {
            reportOfflineLocked()
            started = false
            teardownLocked()
            _state = .stopped
        }
    }

    /// Sleep keeps every PTY alive locally while withdrawing its remote
    /// directory immediately. `start()` republishes the complete snapshot.
    public func suspend() {
        stop()
    }

    public func resume() {
        start()
    }

    /// Rotates the computer identity, E2EE secret, and host credential.
    public func update(identity: HostIdentity) {
        queue.async { [self] in
            reportOfflineLocked()
            self.identity = identity
            guard started else { return }
            teardownLocked()
            connectAllLocked()
        }
    }

    // MARK: - Links (all on `queue`)

    private func teardownLocked() {
        control?.stop()
        control = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        for link in sessionLinks.values { link.stop() }
        sessionLinks.removeAll()
        replayedThrough.removeAll()
        lastReportedDirectory = nil
        lastReportedAgentCounts = nil
        lastReportedActivity = nil
        pendingActivityReport?.cancel()
        pendingActivityReport = nil
        _clientSeen = false
    }

    private func connectAllLocked() {
        _state = .connecting
        let link = RelayLink(
            computer: identity.computer,
            authorization: identity.hostToken,
            role: .host,
            principalID: identity.computer.computerID,
            channel: .control,
            hostName: hostName, callbackQueue: queue
        )
        link.onState = { [weak self] state in self?.controlStateChanged(state) }
        link.onFrame = { [weak self] frame in self?.handleControl(frame: frame) }
        control = link
        link.start()
        startHeartbeatLocked()
        reconcileSessionLinksLocked(with: sessions.list())
    }

    private func controlStateChanged(_ state: RelayLink.State) {
        switch state {
        case .connected:
            _state = .connected
            reportDirectoryLocked(force: true)
            control?.send(.sessions(list: sessions.list()))
            control?.send(.agents(list: lastAgents))
            if let recent = lastAgents.first {
                sendAgentActivityLocked(recent, alert: false)
            }
        case .connecting:
            _state = .connecting
            _clientSeen = false
        case .idle:
            break
        }
    }

    /// One session link per listed session — dead ones included, so a client
    /// switching to an exited terminal can still replay its final screen.
    private func reconcileSessionLinksLocked(with list: [SessionInfo]) {
        let ids = Set(list.map(\.id))
        for (id, link) in sessionLinks where !ids.contains(id) {
            link.stop()
            sessionLinks.removeValue(forKey: id)
            replayedThrough.removeValue(forKey: id)
        }
        for id in ids where sessionLinks[id] == nil {
            let link = RelayLink(
                computer: identity.computer,
                authorization: identity.hostToken,
                role: .host,
                principalID: identity.computer.computerID,
                channel: .session(sid: UInt32(id)),
                hostName: hostName, callbackQueue: queue
            )
            link.onFrame = { [weak self] frame in
                self?.handleSession(id: id, frame: frame)
            }
            sessionLinks[id] = link
            link.start()
        }
    }

    // MARK: - Control channel (on `queue`)

    private func handleControl(frame: Frame) {
        guard frame.type == .ctl, let message = try? frame.controlMessage() else {
            if frame.type == .ctl { control?.send(.err(msg: "malformed ctl payload")) }
            return
        }
        switch message {
        case .hello(let who, _, _, _, _, _):
            guard who == .client else { return }
            _clientSeen = true
            control?.send(.sessions(list: sessions.list()))
            control?.send(.agents(list: lastAgents))
        case .create(let cwd, let cols, let rows, let req):
            do {
                let id = try sessions.create(cwd: cwd, cols: cols, rows: rows)
                // The `sessions` broadcast is emitted by the SessionManager event.
                control?.send(.created(id: id, req: req))
            } catch {
                // Echo `req` so the requesting client can stop waiting and
                // surface the failure instead of timing out silently.
                control?.send(.err(msg: "create failed: \(error)", req: req))
            }
        case .close(let id):
            if !sessions.close(id: id) {
                control?.send(.err(msg: "no such session \(id)"))
            }
        case .dismissAgent(let agentId):
            onDismissAgent?(agentId)
        case .sessions, .agents, .created, .title, .exit, .ready, .requestReplay:
            break // host→client only; ignore if mirrored back
        case .err(let msg, _):
            FileHandle.standardError.write(Data("client error: \(msg)\n".utf8))
        }
    }

    // MARK: - Session channels (on `queue`)

    private func handleSession(id: Int, frame: Frame) {
        // Defense in depth: per-channel keys already stop cross-channel
        // ciphertext at decrypt, so a mismatched sid on a data frame can only
        // be a bug — drop it rather than write to the wrong PTY.
        if (frame.type == .stdin || frame.type == .resize), frame.sessionId != UInt32(id) {
            return
        }
        switch frame.type {
        case .ctl:
            guard let message = try? frame.controlMessage() else { return }
            let requestsReplay: Bool
            switch message {
            case .hello(let who, _, _, _, _, _):
                requestsReplay = who == .client
            case .requestReplay:
                requestsReplay = true
            default:
                requestsReplay = false
            }
            guard requestsReplay,
                  let link = sessionLinks[id],
                  let snapshot = sessions.replaySnapshot(id: id)
            else { return }
            replayedThrough[id] = max(replayedThrough[id] ?? 0, snapshot.coversUpTo)
            link.send(.resize(
                sessionId: UInt32(id), cols: snapshot.cols, rows: snapshot.rows
            ))
            link.send(.replay(sessionId: UInt32(id), data: snapshot.data))
        case .stdin:
            sessions.write(id: id, data: frame.payload)
        case .resize:
            guard let size = try? frame.resizeSize() else { return }
            sessions.resize(id: id, cols: size.cols, rows: size.rows)
        case .stdout, .replay:
            break // host→client only; ignore if mirrored back
        }
    }

    // MARK: - Agent events

    /// Publishes an AgentMonitor snapshot to every control client and keeps
    /// it for replay on the next client hello / reconnect. Also folds the
    /// per-state aggregate counts into the server-visible host snapshot —
    /// bare numbers only, the rich list stays E2EE.
    public func broadcastAgents(_ list: [AgentInfo]) {
        queue.async { [self] in
            lastAgents = list
            guard started else { return }
            control?.send(.agents(list: list))
            reportDirectoryLocked(force: false)
            scheduleAgentActivityLocked(list.first)
        }
    }

    /// Alerting Live Activity updates replace the retired ordinary-notification
    /// channel. Waiting/error arrive after a short ordering delay so the
    /// debounced host snapshot reaches D1 first; done already has its own
    /// monitor-side hold-back window.
    public func broadcastAgentAttention(_ info: AgentInfo) {
        queue.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.started,
                  let current = self.lastAgents.first(where: { $0.id == info.id }),
                  current.state == info.state
            else { return }
            self.pendingActivityReport?.cancel()
            self.pendingActivityReport = nil
            self.sendAgentActivityLocked(current, alert: true)
        }
    }

    static let doneActivityLifetime: TimeInterval = 75
    static let runningActivityUpdateFloor: TimeInterval = 10

    static func agentCounts(
        of list: [AgentInfo], now: Date = .now
    ) -> RelayMetadata.AgentCounts {
        var running = 0, waiting = 0, done = 0
        for agent in list {
            switch agent.state {
            case .running: running += 1
            // Error parks the agent on the user just like waiting; the
            // server-visible aggregate does not distinguish them.
            case .waiting, .error: waiting += 1
            case .done:
                if now.timeIntervalSince1970 - agent.updatedAt < doneActivityLifetime {
                    done += 1
                }
            }
        }
        let cap = RelayMetadata.AgentCounts.maxCount
        return .init(
            running: min(running, cap),
            waiting: min(waiting, cap),
            done: min(done, cap)
        )
    }

    private func scheduleAgentActivityLocked(_ recent: AgentInfo?) {
        pendingActivityReport?.cancel()
        pendingActivityReport = nil
        guard let recent else {
            lastReportedActivity = nil
            return
        }

        let content = AgentActivity.Content(info: recent)
        guard content != lastReportedActivity else { return }
        let elapsed = Date().timeIntervalSince(lastActivitySentAt)
        if recent.state != .running || lastReportedActivity == nil
            || elapsed >= Self.runningActivityUpdateFloor
        {
            sendAgentActivityLocked(recent, alert: false)
            return
        }

        let delay = Self.runningActivityUpdateFloor - elapsed
        let item = DispatchWorkItem { [weak self] in
            guard let self, let latest = self.lastAgents.first else { return }
            self.pendingActivityReport = nil
            self.sendAgentActivityLocked(latest, alert: false)
        }
        pendingActivityReport = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func sendAgentActivityLocked(_ info: AgentInfo, alert: Bool) {
        let content = AgentActivity.Content(info: info)
        do {
            let key = AgentActivity.activityKey(secret: identity.computer.secret)
            let sealed = try AgentActivity.seal(
                content, key: key, computerID: identity.computer.computerID
            )
            guard sealed.count <= RelayMetadata.AgentActivityEnvelope.maxSealedBytes else {
                return
            }
            control?.sendMetadata(.agentActivity(.init(
                state: info.state,
                updatedAt: max(0, Int64((info.updatedAt * 1_000).rounded())),
                alert: alert,
                sealed: sealed
            )))
            lastReportedActivity = content
            lastActivitySentAt = .now
        } catch {
            // Count state remains authoritative and continues to update even if
            // one rich snapshot cannot be sealed.
        }
    }

    // MARK: - Session events (on `queue`)

    private func handle(sessionEvent event: SessionEvent) {
        guard started else { return }
        switch event {
        case .sessionsChanged(let list):
            let directoryChanged = reportDirectoryLocked(force: false, sessions: list)
            // A terminal-count ContentState is a full replacement. Re-attach
            // the latest encrypted agent card after that projection so a TTY
            // lifecycle change cannot erase it from the island. Cwd/resize
            // list refreshes do not change the server-visible directory and
            // must not generate another activity push.
            if directoryChanged, let recent = lastAgents.first {
                sendAgentActivityLocked(recent, alert: false)
            }
            control?.send(.sessions(list: list))
            reconcileSessionLinksLocked(with: list)
        case .resized(let id, let cols, let rows):
            sessionLinks[id]?.send(.resize(
                sessionId: UInt32(id), cols: cols, rows: rows
            ))
        case .output(let id, let data, let offset):
            guard let link = sessionLinks[id] else { return }
            let covered = replayedThrough[id] ?? 0
            let end = offset + UInt64(data.count)
            guard end > covered else { return } // fully inside the last replay
            let payload = offset >= covered ? data : data.suffix(Int(end - covered))
            link.send(.stdout(sessionId: UInt32(id), data: payload))
        case .title(let id, let title):
            control?.send(.title(id: id, title: title))
        case .exit(let id, let code):
            control?.send(.exit(id: id, code: code))
        }
    }

    // MARK: - Durable Object terminal directory (on `queue`)

    private func startHeartbeatLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.reportDirectoryLocked(force: true)
        }
        timer.resume()
        heartbeatTimer?.cancel()
        heartbeatTimer = timer
    }

    @discardableResult
    private func reportDirectoryLocked(
        force: Bool, sessions list: [SessionInfo]? = nil
    ) -> Bool {
        let directory = (list ?? sessions.list()).map {
            RelayMetadata.DirectoryEntry(id: $0.id, alive: $0.alive)
        }
        let counts = Self.agentCounts(of: lastAgents)
        guard force
            || directory != lastReportedDirectory
            || counts != lastReportedAgentCounts
        else { return false }
        control?.sendMetadata(.hostSnapshot(
            hostName: hostName, sessions: directory, agents: counts
        ))
        lastReportedDirectory = directory
        lastReportedAgentCounts = counts
        return true
    }

    private func reportOfflineLocked() {
        guard started else { return }
        control?.sendMetadataSynchronously(.hostOffline)
        lastReportedDirectory = nil
    }
}
