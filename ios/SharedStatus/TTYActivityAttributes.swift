import ActivityKit
import CryptoKit
import Foundation
import TTYBuildKit

public struct TTYActivityAttributes: ActivityAttributes, Codable, Hashable, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// A compact, on-device-only copy of the exact presentation Home
        /// already resolved. It makes a foreground ActivityKit update
        /// independent of a widget Keychain read while keeping remote agent
        /// payloads end-to-end encrypted.
        public struct RecentAgentDisplay: Codable, Hashable, Sendable {
            /// The resolved presentation of the next-most-recent agent, so the
            /// island's second row also survives foreground updates without a
            /// Keychain read. Optional-decoded for states written before the
            /// second row existed.
            public struct Second: Codable, Hashable, Sendable {
                public var agent: String
                public var state: AgentState
                public var title: String
                public var detail: String
                public var updatedAt: Date

                public init(companion: AgentActivity.Companion) {
                    let presentation = AgentActivity.Presentation(companion: companion)
                    agent = companion.agent
                    state = companion.state
                    title = presentation.title
                    detail = presentation.detail
                    updatedAt = Date(timeIntervalSince1970: companion.updatedAt)
                }

                var companion: AgentActivity.Companion {
                    .init(
                        id: "local-second",
                        agent: agent,
                        state: state,
                        sessionName: title,
                        message: detail,
                        updatedAt: updatedAt.timeIntervalSince1970
                    )
                }
            }

            public var agent: String
            public var state: AgentState
            public var title: String
            public var detail: String
            public var updatedAt: Date
            public var second: Second?

            public init(content: AgentActivity.Content) {
                let presentation = AgentActivity.Presentation(content: content)
                agent = content.agent
                state = content.state
                title = presentation.title
                detail = presentation.detail
                updatedAt = Date(timeIntervalSince1970: content.updatedAt)
                second = content.second.map(Second.init(companion:))
            }

            var content: AgentActivity.Content {
                .init(
                    id: "local-presentation",
                    agent: agent,
                    state: state,
                    sessionName: title,
                    message: detail,
                    updatedAt: updatedAt.timeIntervalSince1970,
                    second: second?.companion
                )
            }
        }

        /// One additional per-computer E2EE envelope riding along with the
        /// primary `recentAgentSealed` card, so the expanded island can rank
        /// agent rows across computers the way Home does. Optional-decoded:
        /// pushes from an older relay simply omit it.
        public struct MoreAgent: Codable, Hashable, Sendable {
            public var computerID: String
            public var state: String?
            public var updatedAt: Date?
            public var sealed: String

            public init(
                computerID: String,
                state: String? = nil,
                updatedAt: Date? = nil,
                sealed: String
            ) {
                self.computerID = computerID
                self.state = state
                self.updatedAt = updatedAt
                self.sealed = sealed
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
        public var moreAgents: [MoreAgent]?
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
            moreAgents: [MoreAgent]? = nil,
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
            self.moreAgents = moreAgents
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
                moreAgents: try container.decodeIfPresent(
                    [MoreAgent].self, forKey: .moreAgents
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
                recentAgentComputerID: snapshot.recentAgent?.computerID,
                recentAgentState: snapshot.recentAgent?.state,
                recentAgentUpdatedAt: snapshot.recentAgent?.updatedAt,
                recentAgentSealed: snapshot.recentAgent?.sealed,
                moreAgents: snapshot.moreAgents?.map { envelope in
                    MoreAgent(
                        computerID: envelope.computerID,
                        state: envelope.state,
                        updatedAt: envelope.updatedAt,
                        sealed: envelope.sealed
                    )
                },
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

    /// Counts shown beneath the concrete agent rows. Agents already shown as
    /// rows are excluded, so the summary only counts what the card could not
    /// fit. Offline computers are intentionally absent from this presentation.
    func activityCountSummary(visibleAgents: Int = 1) -> String? {
        var parts: [String] = []
        let moreAgents = max(0, totalAgents - visibleAgents)
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
        return decryptedContent(
            computerID: recentAgentComputerID, sealedText: recentAgentSealed
        )
    }

    /// One concrete agent row of the expanded card, already resolved to
    /// display strings so the widget never touches envelope internals.
    struct ResolvedAgentRow: Equatable {
        var slug: String
        var state: AgentState
        var title: String
        var detail: String
        var updatedAt: Date
    }

    /// The expanded card's concrete rows: every agent across the primary
    /// envelope and any `moreAgents` companions, newest first — the same
    /// ranking Home shows. Foreground display snapshots already ranked
    /// across computers and are used as-is. The count aggregate stays
    /// authoritative: rows never exceed `totalAgents`, so a stale envelope
    /// cannot show an agent the counts say is gone.
    var resolvedAgentRows: [ResolvedAgentRow] {
        guard totalAgents > 0 else { return [] }
        var rows: [ResolvedAgentRow] = []
        func append(_ content: AgentActivity.Content) {
            let presentation = AgentActivity.Presentation(content: content)
            rows.append(ResolvedAgentRow(
                slug: content.agent,
                state: content.state,
                title: presentation.title,
                detail: presentation.detail,
                updatedAt: Date(timeIntervalSince1970: content.updatedAt)
            ))
            if let second = content.second {
                let secondPresentation = AgentActivity.Presentation(companion: second)
                rows.append(ResolvedAgentRow(
                    slug: second.agent,
                    state: second.state,
                    title: secondPresentation.title,
                    detail: secondPresentation.detail,
                    updatedAt: Date(timeIntervalSince1970: second.updatedAt)
                ))
            }
        }
        if let recentAgentDisplay {
            append(recentAgentDisplay.content)
        } else {
            if let primary = decryptedContent(
                computerID: recentAgentComputerID, sealedText: recentAgentSealed
            ) {
                append(primary)
            }
            for envelope in moreAgents ?? [] {
                if let content = decryptedContent(
                    computerID: envelope.computerID, sealedText: envelope.sealed
                ) {
                    append(content)
                }
            }
            rows.sort { $0.updatedAt > $1.updatedAt }
        }
        return Array(rows.prefix(min(2, totalAgents)))
    }

    private func decryptedContent(
        computerID: String?, sealedText: String?
    ) -> AgentActivity.Content? {
        guard let computerID,
              let sealedText,
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
