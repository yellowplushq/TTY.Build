import ActivityKit
import CryptoKit
import Foundation
import PedalsKit

public struct TTYActivityAttributes: ActivityAttributes, Codable, Hashable, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// A compact, on-device-only copy of the exact presentation Home
        /// already resolved. It makes a foreground ActivityKit update
        /// independent of a widget Keychain read while keeping remote agent
        /// payloads end-to-end encrypted.
        public struct RecentAgentDisplay: Codable, Hashable, Sendable {
            public var agent: String
            public var state: AgentState
            public var title: String
            public var detail: String
            public var updatedAt: Date

            public init(content: AgentActivity.Content) {
                let presentation = AgentActivity.Presentation(content: content)
                agent = content.agent
                state = content.state
                title = presentation.title
                detail = presentation.detail
                updatedAt = Date(timeIntervalSince1970: content.updatedAt)
            }

            var content: AgentActivity.Content {
                .init(
                    id: "local-presentation",
                    agent: agent,
                    state: state,
                    sessionName: title,
                    message: detail,
                    updatedAt: updatedAt.timeIntervalSince1970
                )
            }
        }

        public var totalRunning: Int
        /// Coding-agent aggregates. Optional-decoded so pushes from a relay
        /// that predates agent counts still parse (ActivityKit decodes
        /// content-state strictly otherwise).
        public var agentsRunning: Int
        public var agentsWaiting: Int
        public var agentsDone: Int
        public var recentAgentComputerID: String?
        public var recentAgentState: String?
        public var recentAgentUpdatedAt: Date?
        public var recentAgentSealed: String?
        public var recentAgentDisplay: RecentAgentDisplay?
        public var onlineComputerCount: Int
        public var offlineComputerCount: Int
        public var updatedAt: Date
        public var sequence: UInt64

        public init(
            totalRunning: Int,
            agentsRunning: Int = 0,
            agentsWaiting: Int = 0,
            agentsDone: Int = 0,
            recentAgentComputerID: String? = nil,
            recentAgentState: String? = nil,
            recentAgentUpdatedAt: Date? = nil,
            recentAgentSealed: String? = nil,
            recentAgentDisplay: RecentAgentDisplay? = nil,
            onlineComputerCount: Int,
            offlineComputerCount: Int,
            updatedAt: Date,
            sequence: UInt64
        ) {
            self.totalRunning = max(0, totalRunning)
            self.agentsRunning = max(0, agentsRunning)
            self.agentsWaiting = max(0, agentsWaiting)
            self.agentsDone = max(0, agentsDone)
            self.recentAgentComputerID = recentAgentComputerID
            self.recentAgentState = recentAgentState
            self.recentAgentUpdatedAt = recentAgentUpdatedAt
            self.recentAgentSealed = recentAgentSealed
            self.recentAgentDisplay = recentAgentDisplay
            self.onlineComputerCount = max(0, onlineComputerCount)
            self.offlineComputerCount = max(0, offlineComputerCount)
            self.updatedAt = updatedAt
            self.sequence = sequence
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                totalRunning: try container.decode(Int.self, forKey: .totalRunning),
                agentsRunning: try container.decodeIfPresent(Int.self, forKey: .agentsRunning) ?? 0,
                agentsWaiting: try container.decodeIfPresent(Int.self, forKey: .agentsWaiting) ?? 0,
                agentsDone: try container.decodeIfPresent(Int.self, forKey: .agentsDone) ?? 0,
                recentAgentComputerID: try container.decodeIfPresent(String.self, forKey: .recentAgentComputerID),
                recentAgentState: try container.decodeIfPresent(String.self, forKey: .recentAgentState),
                recentAgentUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .recentAgentUpdatedAt),
                recentAgentSealed: try container.decodeIfPresent(String.self, forKey: .recentAgentSealed),
                recentAgentDisplay: try container.decodeIfPresent(
                    RecentAgentDisplay.self, forKey: .recentAgentDisplay
                ),
                onlineComputerCount: try container.decode(Int.self, forKey: .onlineComputerCount),
                offlineComputerCount: try container.decode(Int.self, forKey: .offlineComputerCount),
                updatedAt: try container.decode(Date.self, forKey: .updatedAt),
                sequence: try container.decode(UInt64.self, forKey: .sequence)
            )
        }

        public init(snapshot: TTYStatusSnapshot) {
            self.init(
                totalRunning: snapshot.totalRunning,
                agentsRunning: snapshot.agentsRunning,
                agentsWaiting: snapshot.agentsWaiting,
                agentsDone: snapshot.agentsDone,
                onlineComputerCount: snapshot.onlineComputerCount,
                offlineComputerCount: snapshot.offlineComputerCount,
                updatedAt: snapshot.updatedAt,
                sequence: snapshot.sequence
            )
        }
    }

    /// One aggregate activity represents every computer bound to this client.
    public let scope: String

    public init(scope: String = "all") {
        self.scope = scope
    }
}

extension TTYActivityAttributes.ContentState {
    /// A nonzero aggregate is the authoritative switch between the agent and
    /// terminal presentations. Rich agent content is best-effort E2EE data and
    /// must never decide which presentation the user sees.
    var totalAgents: Int {
        agentsRunning + agentsWaiting + agentsDone
    }

    /// Counts shown beneath the concrete agent. The visible agent is already
    /// represented by its row, so only additional agents are counted. Offline
    /// computers are intentionally absent from this presentation.
    var activityCountSummary: String? {
        var parts: [String] = []
        let moreAgents = max(0, totalAgents - 1)
        if moreAgents > 0 {
            let noun = moreAgents == 1 ? "agent" : "agents"
            parts.append("and \(moreAgents) more \(noun)")
        }
        if totalRunning > 0 {
            let noun = totalRunning == 1 ? "terminal" : "terminals"
            parts.append("\(totalRunning) \(noun)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Prefer the state attached to the most recent encrypted agent envelope.
    /// If that envelope is temporarily absent or unreadable, keep the island
    /// in agent mode and fall back to the most attention-worthy aggregate.
    var displayedAgentState: AgentState? {
        guard totalAgents > 0 else { return nil }
        if let recentAgentDisplay {
            return recentAgentDisplay.state
        }
        if let recentAgentState, let state = AgentState(rawValue: recentAgentState) {
            return state
        }
        if agentsWaiting > 0 { return .waiting }
        if agentsDone > 0 { return .done }
        return .running
    }

    /// Home-originated foreground updates resolve from the compact display
    /// snapshot first. APNs updates do not contain it and continue through the
    /// per-computer E2EE envelope shared with the widget extension.
    var resolvedRecentAgent: AgentActivity.Content? {
        if let recentAgentDisplay {
            return recentAgentDisplay.content
        }
        guard let computerID = recentAgentComputerID,
              let sealedText = recentAgentSealed,
              let sealed = Data(base64Encoded: sealedText),
              let keyData = AgentActivityKeyStore.key(forComputer: computerID)
        else { return nil }
        return try? AgentActivity.open(
            sealed,
            key: SymmetricKey(data: keyData),
            computerID: computerID
        )
    }
}
