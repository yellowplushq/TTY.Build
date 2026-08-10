import CryptoKit
import Foundation

/// Rich coding-agent state embedded in the aggregate TTYBuild Live Activity.
///
/// The Worker receives only a server-visible state, timestamp, and opaque
/// ciphertext. Agent identity, session name, project, prompt, action, and
/// message remain encrypted from the daemon to the widget extension. The
/// payload is kept deliberately small because ActivityKit caps ContentState
/// at 4 KiB.
public enum AgentActivity {
    public enum Attention: String, Codable, CaseIterable, Sendable {
        case waiting
        case error
        case done
    }

    /// A trimmed snapshot of one additional agent, nested inside `Content`
    /// so a single sealed envelope can carry the island's second row. Kept
    /// to display-relevant fields only — the second row never shows tool
    /// activity or terminal identity, and the envelope must stay small.
    public struct Companion: Codable, Equatable, Sendable {
        public var id: String
        public var agent: String
        public var state: AgentState
        public var sessionName: String?
        public var project: String?
        public var prompt: String?
        public var message: String?
        public var updatedAt: Double

        public init(
            id: String,
            agent: String,
            state: AgentState,
            sessionName: String? = nil,
            project: String? = nil,
            prompt: String? = nil,
            message: String? = nil,
            updatedAt: Double
        ) {
            self.id = id
            self.agent = agent
            self.state = state
            self.sessionName = sessionName
            self.project = project
            self.prompt = prompt
            self.message = message
            self.updatedAt = updatedAt
        }

        public init(info: AgentInfo) {
            self.init(
                id: info.id,
                agent: info.agent,
                state: info.state,
                sessionName: info.sessionName.map { Content.singleLine($0, limit: 80) },
                project: Content.projectName(from: info.cwd),
                prompt: info.prompt.map { Content.singleLine($0, limit: 64) },
                message: info.message.map { Content.singleLine($0, limit: 100) },
                updatedAt: info.updatedAt
            )
        }

        /// `Content.trimmed(scale:)` for the nested row: free text shrinks
        /// with `scale`, identity fields stay hard-capped.
        fileprivate func trimmed(scale: Double) -> Companion {
            var copy = self
            copy.id = Content.singleLine(id, limit: 64)
            copy.agent = Content.singleLine(agent, limit: 32)
            copy.sessionName = Content.scaledLine(sessionName, base: 80, scale: scale)
            copy.project = Content.scaledLine(project, base: 64, scale: scale)
            copy.prompt = Content.scaledLine(prompt, base: 64, scale: scale)
            copy.message = Content.scaledLine(message, base: 100, scale: scale)
            return copy
        }
    }

    public struct Content: Codable, Equatable, Sendable {
        public var id: String
        public var agent: String
        public var state: AgentState
        public var sessionName: String?
        public var project: String?
        public var prompt: String?
        public var action: String?
        public var message: String?
        public var sessionId: Int?
        public var terminal: String?
        public var updatedAt: Double
        /// The next-most-recently-updated agent on the same reporting path.
        /// Optional on the wire: envelopes from older daemons decode with no
        /// second row, and older widgets ignore the key entirely.
        public var second: Companion?

        public init(
            id: String,
            agent: String,
            state: AgentState,
            sessionName: String? = nil,
            project: String? = nil,
            prompt: String? = nil,
            action: String? = nil,
            message: String? = nil,
            sessionId: Int? = nil,
            terminal: String? = nil,
            updatedAt: Double,
            second: Companion? = nil
        ) {
            self.id = id
            self.agent = agent
            self.state = state
            self.sessionName = sessionName
            self.project = project
            self.prompt = prompt
            self.action = action
            self.message = message
            self.sessionId = sessionId
            self.terminal = terminal
            self.updatedAt = updatedAt
            self.second = second
        }

        public init(info: AgentInfo) {
            self.init(
                id: info.id,
                agent: info.agent,
                state: info.state,
                sessionName: info.sessionName.map { Self.singleLine($0, limit: 80) },
                project: Self.projectName(from: info.cwd),
                prompt: info.prompt.map { Self.singleLine($0, limit: 100) },
                action: info.action.map { Self.singleLine($0, limit: 80) },
                message: info.message.map { Self.singleLine($0, limit: 140) },
                sessionId: info.sessionId,
                terminal: info.term.map { Self.singleLine($0, limit: 32) },
                updatedAt: info.updatedAt
            )
        }

        /// A copy with every free-text field re-truncated to `scale` of its
        /// standard budget and identity fields hard-capped. At `scale` 0 only
        /// the structural fields remain, whose JSON — even fully escaped —
        /// stays far below the envelope budget, which is what lets
        /// `sealWithinBudget` guarantee both agent rows always fit.
        fileprivate func trimmed(scale: Double) -> Content {
            var copy = self
            copy.id = Self.singleLine(id, limit: 64)
            copy.agent = Self.singleLine(agent, limit: 32)
            copy.sessionName = Self.scaledLine(sessionName, base: 80, scale: scale)
            copy.project = Self.scaledLine(project, base: 64, scale: scale)
            copy.prompt = Self.scaledLine(prompt, base: 100, scale: scale)
            copy.action = Self.scaledLine(action, base: 80, scale: scale)
            copy.message = Self.scaledLine(message, base: 140, scale: scale)
            copy.terminal = terminal.map { Self.singleLine($0, limit: 32) }
            copy.second = second?.trimmed(scale: scale)
            return copy
        }

        fileprivate static func scaledLine(
            _ value: String?, base: Int, scale: Double
        ) -> String? {
            guard let value else { return nil }
            let limit = Int(Double(base) * scale)
            guard limit > 0 else { return nil }
            let line = singleLine(value, limit: limit)
            return line.isEmpty ? nil : line
        }

        fileprivate static func projectName(from path: String) -> String? {
            guard !path.isEmpty else { return nil }
            return singleLine((path as NSString).lastPathComponent, limit: 64)
        }

        fileprivate static func singleLine(_ value: String, limit: Int) -> String {
            let normalized = value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            var result = String(normalized.prefix(limit))
            while result.utf8.count > limit {
                result.removeLast()
            }
            return result
        }
    }

    /// Shared display semantics for every agent surface. The monitor clears
    /// `message` when a newer user prompt arrives, so preferring `message`
    /// here selects the newest user-or-agent conversational message. Agent
    /// brand and state remain separate visual information; implementation-
    /// level tool activity is never displayed.
    public struct Presentation: Equatable, Sendable {
        public var title: String
        public var detail: String

        public init(info: AgentInfo, fallbackSessionName: String? = nil) {
            self.init(
                agent: info.agent,
                state: info.state,
                sessionName: info.sessionName ?? fallbackSessionName,
                project: AgentActivity.projectName(from: info.cwd),
                prompt: info.prompt,
                message: info.message
            )
        }

        public init(content: Content) {
            self.init(
                agent: content.agent,
                state: content.state,
                sessionName: content.sessionName,
                project: content.project,
                prompt: content.prompt,
                message: content.message
            )
        }

        public init(companion: Companion) {
            self.init(
                agent: companion.agent,
                state: companion.state,
                sessionName: companion.sessionName,
                project: companion.project,
                prompt: companion.prompt,
                message: companion.message
            )
        }

        private init(
            agent: String,
            state: AgentState,
            sessionName: String?,
            project: String?,
            prompt: String?,
            message: String?
        ) {
            title = AgentActivity.displayLine(sessionName)
                ?? AgentActivity.displayLine(project)
                ?? AgentActivity.displayName(forAgent: agent)

            let latestMessage = AgentActivity.displayLine(message)
            let latestPrompt = AgentActivity.displayLine(prompt)
            switch state {
            case .running:
                detail = latestMessage ?? latestPrompt ?? "Working…"
            case .waiting:
                detail = latestMessage ?? latestPrompt ?? "Waiting for your input"
            case .error:
                detail = latestMessage ?? latestPrompt ?? "Agent hit an error"
            case .done:
                detail = latestMessage ?? latestPrompt ?? "Task completed"
            }
        }
    }

    /// A dedicated key means access granted to the widget extension never
    /// exposes either relay traffic direction or the pairing secret itself.
    public static func activityKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: KeyDerivation.salt,
            info: Data("live-activity".utf8),
            outputByteCount: KeyDerivation.keyByteCount
        )
    }

    public static func seal(
        _ content: Content, key: SymmetricKey, computerID: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(content)
        let box = try ChaChaPoly.seal(
            plaintext, using: key, authenticating: Data(computerID.utf8)
        )
        return box.combined
    }

    /// Seals `content` guaranteed within `budget`, keeping both agent rows.
    /// Free text (session names, prompts, messages) is progressively
    /// re-truncated until the envelope fits; the final structural-only scale
    /// is mathematically below the budget, so unlike a drop-the-second-row
    /// fallback this never degrades the row count.
    public static func sealWithinBudget(
        _ content: Content,
        key: SymmetricKey,
        computerID: String,
        budget: Int = RelayMetadata.AgentActivityEnvelope.targetSealedBytes
    ) throws -> Data {
        for scale in [1.0, 0.7, 0.45, 0.25] {
            let sealed = try seal(
                content.trimmed(scale: scale), key: key, computerID: computerID
            )
            if sealed.count <= budget { return sealed }
        }
        // Structural fields only: id, agent, state, timestamps. Their JSON is
        // bounded (hard caps above) far below any sane budget.
        return try seal(
            content.trimmed(scale: 0), key: key, computerID: computerID
        )
    }

    public static func open(
        _ sealed: Data, key: SymmetricKey, computerID: String
    ) throws -> Content {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plaintext = try ChaChaPoly.open(
            box, using: key, authenticating: Data(computerID.utf8)
        )
        return try JSONDecoder().decode(Content.self, from: plaintext)
    }

    public static func displayName(forAgent slug: String) -> String {
        switch slug {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "copilot": "Copilot CLI"
        case "grok": "Grok"
        case "hermes": "Hermes"
        case "kimi": "Kimi Code"
        case "kiro": "Kiro"
        case "omp": "Oh My Pi"
        case "opencode": "OpenCode"
        case "pi": "Pi"
        default: slug.capitalized
        }
    }

    private static func projectName(from path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return displayLine((path as NSString).lastPathComponent)
    }

    private static func displayLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
