import Foundation
import TTYBuildKit

/// The desktop service: PTY session manager + relay host connection + optional
/// Unix control socket for the command-line client. The menu bar app owns this
/// object directly; `ttybuild serve` uses the same core for headless operation.
public final class Daemon: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let sessions: [SessionInfo]
        public let clientConnected: Bool
        public let relayState: RelayHostClient.State

        public init(
            sessions: [SessionInfo],
            clientConnected: Bool,
            relayState: RelayHostClient.State
        ) {
            self.sessions = sessions
            self.clientConnected = clientConnected
            self.relayState = relayState
        }
    }

    public struct PairingInvitation: Sendable {
        public let code: PairingCode
        public let expiresAt: Date

        public init(code: PairingCode, expiresAt: Date) {
            self.code = code
            self.expiresAt = expiresAt
        }
    }

    public enum DaemonError: Error, CustomStringConvertible {
        case notRegistered
        case identityResetPending(HostIdentityResetState.Phase)

        public var description: String {
            switch self {
            case .notRegistered:
                """
                no host identity and no service configured — run \
                `ttybuild serve --service https://tty.build` once
                """
            case .identityResetPending(let phase):
                "identity reset is incomplete (\(phase.rawValue)); run `ttybuild pair --reset` to resume"
            }
        }
    }

    public let home: TTYBuildHome
    private let sessions: SessionManager
    private let arbiter = AttachArbiter()
    private let relay: RelayHostClient
    private let agents: AgentMonitor
    private let attach: AttachServer
    private var controlServer: ControlServer?
    /// Held from identity load/registration until the control socket listens.
    /// An offline CLI that lost the initial socket race blocks on this lock,
    /// then observes the newly listening daemon before mutating identity state.
    private var startupIdentityLock: IdentityFileLock?
    private let startedAt = Date()
    /// Serializes identity rotation against status/pair reads.
    private let identityLock = NSLock()
    private var identity: HostIdentity
    private let serviceActions: ServiceActions
    private let pairingLock = NSLock()
    private var pairingSession: HostPairingCode?
    private var pairingTask: Task<Void, Never>?

    /// Loads (or registers) the v2 host identity and wires everything up.
    public init(
        home: TTYBuildHome = TTYBuildHome(),
        sessionOptions: SessionManager.Options = .init(),
        serviceActions: ServiceActions = .live
    ) throws {
        self.home = home
        self.serviceActions = serviceActions
        try home.ensureDirectoryExists()
        let startupIdentityLock = try home.acquireIdentityLock()
        var keepStartupLock = false
        defer {
            if !keepStartupLock { startupIdentityLock.unlock() }
        }

        if let pending = try home.loadIdentityResetState() {
            throw DaemonError.identityResetPending(pending.phase)
        } else if let identity = try home.loadIdentity() {
            self.identity = identity
        } else if let config = home.loadConfig(), let serviceURL = URL(string: config.service) {
            let identity = try registerHostIdentityLocked(
                home: home, serviceURL: serviceURL, actions: serviceActions
            )
            self.identity = identity
        } else {
            throw DaemonError.notRegistered
        }

        var sessionOptions = sessionOptions
        sessionOptions.firstSessionId = (home.loadSessionCounter() ?? 0) + 1
        sessionOptions.onIdAllocated = { [home] id in
            try home.save(sessionCounter: id)
        }
        sessions = SessionManager(options: sessionOptions)
        relay = RelayHostClient(
            identity: identity, sessions: sessions, arbiter: arbiter, home: home
        )
        attach = AttachServer(sessions: sessions, arbiter: arbiter)
        // The monitor re-resolves ownership on its own 2 s sweep, so it needs
        // no session-event subscription (RelayHostClient owns the single
        // SessionManager event consumer).
        agents = AgentMonitor(matchTargets: { [sessions] in
            sessions.agentMatchTargets()
        })
        agents.onChange = { [relay] list in relay.broadcastAgents(list) }
        // Updates capture the startup identity like RelayHostClient does; an
        // identity reset restarts the daemon before either matters.
        agents.onAttention = { [relay] info, _ in
            relay.broadcastAgentAttention(info)
        }
        relay.onDismissAgent = { [agents] id in agents.dismiss(id: id) }
        self.startupIdentityLock = startupIdentityLock
        keepStartupLock = true
    }

    public var hostIdentity: HostIdentity {
        identityLock.lock()
        defer { identityLock.unlock() }
        return identity
    }

    /// Wires the host app's updater into client-triggered `update-status` /
    /// `update-install` ctl requests (PROTOCOL.md §5). The menu bar app calls
    /// this once after start; a headless daemon never does, and its clients
    /// then receive an explanatory error for update requests.
    public func setUpdateHandlers(
        status: RemoteManagement.UpdateHandler?,
        install: RemoteManagement.UpdateHandler?
    ) {
        relay.setUpdateHandlers(status: status, install: install)
    }

    public func start() throws {
        defer {
            startupIdentityLock?.unlock()
            startupIdentityLock = nil
        }
        controlServer = try ControlServer(path: home.socketPath) { [weak self] request in
            self?.handle(request) ?? .error("daemon shutting down")
        }
        relay.start()
    }

    public func shutdown() {
        cancelCurrentPairingSession(revoke: true)
        startupIdentityLock?.unlock()
        startupIdentityLock = nil
        controlServer?.stop()
        controlServer = nil
        relay.stop()
        sessions.closeAll()
    }

    /// Withdraw remote visibility before system sleep without touching PTYs.
    public func suspend() {
        relay.suspend()
    }

    /// Reconnect after wake and republish the complete terminal directory.
    public func resume() {
        relay.resume()
    }

    // MARK: - In-process app API

    public func snapshot() -> Snapshot {
        Snapshot(
            sessions: sessions.list(),
            clientConnected: relay.clientConnected,
            relayState: relay.state
        )
    }

    @discardableResult
    public func createSession() throws -> Int {
        try sessions.create()
    }

    @discardableResult
    public func closeSession(id: Int) -> Bool {
        sessions.close(id: id)
    }

    public func createPairingInvitation() throws -> PairingInvitation {
        let pairing = try createPairingSession(rotatingIdentity: false)
        return PairingInvitation(
            code: pairing.code,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(pairing.expiresAt))
        )
    }

    public func cancelPairingInvitation() {
        cancelCurrentPairingSession(revoke: true)
    }

    /// Claims a phone-issued enrollment token and submits this computer's
    /// sealed E2EE secret. Fire-and-forget: the binding edge only appears
    /// after the user confirms on the phone, which this computer never
    /// observes, so there is no session or state to retain here.
    public func claimReversePairing(code: PairingCode, computerName: String) throws {
        try serviceActions.claimReversePairing(code, computerName, hostIdentity)
    }

    deinit {
        startupIdentityLock?.unlock()
    }

    // MARK: - Control commands (PROTOCOL.md §5)

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "ls":
            return .ok([
                "sessions": .array(sessions.list().map(Self.encode(session:))),
                "client": .string(relay.clientConnected ? "connected" : "none"),
                "service": .string(relay.serviceURL.absoluteString),
            ])

        case "new":
            do {
                let id = try sessions.create()
                return .ok(["id": .int(id)])
            } catch {
                return .error("create failed: \(error)")
            }

        case "kill":
            guard let id = request.id else { return .error("kill requires \"id\"") }
            guard sessions.close(id: id) else { return .error("no such session \(id)") }
            return .ok([:])

        case "pair":
            do {
                let pairing = try createPairingSession(rotatingIdentity: request.reset == true)
                return .ok([
                    "code": .string(pairing.code.digits),
                    "expiresAt": .double(Double(pairing.expiresAt)),
                ])
            } catch {
                return .error("pair failed: \(error)")
            }

        case "cancelPair":
            cancelCurrentPairingSession(revoke: true)
            return .ok([:])

        case "agent-event":
            guard let agent = request.agent, let event = request.event,
                  let agentSessionId = request.agentSessionId
            else {
                return .error("agent-event requires \"agent\", \"event\", \"agentSessionId\"")
            }
            agents.ingest(AgentEvent(
                agent: agent, event: event, agentSessionId: agentSessionId,
                sessionName: request.sessionName, cwd: request.cwd,
                prompt: request.prompt, message: request.message,
                action: request.action, transcriptPath: request.transcriptPath,
                agentError: request.agentError,
                notifyKind: request.notifyKind,
                seq: request.seq, agentPid: request.agentPid,
                lineage: request.lineage ?? []
            ))
            return .ok([:])

        case "agents":
            return .ok([
                "agents": .array(agents.list().map(Self.encode(agent:)))
            ])

        case "attach":
            return attach.response(for: request)

        case "status":
            let state = relay.state
            return .ok([
                "service": .string(relay.serviceURL.absoluteString),
                "state": .string(state == .connected ? "connected" : "connecting"),
                "connected": .bool(state == .connected),
                "client": .string(relay.clientConnected ? "connected" : "none"),
                "computer": .string(relay.computerID),
                "uptime": .double(Date().timeIntervalSince(startedAt).rounded()),
            ])

        default:
            return .error("unknown cmd \"\(request.cmd)\"")
        }
    }

    private func createPairingSession(rotatingIdentity reset: Bool) throws -> HostPairingCode {
        cancelCurrentPairingSession(revoke: true)
        identityLock.lock()
        defer { identityLock.unlock() }
        if reset {
            let pending = try home.loadIdentityResetState()
            let serviceURL = pending?.replacementServiceURL
                ?? home.loadConfig().flatMap { URL(string: $0.service) }
                ?? identity.computer.serviceURL
            let previous = pending?.previous ?? identity
            let fresh = try resetHostIdentity(
                home: home,
                previous: previous,
                replacementServiceURL: serviceURL,
                actions: serviceActions,
                onRevoked: { [relay = self.relay] in relay.stop() }
            )
            identity = fresh
            relay.update(identity: fresh)
            relay.start()
        } else if let pending = try home.loadIdentityResetState() {
            throw HostIdentityResetError.resetPending(pending.phase)
        }

        let pairing = try serviceActions.createPairingCode(identity)
        pairingLock.withLock { pairingSession = pairing }
        startPairingMonitor(pairing: pairing, identity: identity)
        return pairing
    }

    private func startPairingMonitor(pairing: HostPairingCode, identity: HostIdentity) {
        let actions = serviceActions
        let task = Task.detached { [weak self] in
            while !Task.isCancelled,
                  Int64(Date().timeIntervalSince1970) < pairing.expiresAt
            {
                do {
                    switch try actions.pairingCodeStatus(pairing, identity) {
                    case .waiting:
                        try await Task.sleep(for: .milliseconds(400))
                    case .claimed(let claimID, let clientPublicKey):
                        try actions.completePairingClaim(
                            claimID, clientPublicKey, pairing.privateKey, identity
                        )
                        return
                    case .completed:
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            self?.pairingLock.withLock {
                if self?.pairingSession?.codeID == pairing.codeID {
                    self?.pairingSession = nil
                    self?.pairingTask = nil
                }
            }
        }
        pairingLock.withLock { pairingTask = task }
    }

    private func cancelCurrentPairingSession(revoke: Bool) {
        let current: HostPairingCode? = pairingLock.withLock {
            pairingTask?.cancel()
            pairingTask = nil
            guard let pairingSession else { return nil }
            self.pairingSession = nil
            return pairingSession
        }
        if revoke, let current {
            try? serviceActions.cancelPairingCode(current, hostIdentity)
        }
    }

    private static func encode(agent info: AgentInfo) -> ControlValue {
        var fields: [String: ControlValue] = [
            "id": .string(info.id),
            "agent": .string(info.agent),
            "state": .string(info.state.rawValue),
            "cwd": .string(info.cwd),
            "updatedAt": .double(info.updatedAt),
        ]
        if let action = info.action { fields["action"] = .string(action) }
        if let message = info.message { fields["message"] = .string(message) }
        if let prompt = info.prompt { fields["prompt"] = .string(prompt) }
        if let sessionName = info.sessionName { fields["sessionName"] = .string(sessionName) }
        if let sessionId = info.sessionId { fields["sessionId"] = .int(sessionId) }
        if let term = info.term { fields["term"] = .string(term) }
        return .object(fields)
    }

    private static func encode(session: SessionInfo) -> ControlValue {
        .object([
            "id": .int(session.id),
            "title": .string(session.title),
            "cwd": .string(session.cwd),
            "rows": .int(session.rows),
            "cols": .int(session.cols),
            "createdAt": .double(session.createdAt),
            "alive": .bool(session.alive),
        ])
    }
}

/// Product-facing name used by the menu bar app. `Daemon` remains the concrete
/// type name for source compatibility with the headless CLI and existing tests.
public typealias TTYBuildService = Daemon
