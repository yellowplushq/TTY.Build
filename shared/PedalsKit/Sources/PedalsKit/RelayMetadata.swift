import Foundation

/// Server-visible control-plane metadata carried as WebSocket text messages.
/// Terminal titles, working directories, and terminal bytes never appear here;
/// those remain inside the E2EE binary frame stream.
public enum RelayMetadata: Equatable, Sendable {
    public enum OfflineReason: String, Codable, Equatable, Sendable {
        case hostRequested = "host-requested"
        case connectionLost = "connection-lost"
        case leaseExpired = "lease-expired"
    }

    public struct DirectoryEntry: Codable, Equatable, Hashable, Sendable {
        public let id: Int
        public let alive: Bool

        public init(id: Int, alive: Bool) {
            self.id = id
            self.alive = alive
        }
    }

    /// Per-state coding-agent aggregate counts. Deliberately the only
    /// agent-derived data the Worker ever sees: bare numbers, no names,
    /// no projects, no messages. `done` is a short-lived projection used to
    /// keep a completion visible long enough for ActivityKit. `waiting` folds
    /// in error states — both park the agent on the user.
    public struct AgentCounts: Codable, Equatable, Hashable, Sendable {
        public static let zero = AgentCounts(running: 0, waiting: 0, done: 0)
        public static let maxCount = 255

        public let running: Int
        public let waiting: Int
        /// Recently completed agents only. The daemon drops this projection
        /// after the final Live Activity has had time to be seen.
        public let done: Int

        public init(running: Int, waiting: Int, done: Int = 0) {
            self.running = running
            self.waiting = waiting
            self.done = done
        }

        private enum CodingKeys: String, CodingKey {
            case running, waiting, done
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                running: try container.decode(Int.self, forKey: .running),
                waiting: try container.decode(Int.self, forKey: .waiting),
                done: try container.decodeIfPresent(Int.self, forKey: .done) ?? 0
            )
        }
    }

    /// Server-visible routing wrapped around an E2EE agent snapshot. The
    /// Worker may use `state` to choose ActivityKit alert copy and priority,
    /// but cannot read the agent, project, prompt, action, or message.
    public struct AgentActivityEnvelope: Codable, Equatable, Sendable {
        public static let maxSealedBytes = 2_000

        public let eventID: String
        public let state: AgentState
        public let updatedAt: Int64
        public let alert: Bool
        public let sealed: Data

        public init(
            eventID: String = UUID().uuidString.lowercased(),
            state: AgentState,
            updatedAt: Int64,
            alert: Bool,
            sealed: Data
        ) {
            self.eventID = eventID
            self.state = state
            self.updatedAt = updatedAt
            self.alert = alert
            self.sealed = sealed
        }
    }

    public struct Directory: Equatable, Sendable {
        public let revision: UInt64
        public let online: Bool
        public let hostName: String?
        public let sessions: [DirectoryEntry]
        public let updatedAt: Int64
        public let reason: OfflineReason?

        public init(
            revision: UInt64,
            online: Bool,
            hostName: String?,
            sessions: [DirectoryEntry],
            updatedAt: Int64,
            reason: OfflineReason? = nil
        ) {
            self.revision = revision
            self.online = online
            self.hostName = hostName
            self.sessions = sessions
            self.updatedAt = updatedAt
            self.reason = reason
        }
    }

    /// Host -> Durable Object. This is a complete, idempotent snapshot and also
    /// renews the host lease. Repeating it is safe after reconnect ambiguity.
    case hostSnapshot(hostName: String, sessions: [DirectoryEntry], agents: AgentCounts)
    /// Host -> Durable Object -> Live Activity endpoints. Never persisted by
    /// the Worker; delivery is best-effort and the count snapshot remains the
    /// durable fallback.
    case agentActivity(AgentActivityEnvelope)
    /// Host -> Durable Object. Used before sleep and orderly process exit.
    case hostOffline
    /// Durable Object -> control clients. The revision is assigned by the DO.
    case terminalDirectory(Directory)
    /// Durable Object -> session-channel clients. This affects transport only;
    /// terminal visibility comes exclusively from `terminalDirectory`.
    case channelState(online: Bool)
}

extension RelayMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, hostName, sessions, agents, activity, revision, online, updatedAt, reason
    }

    private enum Kind: String, Codable {
        case hostSnapshot = "host-snapshot"
        case agentActivity = "agent-activity"
        case hostOffline = "host-offline"
        case terminalDirectory = "terminal-directory"
        case channelState = "channel-state"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostSnapshot(let hostName, let sessions, let agents):
            try container.encode(Kind.hostSnapshot, forKey: .type)
            try container.encode(hostName, forKey: .hostName)
            try container.encode(sessions, forKey: .sessions)
            // Zero counts are omitted (absent decodes as zero): a Worker that
            // predates the agents field kills the socket on unknown keys, so
            // an agent-free daemon stays compatible either way.
            if agents != .zero {
                try container.encode(agents, forKey: .agents)
            }
        case .agentActivity(let activity):
            try container.encode(Kind.agentActivity, forKey: .type)
            try container.encode(activity, forKey: .activity)
        case .hostOffline:
            try container.encode(Kind.hostOffline, forKey: .type)
        case .terminalDirectory(let directory):
            try container.encode(Kind.terminalDirectory, forKey: .type)
            try container.encode(directory.revision, forKey: .revision)
            try container.encode(directory.online, forKey: .online)
            try container.encodeIfPresent(directory.hostName, forKey: .hostName)
            try container.encode(directory.sessions, forKey: .sessions)
            try container.encode(directory.updatedAt, forKey: .updatedAt)
            try container.encodeIfPresent(directory.reason, forKey: .reason)
        case .channelState(let online):
            try container.encode(Kind.channelState, forKey: .type)
            try container.encode(online, forKey: .online)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hostSnapshot:
            let hostName = try container.decode(String.self, forKey: .hostName)
            let sessions = try container.decode([DirectoryEntry].self, forKey: .sessions)
            // Absent on snapshots from pre-agent daemons; decode as zero.
            let agents = try container.decodeIfPresent(AgentCounts.self, forKey: .agents) ?? .zero
            try Self.validate(hostName: hostName, sessions: sessions, codingPath: decoder.codingPath)
            try Self.validateAgentCounts(agents, codingPath: decoder.codingPath)
            self = .hostSnapshot(
                hostName: hostName,
                sessions: sessions,
                agents: agents
            )
        case .agentActivity:
            let activity = try container.decode(AgentActivityEnvelope.self, forKey: .activity)
            guard activity.eventID.count == 36,
                  UUID(uuidString: activity.eventID) != nil,
                  activity.updatedAt >= 0,
                  !activity.sealed.isEmpty,
                  !(activity.alert && activity.state == .running),
                  activity.sealed.count <= AgentActivityEnvelope.maxSealedBytes
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid agent activity envelope"
                ))
            }
            self = .agentActivity(activity)
        case .hostOffline:
            self = .hostOffline
        case .terminalDirectory:
            let online = try container.decode(Bool.self, forKey: .online)
            let hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
            let sessions = try container.decode([DirectoryEntry].self, forKey: .sessions)
            let updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
            let reason = try container.decodeIfPresent(OfflineReason.self, forKey: .reason)
            if let hostName {
                try Self.validateHostName(hostName, codingPath: decoder.codingPath)
            }
            try Self.validateSessions(sessions, codingPath: decoder.codingPath)
            guard updatedAt >= 0,
                  online || sessions.isEmpty,
                  online ? reason == nil : true
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid terminal directory state"
                ))
            }
            self = .terminalDirectory(.init(
                revision: try container.decode(UInt64.self, forKey: .revision),
                online: online,
                hostName: hostName,
                sessions: sessions,
                updatedAt: updatedAt,
                reason: reason
            ))
        case .channelState:
            self = .channelState(online: try container.decode(Bool.self, forKey: .online))
        }
    }

    private static func validate(
        hostName: String,
        sessions: [DirectoryEntry],
        codingPath: [any CodingKey]
    ) throws {
        try validateHostName(hostName, codingPath: codingPath)
        try validateSessions(sessions, codingPath: codingPath)
    }

    private static func validateHostName(
        _ value: String,
        codingPath: [any CodingKey]
    ) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf16.count <= 128,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "invalid terminal directory host name"
            ))
        }
    }

    private static func validateAgentCounts(
        _ counts: AgentCounts,
        codingPath: [any CodingKey]
    ) throws {
        for value in [counts.running, counts.waiting, counts.done] {
            guard (0...AgentCounts.maxCount).contains(value) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath,
                    debugDescription: "agent counts must be within 0...\(AgentCounts.maxCount)"
                ))
            }
        }
    }

    private static func validateSessions(
        _ sessions: [DirectoryEntry],
        codingPath: [any CodingKey]
    ) throws {
        guard sessions.count <= 255 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "terminal directory exceeds 255 entries"
            ))
        }
        var previous = -1
        for entry in sessions {
            guard entry.id >= 0,
                  UInt64(entry.id) <= UInt64(UInt32.max),
                  entry.id > previous
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath,
                    debugDescription: "terminal directory IDs must be ordered and unique UInt32 values"
                ))
            }
            previous = entry.id
        }
    }

    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: [], debugDescription: "relay metadata is not UTF-8")
            )
        }
        return text
    }

    public init(jsonText: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(jsonText.utf8))
    }
}
