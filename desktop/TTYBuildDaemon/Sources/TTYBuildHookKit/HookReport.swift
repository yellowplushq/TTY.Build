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
    /// `notify` only: what the notification payload actually means —
    /// `permission` (approval prompt), `idle` (unattended-input reminder), or
    /// `other`. The daemon only treats the first two as "waiting for the
    /// user"; hosts fire notification hooks for plenty of things that are not
    /// input requests, and those must not flip a working agent to waiting.
    public var notifyKind: String?

    public init(
        event: String, agentSessionId: String, sessionName: String? = nil,
        cwd: String? = nil,
        prompt: String? = nil, message: String? = nil, action: String? = nil,
        transcriptPath: String? = nil,
        agentError: Bool? = nil,
        notifyKind: String? = nil
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
        self.notifyKind = notifyKind
    }
}

/// Classifies a notification hook payload into the daemon's `notifyKind`
/// vocabulary. Claude Code documents exactly two Notification triggers —
/// permission requests and the 60 s idle reminder — and the Claude-fork CLIs
/// (grok, kimi) inherit the same phrasing, so matching is on wording
/// fragments that survive rebranding (no agent name).
public enum HookNotificationClassifier {
    public static let permission = "permission"
    public static let idle = "idle"
    public static let other = "other"

    public static func classify(message: String?) -> String {
        guard let message, !message.isEmpty else { return other }
        let lowered = message.lowercased()
        if lowered.contains("permission") || lowered.contains("approval")
            || lowered.contains("needs your input")
        {
            return permission
        }
        if lowered.contains("waiting for your input")
            || lowered.contains("waiting for input")
            || lowered.contains("is waiting")
        {
            return idle
        }
        return other
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
    // empty lets the monitor keep showing the latest conversational detail.
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
