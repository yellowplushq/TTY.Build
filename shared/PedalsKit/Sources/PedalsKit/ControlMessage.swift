import Foundation

/// Peer role, as carried in `hello.who`; selects the local E2EE direction keys.
public enum PeerRole: String, Codable, Sendable {
    case host
    case client
}

/// One entry of the `sessions` list (PROTOCOL.md §5).
public struct SessionInfo: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    /// The session's live working directory (daemon polls the foreground
    /// process cwd; used to open a new terminal in the same directory).
    public var cwd: String
    public var rows: Int
    public var cols: Int
    /// Unix epoch seconds.
    public var createdAt: Double
    public var alive: Bool

    public init(id: Int, title: String, cwd: String, rows: Int, cols: Int,
                createdAt: Double, alive: Bool) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
        self.createdAt = createdAt
        self.alive = alive
    }
}

/// Coding-agent session state, reported by daemon-installed hooks
/// (docs/AGENT_MONITORING_DESIGN.md). Unknown wire values decode as
/// `.running` so newer daemons stay renderable on older clients.
public enum AgentState: String, Codable, Sendable {
    case running
    case waiting
    /// The turn ended on an agent-side failure (e.g. an API error). Sticky
    /// until a new prompt or session start; needs the user's attention.
    case error
    case done

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentState(rawValue: raw) ?? .running
    }
}

/// One entry of the `agents` list: a coding-agent session observed via hooks.
/// Rich content (session name, cwd, action, message, prompt) is E2EE-only —
/// it must never appear in relay metadata or D1.
public struct AgentInfo: Codable, Equatable, Sendable {
    /// Hook-reported session id, unique per agent process session.
    public var id: String
    /// Agent kind slug: "claude", "codex", …
    public var agent: String
    public var state: AgentState
    /// User-facing session title. For daemon-owned terminals this is the live
    /// terminal session title; unmanaged agents may report their own title.
    public var sessionName: String?
    /// The agent's working directory (project path).
    public var cwd: String
    /// One-line current action while running, e.g. "Bash: git status".
    public var action: String?
    /// The agent's last message (waiting/done), truncated by the daemon.
    public var message: String?
    /// The user's last prompt, truncated by the daemon.
    public var prompt: String?
    /// Daemon session id when the agent runs inside a daemon-owned PTY;
    /// nil ⇒ unmanaged (rendered in the standalone Agents section).
    public var sessionId: Int?
    /// Terminal app name for unmanaged agents (e.g. "iTerm2"), best-effort.
    public var term: String?
    /// Unix epoch seconds of the last state change.
    public var updatedAt: Double

    public init(id: String, agent: String, state: AgentState,
                sessionName: String? = nil, cwd: String,
                action: String? = nil, message: String? = nil,
                prompt: String? = nil, sessionId: Int? = nil,
                term: String? = nil, updatedAt: Double) {
        self.id = id
        self.agent = agent
        self.state = state
        self.sessionName = sessionName
        self.cwd = cwd
        self.action = action
        self.message = message
        self.prompt = prompt
        self.sessionId = sessionId
        self.term = term
        self.updatedAt = updatedAt
    }
}

/// ctl JSON messages (PROTOCOL.md §5). Wire form is `{"t":"<kind>", ...}`.
///
/// ctl only flows on the control channel. Data channels (one WebSocket per
/// attached session) carry stdin/stdout/resize/replay; connecting a data
/// channel is itself the "attach", so there is no attach/detach ctl.
public enum ControlMessage: Equatable, Sendable {
    /// First frame after connect, from each side. `host` is the daemon's
    /// machine name, sent by the host so clients can label the computer.
    case hello(
        who: PeerRole,
        principal: String,
        connEpoch: UInt32,
        nonce: Data,
        ver: Int,
        host: String?
    )
    /// First connection-bound frame. It proves the sender derived keys from
    /// both fresh nonces before application traffic is accepted.
    case ready(who: PeerRole, echoNonce: Data)
    /// Client→host, session channels only: request a fresh replay snapshot.
    case requestReplay
    /// host→client: private descriptors for the DO directory's session IDs.
    case sessions(list: [SessionInfo])
    /// host→client: full snapshot of observed coding-agent sessions,
    /// broadcast on change (debounced) and on client hello.
    case agents(list: [AgentInfo])
    /// client→host: create a session. `cwd` nil ⇒ JSON null (daemon: home).
    /// `req` is a client-chosen random tag echoed back in `created`.
    case create(cwd: String?, cols: Int, rows: Int, req: UInt32?)
    /// host→client: reply to `create`, broadcast to every control client.
    /// `req` echoes the tag from `create` so the requesting client can tell
    /// its own terminal apart from ones created by other devices.
    case created(id: Int, req: UInt32?)
    /// client→host: close a session.
    case close(id: Int)
    /// client→host: remove an observed agent from the registry (the Home
    /// list is bidirectional — a dismissed agent disappears for every
    /// client until its next hook event recreates the record). `agentId`
    /// is the hook session id from `AgentInfo.id`.
    case dismissAgent(agentId: String)
    /// host→client: session title changed.
    case title(id: Int, title: String)
    /// host→client: session process exited.
    case exit(id: Int, code: Int)
    /// either direction: non-fatal error report. `req` echoes the tag of the
    /// `create` that failed (nil for errors not tied to a request), so the
    /// requesting client can stop waiting and surface the message.
    case err(msg: String, req: UInt32? = nil)
}

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, who, principal, connEpoch, nonce, ver, host, echoNonce, list, cwd, cols, rows, id, title, code, msg, req, agents, agentId
    }

    private var kind: String {
        switch self {
        case .hello: "hello"
        case .ready: "ready"
        case .requestReplay: "requestReplay"
        case .sessions: "sessions"
        case .agents: "agents"
        case .create: "create"
        case .created: "created"
        case .close: "close"
        case .dismissAgent: "dismiss-agent"
        case .title: "title"
        case .exit: "exit"
        case .err: "err"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .t)
        switch self {
        case let .hello(who, principal, connEpoch, nonce, ver, host):
            try container.encode(who, forKey: .who)
            try container.encode(principal, forKey: .principal)
            try container.encode(connEpoch, forKey: .connEpoch)
            try container.encode(nonce, forKey: .nonce)
            try container.encode(ver, forKey: .ver)
            try container.encodeIfPresent(host, forKey: .host)
        case let .ready(who, echoNonce):
            try container.encode(who, forKey: .who)
            try container.encode(echoNonce, forKey: .echoNonce)
        case .requestReplay:
            break
        case let .sessions(list):
            try container.encode(list, forKey: .list)
        case let .agents(list):
            try container.encode(list, forKey: .agents)
        case let .create(cwd, cols, rows, req):
            try container.encode(cwd, forKey: .cwd) // nil encodes as JSON null per spec
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
            try container.encodeIfPresent(req, forKey: .req)
        case let .created(id, req):
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(req, forKey: .req)
        case let .close(id):
            try container.encode(id, forKey: .id)
        case let .dismissAgent(agentId):
            try container.encode(agentId, forKey: .agentId)
        case let .title(id, title):
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
        case let .exit(id, code):
            try container.encode(id, forKey: .id)
            try container.encode(code, forKey: .code)
        case let .err(msg, req):
            try container.encode(msg, forKey: .msg)
            try container.encodeIfPresent(req, forKey: .req)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .t)
        switch kind {
        case "hello":
            self = .hello(
                who: try container.decode(PeerRole.self, forKey: .who),
                principal: try container.decode(String.self, forKey: .principal),
                connEpoch: try container.decode(UInt32.self, forKey: .connEpoch),
                nonce: try container.decode(Data.self, forKey: .nonce),
                ver: try container.decode(Int.self, forKey: .ver),
                host: try container.decodeIfPresent(String.self, forKey: .host)
            )
        case "ready":
            self = .ready(
                who: try container.decode(PeerRole.self, forKey: .who),
                echoNonce: try container.decode(Data.self, forKey: .echoNonce)
            )
        case "requestReplay":
            self = .requestReplay
        case "sessions":
            self = .sessions(list: try container.decode([SessionInfo].self, forKey: .list))
        case "agents":
            self = .agents(list: try container.decode([AgentInfo].self, forKey: .agents))
        case "create":
            self = .create(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                cols: try container.decode(Int.self, forKey: .cols),
                rows: try container.decode(Int.self, forKey: .rows),
                req: try container.decodeIfPresent(UInt32.self, forKey: .req)
            )
        case "created":
            self = .created(
                id: try container.decode(Int.self, forKey: .id),
                req: try container.decodeIfPresent(UInt32.self, forKey: .req)
            )
        case "close":
            self = .close(id: try container.decode(Int.self, forKey: .id))
        case "dismiss-agent":
            self = .dismissAgent(agentId: try container.decode(String.self, forKey: .agentId))
        case "title":
            self = .title(
                id: try container.decode(Int.self, forKey: .id),
                title: try container.decode(String.self, forKey: .title)
            )
        case "exit":
            self = .exit(
                id: try container.decode(Int.self, forKey: .id),
                code: try container.decode(Int.self, forKey: .code)
            )
        case "err":
            self = .err(
                msg: try container.decode(String.self, forKey: .msg),
                req: try container.decodeIfPresent(UInt32.self, forKey: .req)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t, in: container,
                debugDescription: "unknown ctl message kind \"\(kind)\""
            )
        }
    }

    // MARK: JSON helpers

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(ControlMessage.self, from: jsonData)
    }
}
