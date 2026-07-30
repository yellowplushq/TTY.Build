import Foundation

/// One mapped hook event, ready for wire encoding (PROTOCOL.md §7
/// `agent-event`). Field caps are applied here and re-applied by the daemon:
/// both ends defend independently.
public struct HookReport: Equatable, Sendable {
    /// Stable event vocabulary: `session-start`, `prompt`, `ask`, `tool`,
    /// `busy`, `notify`, `compact`, `stop`, `session-end`.
    public var event: String
    /// The agent's own session id (Claude Code `session_id`).
    public var agentSessionId: String
    /// Optional user-facing name supplied by the agent hook.
    public var sessionName: String?
    public var cwd: String?
    /// The user's prompt text (`prompt` events only), capped.
    public var prompt: String?
    /// The agent's last message (`notify`/`stop`), capped.
    public var message: String?
    /// One-line current action (`tool` events only), capped.
    public var action: String?
    /// Local JSONL transcript used for best-effort, low-frequency refreshes
    /// while the agent is working. The daemon validates it against the
    /// agent's own config directory before reading.
    public var transcriptPath: String?
    /// `stop` only: the turn ended on an agent-side failure (API error).
    public var agentError: Bool?

    public init(
        event: String, agentSessionId: String, sessionName: String? = nil,
        cwd: String? = nil,
        prompt: String? = nil, message: String? = nil, action: String? = nil,
        transcriptPath: String? = nil,
        agentError: Bool? = nil
    ) {
        self.event = event
        self.agentSessionId = agentSessionId
        self.sessionName = sessionName
        self.cwd = cwd
        self.prompt = prompt
        self.message = message
        self.action = action
        self.transcriptPath = transcriptPath
        self.agentError = agentError
    }
}

/// Shared field caps, applied by every mapper; the daemon re-applies the same
/// caps on ingest.
enum HookFieldCaps {
    static let prompt = 200
    static let action = 120
    static let message = 300
    static let sessionName = 120
    static let transcriptPath = 4096
}

/// Session-name fields used by agent hook payloads. A generic notification
/// `title` is intentionally excluded: it describes the event, not the
/// persistent session identity.
func hookSessionName(from object: [String: Any]) -> String? {
    for key in ["session_name", "session_title", "sessionName", "sessionTitle"] {
        guard let value = object[key] as? String else { continue }
        let cleaned = sanitizeHookText(value, cap: HookFieldCaps.sessionName)
        if !cleaned.isEmpty { return cleaned }
    }
    return nil
}

/// "ToolName: detail" one-liner shared by all Claude-shaped mappers: detail is
/// the first useful command/query, else the last component of a file path.
func hookActionLine(tool: String, input: [String: Any]?) -> String {
    var detail = ""
    if let command = (input?["command"] ?? input?["cmd"]) as? String {
        detail = command
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    } else if let path = (input?["file_path"] ?? input?["path"]) as? String,
              !path.isEmpty
    {
        detail = (path as NSString).lastPathComponent
    } else if let query = (input?["query"] ?? input?["pattern"]) as? String {
        detail = query
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    }
    detail = detail.trimmingCharacters(in: .whitespaces)
    if tool.isEmpty { return detail }
    // A bare tool name is not meaningful user-facing progress. Returning
    // empty lets the monitor keep showing the last agent message.
    return detail.isEmpty ? "" : "\(tool): \(detail)"
}

/// Shared field hygiene: strips C0 controls (and DEL) and caps length. The
/// daemon applies the same treatment again on ingest.
func sanitizeHookText(_ value: String, cap: Int) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
        if out.count >= cap { break }
        if scalar.value < 0x20 || scalar.value == 0x7F {
            out.append(" ")
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}
