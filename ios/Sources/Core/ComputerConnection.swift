import Combine
import Foundation
import PedalsKit

/// One bound computer: the long-lived `control` RelayLink to its room.
/// Publishes the daemon's session list, machine name, and connection state;
/// hands out per-terminal session links (see `TerminalManager`'s pool).
@MainActor
final class ComputerConnection {
    enum Event {
        /// Broadcast reply to a `create`; `req` says whose request it was.
        case created(id: Int, req: UInt32?)
        case exit(id: Int, code: Int)
        /// Daemon-reported failure; `req` ties it to one of our creates.
        case error(msg: String, req: UInt32?)
        /// The DO expired or explicitly cleared this computer's directory.
        case offline(removedTerminalCount: Int)
    }

    let binding: ComputerBinding
    private let clientID: String
    private let clientToken: String
    /// Stable server-issued identity.
    var id: String { binding.computerID }

    @Published private(set) var linkState: RelayLink.State = .idle
    /// Daemon machine name from the server-authoritative directory.
    @Published private(set) var hostName: String?
    /// True only when the Durable Object's terminal directory is online.
    @Published private(set) var hostOnline = false
    @Published private(set) var sessions: [SessionInfo] = []
    /// Latest coding-agent snapshot from the daemon's hooks; cleared with the
    /// session list when the host goes offline.
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var roundTripTime: TimeInterval?

    let events = PassthroughSubject<Event, Never>()

    private let control: RelayLink
    private var directoryRevision: UInt64?
    private var directoryEntries: [Int: Bool] = [:]
    private var peerSessions: [SessionInfo] = []
    /// Raw agent list from the daemon, held so a snapshot that arrives before
    /// the directory reports online still applies once it does.
    private var peerAgents: [AgentInfo] = []

    var displayName: String {
        hostName ?? "Computer \(binding.computerID.prefix(6))"
    }

    var directoryKnown: Bool { directoryRevision != nil }

    init(binding: ComputerBinding, clientID: String, clientToken: String) {
        self.binding = binding
        self.clientID = clientID
        self.clientToken = clientToken
        control = RelayLink(
            computer: binding,
            authorization: clientToken,
            role: .client,
            principalID: clientID,
            channel: .control
        )
        control.onState = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.linkState = state
                if case .connecting = state {
                    self.roundTripTime = nil
                }
            }
        }
        control.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame: frame) }
        }
        control.onRoundTrip = { [weak self] rtt in
            MainActor.assumeIsolated { self?.roundTripTime = rtt }
        }
        control.onMetadata = { [weak self] metadata in
            MainActor.assumeIsolated { self?.handle(metadata: metadata) }
        }
    }

    func start() {
        control.start()
    }

    func stop() {
        control.stop()
    }

    /// Reconnect immediately (app foregrounded / connectivity change).
    func kick() {
        control.kick()
    }

    // MARK: - Requests

    func createSession(cwd: String?, cols: Int, rows: Int, req: UInt32) {
        control.send(.create(cwd: cwd, cols: cols, rows: rows, req: req))
    }

    func closeSession(id: Int) {
        control.send(.close(id: id))
    }

    /// Removes an observed agent from the daemon's registry (bidirectional
    /// list; the record reappears on the agent's next hook event).
    func dismissAgent(id: String) {
        control.send(.dismissAgent(agentId: id))
    }

    /// A fresh (not yet started) data link for one of this computer's sessions.
    func makeSessionLink(sid: Int) -> RelayLink {
        RelayLink(
            computer: binding,
            authorization: clientToken,
            role: .client,
            principalID: clientID,
            channel: .session(sid: UInt32(sid))
        )
    }

    // MARK: - Control frames

    private func handle(frame: Frame) {
        guard frame.type == .ctl, let message = try? frame.controlMessage() else { return }
        switch message {
        case .hello(let who, _, _, _, _, let host):
            guard who == .host else { break }
            if let host, !host.isEmpty { hostName = host }
        case .sessions(let list):
            peerSessions = list
            applyDirectory()
        case .agents(let list):
            peerAgents = list
            agents = hostOnline ? list : []
        case .created(let id, let req):
            events.send(.created(id: id, req: req))
        case .title(let id, let title):
            // The daemon also rebroadcasts `sessions` on title changes; this
            // just applies it without waiting for the full list.
            guard let index = peerSessions.firstIndex(where: { $0.id == id }) else { break }
            peerSessions[index].title = title
            applyDirectory()
        case .exit(let id, let code):
            if let index = peerSessions.firstIndex(where: { $0.id == id }) {
                peerSessions[index].alive = false
            }
            applyDirectory()
            events.send(.exit(id: id, code: code))
        case .err(let msg, let req):
            events.send(.error(msg: msg, req: req))
        case .create, .close, .dismissAgent, .ready, .requestReplay:
            break // client→host only; ignore if mirrored back
        }
    }

    private func handle(metadata: RelayMetadata) {
        guard case .terminalDirectory(let directory) = metadata else { return }
        if let directoryRevision, directory.revision <= directoryRevision { return }

        let wasOnline = hostOnline
        let removedCount = sessions.count
        directoryRevision = directory.revision
        hostOnline = directory.online
        if let name = directory.hostName, !name.isEmpty { hostName = name }
        directoryEntries = directory.online
            ? Dictionary(uniqueKeysWithValues: directory.sessions.map { ($0.id, $0.alive) })
            : [:]

        if directory.online {
            applyDirectory()
            agents = peerAgents
        } else {
            peerSessions.removeAll(keepingCapacity: true)
            peerAgents.removeAll(keepingCapacity: true)
            sessions = []
            agents = []
            if wasOnline {
                events.send(.offline(removedTerminalCount: removedCount))
            }
        }
    }

    private func applyDirectory() {
        guard hostOnline else {
            sessions = []
            return
        }
        sessions = peerSessions.compactMap { session in
            guard let alive = directoryEntries[session.id] else { return nil }
            var current = session
            current.alive = alive
            return current
        }
    }
}
