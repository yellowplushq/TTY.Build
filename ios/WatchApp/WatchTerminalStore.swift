import Foundation
import Observation
import PedalsKit

struct WatchTerminalID: Hashable, Sendable {
    let computerID: String
    let sessionID: Int
}

struct WatchTerminalDescriptor: Identifiable, Hashable, Sendable {
    let id: WatchTerminalID
    var computerName: String
    var title: String
    var cols: Int
    var rows: Int
    var alive: Bool
    /// State/kind of the agent running inside this terminal, nil when none
    /// does (the row morph of the ownership/dedup rule, scaled to the Watch).
    var agentState: AgentState?
    var agentSlug: String?
    /// Latest assistant message or current action for the managed agent.
    var agentDetail: String?
}

struct WatchTerminalComputer: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var online: Bool
    /// False until this connection has received enough relay state to make
    /// `terminals` authoritative: the directory, plus the host's session list
    /// whenever the directory says the host is online. Before that an empty
    /// list means "still connecting", not "no terminals".
    var ready: Bool
    var terminals: [WatchTerminalDescriptor]
    /// Agents not matched to a visible terminal (the standalone Agents
    /// section). Managed agents render inside their terminal row instead —
    /// an agent never appears in both places.
    var agents: [AgentInfo]
}

@MainActor
@Observable
final class WatchTerminalStore {
    static let shared = WatchTerminalStore()

    private(set) var computers: [WatchTerminalComputer] = []
    private(set) var hasCredentials = false
    /// Changes only when terminal membership or an alive flag changes. Titles,
    /// host names, and TTY dimensions deliberately do not affect this value,
    /// so an ordinary redraw/resize never dismisses an open terminal.
    private(set) var terminalListRevision: UInt64 = 0

    @ObservationIgnored private var context: WatchTerminalContext?
    @ObservationIgnored private var connections: [String: WatchTerminalComputerConnection] = [:]
    @ObservationIgnored private var terminalSessions: [WatchTerminalID: WatchTerminalSession] = [:]
    @ObservationIgnored private var started = false
    /// Highest update revision applied so far; stale WatchConnectivity
    /// deliveries (durable applicationContext racing a fresher reply) must not
    /// regress or wipe the installed credential.
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var lastCredentialRefreshRequest: Date?

    private init() {
        if let stored = WatchTerminalCredentialStore.load() {
            revision = stored.revision
            replaceContext(stored, persist: false)
        }
    }

    func install(_ update: WatchTerminalContextUpdate) {
        guard update.revision >= revision else { return }
        revision = update.revision
        replaceContext(update.context, persist: true)
    }

    func start() {
        guard !started else { return }
        started = true
        for connection in connections.values { connection.start() }
        #if DEBUG
        // The layout fixture has no connections to trigger a publish.
        if Self.fixtureComputers != nil { publishComputers() }
        #endif
    }

    func stop() {
        guard started else { return }
        started = false
        for connection in connections.values { connection.stop() }
        for session in terminalSessions.values { session.stop() }
    }

    func retryConnections() {
        guard started else {
            start()
            return
        }
        for connection in connections.values { connection.start() }
    }

    func descriptor(for id: WatchTerminalID) -> WatchTerminalDescriptor? {
        computers.lazy.flatMap(\.terminals).first { $0.id == id }
    }

    /// Optimistic dismissal, mirroring the iPhone Home list: the row hides
    /// immediately, the daemon drops the record for every client, and the
    /// agent's next hook event recreates it.
    func dismissAgent(computerID: String, agentID: String) {
        connections[computerID]?.dismissAgent(id: agentID)
        publishComputers()
    }

    func session(for descriptor: WatchTerminalDescriptor) -> WatchTerminalSession? {
        if let existing = terminalSessions[descriptor.id] {
            existing.update(descriptor: descriptor)
            return existing
        }
        guard let context,
              let binding = context.bindings.first(where: {
                  $0.computerID == descriptor.id.computerID
              })
        else { return nil }

        let session = WatchTerminalSession(
            descriptor: descriptor,
            binding: binding,
            identity: context.identity
        )
        terminalSessions[descriptor.id] = session
        return session
    }

    private func replaceContext(_ context: WatchTerminalContext?, persist: Bool) {
        guard context != self.context else { return }

        // The phone stamps a fresh timestamp revision on every send, so
        // deliveries differ even when the credential payload is unchanged.
        // Tearing down live connections (and dismissing an open terminal)
        // over a revision-only change would reset the UI on every wake;
        // just record the newer revision instead.
        if let context, let current = self.context,
           context.identity == current.identity,
           context.bindings == current.bindings {
            self.context = context
            if persist {
                WatchTerminalCredentialStore.save(context)
            }
            return
        }

        for connection in connections.values { connection.stop() }
        for session in terminalSessions.values { session.stop() }
        connections.removeAll()
        terminalSessions.removeAll()
        self.context = context
        hasCredentials = context != nil

        if persist {
            WatchTerminalCredentialStore.save(context)
        }

        if let context {
            for binding in context.bindings {
                let connection = WatchTerminalComputerConnection(
                    binding: binding,
                    identity: context.identity
                )
                connection.onChange = { [weak self] in
                    self?.publishComputers()
                }
                connection.onUnauthorized = { [weak self] in
                    self?.requestCredentialRefresh()
                }
                connections[binding.computerID] = connection
                if started { connection.start() }
            }
        }
        publishComputers()
    }

    /// The relay rejected our bearer: the phone has re-provisioned or revoked
    /// this delegate. Ask the phone for the current context (throttled — every
    /// affected connection reports the same rejection on every retry).
    private func requestCredentialRefresh() {
        let now = Date()
        if let last = lastCredentialRefreshRequest,
           now.timeIntervalSince(last) < 30 { return }
        lastCredentialRefreshRequest = now
        WatchStatusBridge.shared.requestCurrentContext()
    }

    #if DEBUG
    /// Dev-only layout fixture (`PEDALS_WATCH_HOME_FIXTURE=1`): a realistic
    /// two-section status list without needing a paired phone.
    private static let fixtureComputers: [WatchTerminalComputer]? = {
        guard ProcessInfo.processInfo.environment["PEDALS_WATCH_HOME_FIXTURE"] == "1"
        else { return nil }
        let now = Date().timeIntervalSince1970
        func agent(
            _ slug: String, _ state: AgentState, sessionName: String,
            cwd: String, age: Double,
            prompt: String? = nil, message: String? = nil, action: String? = nil
        ) -> AgentInfo {
            AgentInfo(
                id: "fx-\(slug)", agent: slug, state: state,
                sessionName: sessionName, cwd: cwd,
                action: action, message: message, prompt: prompt,
                updatedAt: now - age
            )
        }
        return [
            WatchTerminalComputer(
                id: "fixture", name: "Studio", online: true, ready: true,
                terminals: [
                    WatchTerminalDescriptor(
                        id: WatchTerminalID(computerID: "fixture", sessionID: 1),
                        computerName: "Studio", title: "Polish agent monitoring",
                        cols: 80, rows: 24, alive: true,
                        agentState: .waiting, agentSlug: "claude",
                        agentDetail: "Choose how to continue"
                    ),
                    WatchTerminalDescriptor(
                        id: WatchTerminalID(computerID: "fixture", sessionID: 2),
                        computerName: "Studio", title: "zsh — ~",
                        cols: 80, rows: 24, alive: true,
                        agentState: nil, agentSlug: nil, agentDetail: nil
                    ),
                ],
                agents: [
                    agent(
                        "codex", .running, sessionName: "Website release",
                        cwd: "/Users/eyhn/Projects/website",
                        age: 300, action: "Bash: npm run build"
                    ),
                    agent(
                        "kiro", .done, sessionName: "Landing page",
                        cwd: "/Users/eyhn/Projects/blog",
                        age: 3600, message: "Deployed the new landing page."
                    ),
                    agent(
                        "grok", .error, sessionName: "Model experiments",
                        cwd: "/Users/eyhn/Projects/experiments",
                        age: 10800, message: "API rate limit exceeded"
                    ),
                ]
            ),
        ]
    }()
    #endif

    private func publishComputers() {
        let previousListState = Self.listState(computers)
        var updatedComputers = connections.values
            .map(\.snapshot)
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        #if DEBUG
        if let fixture = Self.fixtureComputers {
            updatedComputers = fixture
            hasCredentials = true
        }
        #endif
        computers = updatedComputers

        if Self.listState(updatedComputers) != previousListState {
            terminalListRevision &+= 1
        }

        for descriptor in computers.lazy.flatMap(\.terminals) {
            terminalSessions[descriptor.id]?.update(descriptor: descriptor)
        }

        let liveTerminalIDs = Set(
            computers.lazy.flatMap(\.terminals).filter(\.alive).map(\.id)
        )
        let staleSessionIDs = terminalSessions.keys.filter {
            !liveTerminalIDs.contains($0)
        }
        for id in staleSessionIDs {
            terminalSessions.removeValue(forKey: id)?.stop()
        }
    }

    private static func listState(
        _ computers: [WatchTerminalComputer]
    ) -> [WatchTerminalID: Bool] {
        Dictionary(uniqueKeysWithValues: computers.lazy.flatMap(\.terminals).map {
            ($0.id, $0.alive)
        })
    }
}

@MainActor
private final class WatchTerminalComputerConnection {
    let binding: ComputerBinding
    var onChange: (() -> Void)?
    var onUnauthorized: (() -> Void)?

    private let identity: ClientIdentity
    private var control: RelayLink?
    private var linkState: RelayLink.State = .idle
    private var hostName: String?
    private var hostOnline = false
    private var directoryRevision: UInt64?
    private var directoryEntries: [Int: Bool] = [:]
    private var peerSessions: [SessionInfo] = []
    private var visibleSessions: [SessionInfo] = []
    private var receivedSessions = false
    private var agents: [AgentInfo] = []
    /// Optimistic dismissal overlay: agent id → the state it was dismissed
    /// in. Hidden while the broadcast still shows that state; pruned when
    /// the agent disappears or moves on (then it shows again).
    private var dismissed: [String: AgentState] = [:]

    init(binding: ComputerBinding, identity: ClientIdentity) {
        self.binding = binding
        self.identity = identity
    }

    func dismissAgent(id: String) {
        guard let info = agents.first(where: { $0.id == id }) else { return }
        dismissed[id] = info.state
        control?.send(.dismissAgent(agentId: id))
    }

    var snapshot: WatchTerminalComputer {
        let name = hostName ?? "Computer \(binding.computerID.prefix(6))"
        let visible = agents.filter { dismissed[$0.id] != $0.state }
        let visibleIDs = Set(visibleSessions.map(\.id))
        // Ownership dedup: managed agents morph their terminal row; the rest
        // land in the standalone Agents section (never both).
        let managed = Dictionary(
            grouping: visible.compactMap { info in
                info.sessionId.flatMap { visibleIDs.contains($0) ? (sid: $0, info: info) : nil }
            },
            by: \.sid
        )
        let standalone = visible.filter { info in
            guard let sid = info.sessionId else { return true }
            return !visibleIDs.contains(sid)
        }
        return WatchTerminalComputer(
            id: binding.computerID,
            name: name,
            online: hostOnline,
            ready: directoryRevision != nil && (!hostOnline || receivedSessions),
            terminals: visibleSessions.map { session in
                let agent = managed[session.id]?.first?.info
                return WatchTerminalDescriptor(
                    id: WatchTerminalID(
                        computerID: binding.computerID,
                        sessionID: session.id
                    ),
                    computerName: name,
                    title: session.title,
                    cols: session.cols,
                    rows: session.rows,
                    alive: session.alive,
                    agentState: agent?.state,
                    agentSlug: agent?.agent,
                    agentDetail: agent.map {
                        AgentActivity.Presentation(
                            info: $0, fallbackSessionName: session.title
                        ).detail
                    }
                )
            },
            agents: standalone
        )
    }

    func start() {
        guard control == nil else {
            control?.kick()
            return
        }
        let control = RelayLink(
            computer: binding,
            authorization: identity.clientToken,
            role: .client,
            principalID: identity.clientID,
            channel: .control
        )
        control.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state: state) }
        }
        control.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame: frame) }
        }
        control.onMetadata = { [weak self] metadata in
            MainActor.assumeIsolated { self?.handle(metadata: metadata) }
        }
        control.onUnauthorized = { [weak self] in
            MainActor.assumeIsolated { self?.onUnauthorized?() }
        }
        self.control = control
        control.start()
    }

    func stop() {
        control?.stop()
        control = nil
        linkState = .idle
    }

    private func handle(state: RelayLink.State) {
        linkState = state
        onChange?()
    }

    private func handle(frame: Frame) {
        guard frame.type == .ctl, let message = try? frame.controlMessage() else { return }
        switch message {
        case .hello(let who, _, _, _, _, let host):
            guard who == .host else { return }
            if let host, !host.isEmpty { hostName = host }
        case .sessions(let list):
            peerSessions = list
            receivedSessions = true
            applyDirectory()
        case .title(let id, let title):
            if let index = peerSessions.firstIndex(where: { $0.id == id }) {
                peerSessions[index].title = title
                applyDirectory()
            }
        case .exit(let id, _):
            if let index = peerSessions.firstIndex(where: { $0.id == id }) {
                peerSessions[index].alive = false
                applyDirectory()
            }
        case .agents(let list):
            agents = list
            dismissed = dismissed.filter { id, state in
                list.contains { $0.id == id && $0.state == state }
            }
        case .ready, .requestReplay, .create, .created, .close, .dismissAgent, .err:
            break
        }
        onChange?()
    }

    private func handle(metadata: RelayMetadata) {
        guard case .terminalDirectory(let directory) = metadata else { return }
        if let directoryRevision, directory.revision <= directoryRevision { return }

        self.directoryRevision = directory.revision
        hostOnline = directory.online
        if let name = directory.hostName, !name.isEmpty { hostName = name }
        directoryEntries = directory.online
            ? Dictionary(uniqueKeysWithValues: directory.sessions.map { ($0.id, $0.alive) })
            : [:]
        if !directory.online {
            peerSessions.removeAll(keepingCapacity: true)
            agents.removeAll(keepingCapacity: true)
        }
        applyDirectory()
        onChange?()
    }

    private func applyDirectory() {
        guard hostOnline else {
            visibleSessions = []
            return
        }
        visibleSessions = peerSessions.compactMap { session in
            guard let alive = directoryEntries[session.id] else { return nil }
            var value = session
            value.alive = alive
            return value
        }
    }
}
