import Combine
import Foundation
import TTYBuildKit

/// One observed coding-agent session, tagged with the computer it runs on
/// (docs/AGENT_MONITORING_DESIGN.md §4).
struct AgentRow: Equatable {
    let computerID: String
    let computerName: String
    let hostOnline: Bool
    let info: AgentInfo
}

/// One tab in the client-maintained cross-computer terminal list.
struct Terminal: Equatable {
    let id: TerminalID
    var info: SessionInfo
    var computerName: String
    /// A `close` is in flight; the tab is frozen until the daemon's next
    /// session list confirms removal.
    var closing = false
}

/// The hub: owns every `ComputerConnection` (one per bound computer), merges
/// their session lists into one ordered tab list, and pools the per-terminal
/// data channels.
///
/// Ordering is maintained client-side (the daemon only knows sets):
/// - a terminal this device created is inserted right after the active tab
///   and switched to (correlated via the `req` echo in `created`);
/// - terminals created elsewhere (other devices / CLI) are appended at the
///   end and do NOT steal focus.
///
/// Channels connect lazily on first activation. The most recently activated
/// terminals keep their data sockets (see `maxLiveChannels`); anything beyond
/// the pool is closed ("asleep") while the daemon keeps its PTY running.
/// Hidden pooled terminals keep parsing stdout into their emulators without
/// rendering, so paging back needs no replay. Reactivating a slept terminal
/// reconnects + replays, so it consumes no stdout/render/resize work while
/// asleep.
@MainActor
final class TerminalManager {
    @Published private(set) var computers: [ComputerConnection] = []
    /// Ordered tab list (the client-maintained order).
    @Published private(set) var terminals: [Terminal] = []
    @Published private(set) var activeID: TerminalID?
    /// Data-channel phase per terminal; missing key = asleep / never opened.
    @Published private(set) var phases: [TerminalID: TerminalChannel.Phase] = [:]
    /// Every observed coding agent from every bound computer, in computer
    /// order (unsorted within a computer — presentation sorts).
    @Published private(set) var agentRows: [AgentRow] = []
    /// Exclusive holder per terminal (docs/EXCLUSIVE_ATTACH_DESIGN.md).
    /// Missing key = pre-holder daemon: fully interactive, no placeholder.
    @Published private(set) var holders: [TerminalID: HolderInfo] = [:]

    /// How one terminal relates to this device's interactivity.
    enum HolderState: Equatable {
        /// We hold it, or the daemon predates holders: type freely.
        case interactive
        /// A holder-aware daemon reports nobody holding: tap to attach.
        case unheld
        /// Someone else holds it: full-screen placeholder, tap to take over.
        case takenOver(name: String?)
    }

    enum Output {
        case replay(Data)
        case stdout(Data)
        /// The daemon applied a grid this device never sent (another client
        /// resized the PTY). Hidden keep-fed emulators can't reconstruct
        /// output formatted for a foreign grid, so their stream is stale.
        case remoteResize(cols: UInt16, rows: UInt16)
        /// The daemon's relay socket blipped; frames sent meanwhile were
        /// dropped. Re-announce idempotent per-terminal state (grid size).
        case hostRestored
    }
    let outputs = PassthroughSubject<(id: TerminalID, output: Output), Never>()
    let exits = PassthroughSubject<(id: TerminalID, code: Int), Never>()
    /// Daemon-reported failures of *our* requests (e.g. a create that failed),
    /// for the UI to surface.
    let errors = PassthroughSubject<String, Never>()
    /// Transient, non-blocking app-level feedback.
    let notices = PassthroughSubject<String, Never>()
    /// A terminal created by *this* device just became active (the `created`
    /// echo matched one of our reqs) — the UI should switch to its page.
    let ownCreations = PassthroughSubject<TerminalID, Never>()

    /// Data-plane pool size: the most recently activated terminals keep their
    /// session sockets open so paging back to them is instant (no dial +
    /// replay wait). Anything beyond the limit is evicted LRU and sleeps;
    /// backgrounding still sleeps everything.
    static let maxLiveChannels = 3
    /// How long to hold an unidentified new session off the tab list while our
    /// own `create` is in flight (`sessions` can arrive before `created`).
    private static let placementGrace: TimeInterval = 2

    private let pairingStore: PairingStore
    /// Our relay principal, for `holders` comparisons (nil until paired).
    private var clientID: String?
    /// Read-only view for UI-side holder-state resolution against emitted
    /// snapshots.
    var clientPrincipal: String? { clientID }
    private var channels: [TerminalID: TerminalChannel] = [:]
    private var subscriptions: [String: Set<AnyCancellable>] = [:]
    /// req → computerID of our in-flight creates.
    private var pendingCreates: [UInt32: String] = [:]
    /// `created` said these are ours but `sessions` hasn't listed them yet.
    private var placeAsOwnWhenSeen: Set<TerminalID> = []
    /// New ids held back during `placementGrace` (see above).
    private var heldAppends: [TerminalID: SessionInfo] = [:]
    /// Latest per-computer agent snapshot, captured from the EMISSIONS (never
    /// read back off the connection — @Published emits during willSet).
    private struct AgentSource {
        var agents: [AgentInfo]
        var hostOnline: Bool
        var computerName: String
    }
    private var agentSources: [String: AgentSource] = [:]

    init(pairingStore: PairingStore) {
        self.pairingStore = pairingStore
        let identity: ClientIdentity
        let bindings: [ComputerBinding]
        do {
            guard let storedIdentity = try pairingStore.loadClientIdentity() else { return }
            identity = storedIdentity
            clientID = identity.clientID
            bindings = try pairingStore.loadAll()
        } catch {
            // A corrupt or inaccessible Keychain value is not empty state.
            // Explicit pairing will surface the error without overwriting it.
            return
        }
        for binding in bindings where binding.serviceURL == identity.serviceURL {
            attach(ComputerConnection(
                binding: binding,
                clientID: identity.clientID,
                clientToken: identity.clientToken
            ))
        }
    }

    // MARK: - Computers

    func computer(id: String) -> ComputerConnection? {
        computers.first { $0.id == id }
    }

    func addComputer(
        code: PairingCode,
        serviceURL: URL = TTYBuildServiceAPI.productionServiceURL
    ) async throws {
        let previousClientID = try pairingStore.loadClientIdentity()?.clientID
        let (binding, identity) = try await pairingStore.bind(
            code: code,
            serviceURL: serviceURL
        )
        finishAdding(binding: binding, identity: identity, previousClientID: previousClientID)
    }

    private func finishAdding(
        binding: ComputerBinding,
        identity: ClientIdentity,
        previousClientID: String?
    ) {

        clientID = identity.clientID
        if let previousClientID, previousClientID != identity.clientID {
            // Every existing relay bearer belongs to the rejected identity.
            // Tear down connections, channels, terminal tabs, and pending
            // requests before attaching the replacement identity.
            for connection in computers {
                removeComputerLocally(connection)
            }
        } else if let existing = computer(id: binding.computerID) {
            removeComputerLocally(existing)
        }
        attach(ComputerConnection(
            binding: binding,
            clientID: identity.clientID,
            clientToken: identity.clientToken
        ))
    }

    /// Attaches a computer whose binding arrived through a confirmed
    /// reverse-pairing claim. The Keychain commit happens here, before the
    /// caller confirms server-side, so reconcile() can never race the edge.
    func addReversePairedComputer(binding: ComputerBinding) async throws {
        let identity = try await pairingStore.commitReversePairedBinding(binding)
        finishAdding(
            binding: binding,
            identity: identity,
            previousClientID: identity.clientID
        )
    }

    /// Unbind: forget the pairing and drop its terminals from the tab list.
    func removeComputer(id: String) async throws {
        try await pairingStore.unbind(computerID: id)
        if let connection = computer(id: id) {
            removeComputerLocally(connection)
        }
    }

    private func attach(_ connection: ComputerConnection) {
        computers.append(connection)
        var cancellables: Set<AnyCancellable> = []
        connection.$sessions
            .sink { [weak self, weak connection] list in
                guard let self, let connection else { return }
                self.reconcile(computer: connection, list: list)
            }
            .store(in: &cancellables)
        connection.events
            .sink { [weak self, weak connection] event in
                guard let self, let connection else { return }
                self.handle(event: event, from: connection)
            }
            .store(in: &cancellables)
        connection.$agents
            .combineLatest(connection.$hostOnline, connection.$hostName)
            .sink { [weak self, weak connection] agents, hostOnline, hostName in
                guard let self, let connection else { return }
                let name = hostName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Computer \(connection.binding.computerID.prefix(6))"
                self.agentSources[connection.id] = AgentSource(
                    agents: agents, hostOnline: hostOnline, computerName: name
                )
                self.rebuildAgentRows()
            }
            .store(in: &cancellables)
        connection.$holders
            .sink { [weak self, weak connection] map in
                guard let self, let connection else { return }
                let cid = connection.id
                var merged = self.holders.filter { $0.key.computerID != cid }
                for (sid, holder) in map {
                    merged[TerminalID(computerID: cid, sid: sid)] = holder
                }
                self.holders = merged
            }
            .store(in: &cancellables)
        subscriptions[connection.id] = cancellables
        connection.start()
    }

    private func removeComputerLocally(_ connection: ComputerConnection) {
        subscriptions.removeValue(forKey: connection.id)
        connection.stop()
        computers.removeAll { $0.id == connection.id }
        holders = holders.filter { $0.key.computerID != connection.id }
        let removed = terminals.filter { $0.id.computerID == connection.id }.map(\.id)
        for id in removed { dropTerminal(id) }
        pendingCreates = pendingCreates.filter { $0.value != connection.id }
        // Drop pending placements too, else a scheduled held-append flush (or a
        // late `created`) would append a ghost tab for an unbound computer that
        // can never open a channel or be closed.
        heldAppends = heldAppends.filter { $0.key.computerID != connection.id }
        placeAsOwnWhenSeen = placeAsOwnWhenSeen.filter { $0.computerID != connection.id }
        agentSources.removeValue(forKey: connection.id)
        rebuildAgentRows()
    }

    // MARK: - Terminal accessors

    func terminal(_ id: TerminalID) -> Terminal? {
        terminals.first { $0.id == id }
    }

    // MARK: - Agents

    private func rebuildAgentRows() {
        agentRows = computers.flatMap { connection -> [AgentRow] in
            guard let source = agentSources[connection.id] else { return [] }
            return source.agents.map {
                AgentRow(
                    computerID: connection.id,
                    computerName: source.computerName,
                    hostOnline: source.hostOnline,
                    info: $0
                )
            }
        }
    }

    /// The managed agent running inside terminal `id`, if any. Should several
    /// hooks report the same PTY, the most attention-worthy (waiting > error >
    /// running > done, then most recently updated) wins.
    func agent(for id: TerminalID) -> AgentInfo? {
        Self.agent(for: id, in: agentRows)
    }

    /// Static so views can resolve against *emitted* rows (a sink must never
    /// read `agentRows` back off the manager — @Published emits during willSet).
    static func agent(for id: TerminalID, in rows: [AgentRow]) -> AgentInfo? {
        rows
            .filter { $0.computerID == id.computerID && $0.info.sessionId == id.sid }
            .map(\.info)
            .min { lhs, rhs in
                if lhs.state.attentionRank != rhs.state.attentionRank {
                    return lhs.state.attentionRank < rhs.state.attentionRank
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    // MARK: - Activation + connection pool

    func activate(_ id: TerminalID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        if activeID != id {
            activeID = id
        }
        ensureChannel(id)
    }

    private func ensureChannel(_ id: TerminalID) {
        if let channel = channels[id] {
            channel.touch()
            return
        }
        guard let connection = computer(id: id.computerID) else { return }
        let channel = TerminalChannel(
            terminalID: id, link: connection.makeSessionLink(sid: id.sid)
        )
        channel.onReplay = { [weak self] data in
            self?.outputs.send((id: id, output: .replay(data)))
        }
        channel.onStdout = { [weak self] data in
            self?.outputs.send((id: id, output: .stdout(data)))
        }
        channel.onResizeEcho = { [weak self] cols, rows in
            self?.outputs.send((id: id, output: .remoteResize(cols: cols, rows: rows)))
        }
        channel.onHostRestored = { [weak self] in
            self?.outputs.send((id: id, output: .hostRestored))
        }
        channel.onPhase = { [weak self] phase in
            self?.phases[id] = phase
        }
        phases[id] = channel.phase
        channels[id] = channel
        evictBeyondPoolLimit()
    }

    /// Sleep the least recently activated channels once the pool overflows,
    /// never the active one. The daemon keeps every PTY running regardless.
    private func evictBeyondPoolLimit() {
        while channels.count > Self.maxLiveChannels {
            let victim = channels.values
                .filter { $0.terminalID != activeID }
                .min { $0.lastActivated < $1.lastActivated }
            guard let victim else { return }
            victim.stop()
            channels.removeValue(forKey: victim.terminalID)
            phases.removeValue(forKey: victim.terminalID)
        }
    }

    /// Stop terminal data sockets without touching control connections or the
    /// daemon PTYs. The selected terminal identity is retained so foreground
    /// restoration can reopen exactly that channel and receive a fresh replay.
    func sleepAllChannels() {
        for channel in channels.values {
            channel.stop()
        }
        channels.removeAll()
        phases = [:]
    }

    /// Reconnect currently open links immediately (app returned to foreground).
    /// A sleeping terminal is reopened by `activate`, after its page is ready
    /// to consume the replay.
    func kickAll() {
        for computer in computers { computer.kick() }
        for channel in channels.values { channel.kick() }
    }

    // MARK: - Create

    /// Creates a terminal on `computerID`. If the active terminal lives on the
    /// same computer the new one inherits its live cwd; otherwise home.
    func createTerminal(on computerID: String, cols: Int, rows: Int) {
        guard let connection = computer(id: computerID) else { return }
        let cwd: String? = {
            guard let activeID, activeID.computerID == computerID,
                  let active = terminal(activeID)
            else { return nil }
            return active.info.cwd.isEmpty ? nil : active.info.cwd
        }()
        let req = UInt32.random(in: .min ... .max)
        pendingCreates[req] = computerID
        connection.createSession(cwd: cwd, cols: cols, rows: rows, req: req)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.pendingCreates.removeValue(forKey: req)
        }
    }

    // MARK: - Close (async: frozen until the daemon confirms)

    func closeTerminal(_ id: TerminalID) {
        guard let index = terminals.firstIndex(where: { $0.id == id }),
              !terminals[index].closing
        else { return }
        terminals[index].closing = true
        computer(id: id.computerID)?.closeSession(id: id.sid)
    }

    /// Tab-close selection rule: prefer the preceding tab, using the next tab
    /// only when the first tab is being removed.
    static func replacementID(
        afterClosing id: TerminalID,
        in terminals: [Terminal]
    ) -> TerminalID? {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return nil }
        if index > terminals.startIndex {
            return terminals[index - 1].id
        }
        return terminals.dropFirst().first?.id
    }

    /// Forwards an agent dismissal to its daemon (the Home list is
    /// bidirectional): the record disappears for every client until the
    /// agent's next hook event. The caller hides the row optimistically.
    func dismissAgent(computerID: String, agentID: String) {
        computer(id: computerID)?.dismissAgent(id: agentID)
    }

    // MARK: - Exclusive hold

    /// Resolves against *emitted* values (a sink must never read @Published
    /// state back off the manager — emission happens during willSet).
    static func holderState(
        for id: TerminalID, in holders: [TerminalID: HolderInfo], clientID: String?
    ) -> HolderState {
        guard let holder = holders[id] else { return .interactive }
        switch holder.kind {
        case .none:
            return .unheld
        case .client where holder.principal == clientID:
            return .interactive
        case .client:
            return .takenOver(name: holder.name ?? "another device")
        case .attach:
            return .takenOver(name: holder.name ?? "Terminal")
        }
    }

    func holderState(_ id: TerminalID) -> HolderState {
        Self.holderState(for: id, in: holders, clientID: clientID)
    }

    /// Unconditional take-over (tap on the placeholder). The confirmation is
    /// the `takeover` broadcast flipping `holders`.
    func claimTerminal(_ id: TerminalID) {
        computer(id: id.computerID)?.claimSession(id: id.sid)
    }

    // MARK: - Terminal I/O passthrough

    func sendStdin(_ id: TerminalID, data: Data) {
        guard activeID == id, terminal(id)?.closing != true,
              holderState(id) == .interactive
        else { return }
        channels[id]?.sendStdin(data)
    }

    func sendResize(_ id: TerminalID, cols: UInt16, rows: UInt16) {
        guard activeID == id, holderState(id) == .interactive else { return }
        channels[id]?.sendResize(cols: cols, rows: rows)
    }

    /// Ask the host for a fresh replay snapshot (the UI missed one, e.g. the
    /// page was built after the channel already went live).
    func requestReplay(_ id: TerminalID) {
        channels[id]?.requestReplay()
    }

    // MARK: - Reconciliation

    private func handle(event: ComputerConnection.Event, from connection: ComputerConnection) {
        switch event {
        case .created(let sid, let req):
            let id = TerminalID(computerID: connection.id, sid: sid)
            let isOurs = req.map { pendingCreates.removeValue(forKey: $0) != nil } ?? false
            if isOurs {
                if let info = heldAppends.removeValue(forKey: id) {
                    insertOwn(id: id, info: info, computerName: connection.displayName)
                } else if terminals.contains(where: { $0.id == id }) {
                    moveAfterActiveAndActivate(id)
                } else {
                    placeAsOwnWhenSeen.insert(id)
                }
            } else if let info = heldAppends.removeValue(forKey: id) {
                append(id: id, info: info, computerName: connection.displayName)
            }
        case .exit(let sid, let code):
            exits.send((id: TerminalID(computerID: connection.id, sid: sid), code: code))
        case .error(let msg, let req):
            // Only failures of requests *this* device made are ours to show.
            guard let req, pendingCreates.removeValue(forKey: req) != nil else { break }
            errors.send(msg)
        case .offline(let removedTerminalCount):
            pendingCreates = pendingCreates.filter { $0.value != connection.id }
            heldAppends = heldAppends.filter { $0.key.computerID != connection.id }
            placeAsOwnWhenSeen = placeAsOwnWhenSeen.filter { $0.computerID != connection.id }
            guard removedTerminalCount > 0 else { break }
            let suffix = removedTerminalCount == 1 ? "terminal was" : "terminals were"
            notices.send("\(connection.displayName) went offline. \(removedTerminalCount) \(suffix) hidden.")
        case .hooksStatus, .updateStatus:
            // Request/reply traffic for the computer detail page; subscribers
            // (e.g. ComputerDetailViewController) observe the connection's
            // events directly.
            break
        }
    }

    private func reconcile(computer connection: ComputerConnection, list: [SessionInfo]) {
        let cid = connection.id
        let listed = Dictionary(uniqueKeysWithValues: list.map {
            (TerminalID(computerID: cid, sid: $0.id), $0)
        })

        // Update / remove existing tabs of this computer.
        for terminal in terminals where terminal.id.computerID == cid {
            if let info = listed[terminal.id] {
                update(terminal.id) { tab in
                    tab.info = info
                    tab.computerName = connection.displayName
                }
                // The close ctl can be lost while the host is away (the relay
                // drops it, possibly with our control link never dropping). A
                // still-listed closing tab means the daemon hasn't seen the
                // close — re-issue it on each fresh list until it takes.
                if terminal.closing {
                    connection.closeSession(id: terminal.id.sid)
                }
            } else {
                dropTerminal(terminal.id)
            }
        }
        heldAppends = heldAppends.filter {
            $0.key.computerID != cid || listed[$0.key] != nil
        }

        // Place new ids.
        let known = Set(terminals.map(\.id))
        let ourCreateInFlight = pendingCreates.values.contains(cid)
        for info in list {
            let id = TerminalID(computerID: cid, sid: info.id)
            guard !known.contains(id), heldAppends[id] == nil else { continue }
            if placeAsOwnWhenSeen.remove(id) != nil {
                insertOwn(id: id, info: info, computerName: connection.displayName)
            } else if ourCreateInFlight {
                // Might be our own create whose `created` echo is still in
                // flight; hold it briefly so it doesn't first appear at the
                // end and then jump.
                heldAppends[id] = info
                scheduleHeldFlush(id: id, computerName: connection.displayName)
            } else {
                append(id: id, info: info, computerName: connection.displayName)
            }
        }

        // Nothing was active yet (fresh launch): show the first tab.
        if activeID == nil, let first = terminals.first {
            activate(first.id)
        }
    }

    private func scheduleHeldFlush(id: TerminalID, computerName: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.placementGrace))
            guard let self, let info = self.heldAppends.removeValue(forKey: id) else { return }
            self.append(id: id, info: info, computerName: computerName)
        }
    }

    /// Remote-created terminals: appended at the end, focus untouched.
    private func append(id: TerminalID, info: SessionInfo, computerName: String) {
        guard !terminals.contains(where: { $0.id == id }) else { return }
        terminals.append(Terminal(id: id, info: info, computerName: computerName))
    }

    /// Our own terminal: insert right after the active tab and switch to it.
    private func insertOwn(id: TerminalID, info: SessionInfo, computerName: String) {
        guard !terminals.contains(where: { $0.id == id }) else {
            moveAfterActiveAndActivate(id)
            return
        }
        let terminal = Terminal(id: id, info: info, computerName: computerName)
        terminals.insert(terminal, at: insertionIndexAfterActive())
        activate(id)
        ownCreations.send(id)
    }

    private func moveAfterActiveAndActivate(_ id: TerminalID) {
        guard let from = terminals.firstIndex(where: { $0.id == id }) else { return }
        let terminal = terminals.remove(at: from)
        terminals.insert(terminal, at: insertionIndexAfterActive())
        activate(id)
        ownCreations.send(id)
    }

    private func insertionIndexAfterActive() -> Int {
        guard let activeID,
              let index = terminals.firstIndex(where: { $0.id == activeID })
        else { return terminals.count }
        return index + 1
    }

    private func update(_ id: TerminalID, _ mutate: (inout Terminal) -> Void) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        mutate(&terminals[index])
    }

    private func dropTerminal(_ id: TerminalID) {
        channels[id]?.stop()
        channels.removeValue(forKey: id)
        phases.removeValue(forKey: id)
        placeAsOwnWhenSeen.remove(id)
        heldAppends.removeValue(forKey: id)
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        let replacementID = Self.replacementID(afterClosing: id, in: terminals)
        terminals.remove(at: index)

        if activeID == id {
            // Tab-close convention is to return to the tab immediately before
            // the closed one. The first tab has no predecessor, so it uses the
            // following tab instead.
            if let replacementID {
                activate(replacementID)
            } else {
                activeID = nil
            }
        }
    }
}

extension AgentState {
    /// Attention order for sorting and dedup: waiting > error > running > done.
    var attentionRank: Int {
        switch self {
        case .waiting: 0
        case .error: 1
        case .running: 2
        case .done: 3
        }
    }

    /// States that should pull the user in ("needs you").
    var needsAttention: Bool {
        self == .waiting || self == .error
    }
}
