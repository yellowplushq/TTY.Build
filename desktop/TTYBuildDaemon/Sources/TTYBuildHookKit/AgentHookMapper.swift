import Darwin
import Foundation

/// Optional enrichment fields parsed from the stdin of Claude-hook-compatible
/// CLIs (codex, copilot, grok, kimi, kiro). The payload shape mirrors Claude
/// Code's flat hook JSON; every field is untrusted and optional — the argv
/// `--event` alone decides the mapped event.
struct ClaudeFlatStdin {
    var sessionId: String?
    var sessionName: String?
    /// Codex includes these fields only for thread-spawned subagents. They
    /// are internal child work, not user sessions, and must not become
    /// standalone TTYBuild rows or Live Activities.
    var isCodexSubagent = false
    var cwd: String?
    var transcriptPath: String?
    var prompt: String?
    var toolName: String?
    /// "ToolName: detail" one-liner from `tool_name` + `tool_input`, capped.
    var action: String?
    /// First non-empty of `message`, `last_assistant_message`,
    /// `assistant_response` (supacode's precedence), capped.
    var message: String?

    init(data: Data) {
        self.init(object: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    init(object: [String: Any]?) {
        guard let object else { return }
        if let id = object["session_id"] as? String, !id.isEmpty {
            sessionId = id
        }
        isCodexSubagent = ["agent_id", "agent_type"].contains {
            guard let value = object[$0] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        sessionName = hookSessionName(from: object)
        cwd = object["cwd"] as? String
        if let path = object["transcript_path"] as? String {
            let cleaned = sanitizeHookText(path, cap: HookFieldCaps.transcriptPath)
            if !cleaned.isEmpty { transcriptPath = cleaned }
        }
        if let prompt = object["prompt"] as? String {
            let cleaned = sanitizeHookText(prompt, cap: HookFieldCaps.prompt)
            if !cleaned.isEmpty { self.prompt = cleaned }
        }
        if let tool = object["tool_name"] as? String, !tool.isEmpty {
            toolName = tool
            let line = hookActionLine(tool: tool, input: object["tool_input"] as? [String: Any])
            let cleaned = sanitizeHookText(line, cap: HookFieldCaps.action)
            action = cleaned.isEmpty ? nil : cleaned
        }
        for key in ["message", "last_assistant_message", "assistant_response"] {
            guard let value = object[key] as? String else { continue }
            let cleaned = sanitizeHookText(value, cap: HookFieldCaps.message)
            if !cleaned.isEmpty {
                message = cleaned
                break
            }
        }
    }
}

/// Optional enrichment fields composed by OUR generated plugins (opencode,
/// omp, pi, hermes): flat JSON with camelCase keys. Untrusted like everything
/// else on stdin.
struct NormalizedStdin {
    var sessionId: String?
    var sessionName: String?
    var cwd: String?
    var message: String?
    var action: String?

    init(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        if let id = object["sessionId"] as? String, !id.isEmpty {
            sessionId = id
        }
        sessionName = hookSessionName(from: object)
        cwd = object["cwd"] as? String
        if let message = object["message"] as? String {
            let cleaned = sanitizeHookText(message, cap: HookFieldCaps.message)
            if !cleaned.isEmpty { self.message = cleaned }
        }
        if let action = object["action"] as? String {
            let cleaned = sanitizeHookText(action, cap: HookFieldCaps.action)
            if !cleaned.isEmpty { self.action = cleaned }
        }
    }
}

/// Maps a non-Claude agent hook invocation (`ttybuild-hook <slug> --event
/// <event>` plus optional stdin enrichment) onto the stable event vocabulary.
/// Unlike Claude, these agents name the event on argv — stdin only enriches.
/// Returns nil for unknown slugs/events; the reporter then exits silently.
public enum AgentHookMapper {
    /// Claude-hook-compatible-ish CLIs: stdin (when present) is flat
    /// Claude-shaped JSON.
    static let claudeFlatSlugs: Set<String> = ["codex", "copilot", "grok", "kimi", "kiro"]
    /// Agents driven by our generated plugins, which compose NormalizedStdin.
    static let normalizedSlugs: Set<String> = ["opencode", "omp", "pi", "hermes"]

    /// Every slug this mapper handles (`claude` is handled by
    /// ClaudeHookMapper and is not in this set).
    public static var slugs: Set<String> { claudeFlatSlugs.union(normalizedSlugs) }

    /// Wire vocabulary accepted on argv for the Claude-flat family.
    static let genericEvents: Set<String> = [
        "session-start", "prompt", "tool", "busy", "ask", "notify", "stop",
        "session-end",
    ]
    /// Our plugins emit turn starts as `busy` and never `prompt` (they have
    /// no prompt text source).
    static let normalizedEvents: Set<String> = [
        "session-start", "busy", "tool", "ask", "notify", "stop", "session-end",
    ]

    /// Copilot's notification hook only means "waiting for the user" for
    /// these payload types (supacode gates on exactly these two).
    static let copilotNotifyGates = ["permission_prompt", "elicitation_dialog"]

    public static func report(
        slug: String, event: String, stdinData: Data,
        fallbackSessionId: String? = nil,
        codexHome: URL? = nil,
        resolveCodexMetadata: Bool = true
    ) -> HookReport? {
        // Deterministic per agent process, so repeated events without a
        // stdin session id coalesce into one record.
        let fallback = fallbackSessionId ?? "\(slug)-\(getppid())"
        if claudeFlatSlugs.contains(slug) {
            if slug == "copilot", event == "notification" {
                return copilotNotification(stdinData: stdinData, fallbackSessionId: fallback)
            }
            guard genericEvents.contains(event) else { return nil }
            let stdin = ClaudeFlatStdin(data: stdinData)
            if slug == "codex", stdin.isCodexSubagent {
                return nil
            }
            let sessionID = stdin.sessionId ?? fallback
            let codexMetadata = slug == "codex" && resolveCodexMetadata
                ? CodexSessionMetadata.resolve(sessionID: sessionID, home: codexHome)
                : nil
            // Codex's hook `session_title` is often the animated terminal
            // title ("⠹ project"), not the persistent thread name. Prefer
            // Codex's own session index/state database whenever available.
            let sessionName = codexMetadata?.title ?? stdin.sessionName
            return genericReport(
                event: event, stdin: stdin,
                fallbackSessionId: fallback, sessionName: sessionName,
                transcriptPath: stdin.transcriptPath ?? codexMetadata?.transcriptPath
            )
        }
        if normalizedSlugs.contains(slug) {
            guard normalizedEvents.contains(event) else { return nil }
            return normalizedReport(
                event: event, stdin: NormalizedStdin(data: stdinData),
                fallbackSessionId: fallback
            )
        }
        return nil
    }

    /// Generic argv-event path: the event passes through as-is; stdin only
    /// fills the fields that event carries. No transcript probe and no
    /// `agentError` for these agents.
    static func genericReport(
        event: String, stdin: ClaudeFlatStdin, fallbackSessionId: String,
        sessionName: String? = nil, transcriptPath: String? = nil
    ) -> HookReport? {
        var report = HookReport(
            event: event, agentSessionId: stdin.sessionId ?? fallbackSessionId,
            sessionName: sessionName ?? stdin.sessionName, cwd: stdin.cwd,
            transcriptPath: transcriptPath ?? stdin.transcriptPath
        )
        switch event {
        case "prompt":
            report.prompt = stdin.prompt
        case "tool":
            // Mirror the Claude mapper: an ask-shaped tool means "waiting".
            if let tool = stdin.toolName, ClaudeHookMapper.askTools.contains(tool) {
                report.event = "ask"
            } else {
                report.action = stdin.action
            }
            report.message = stdin.message
        case "busy", "stop":
            report.message = stdin.message
        case "notify":
            report.message = stdin.message
            // grok/kimi are Claude forks with the same two Notification
            // triggers; classify so noise notifications cannot flip a
            // working agent to waiting.
            report.notifyKind = HookNotificationClassifier.classify(
                message: stdin.message
            )
        default:
            // session-start, ask, and session-end carry no text.
            break
        }
        return report
    }

    /// Copilot `--event notification`: only permission prompts and
    /// elicitation dialogs mean "waiting for the user". The gate reads the
    /// structured `type` field — a raw substring search over the whole
    /// payload would pass any notification whose free text merely mentions a
    /// gated type. Payloads without a `type` fall back to message
    /// classification; everything else (welcome toasts, update notes, …) is
    /// dropped.
    static func copilotNotification(
        stdinData: Data, fallbackSessionId: String
    ) -> HookReport? {
        let object = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any]
        let stdin = ClaudeFlatStdin(object: object)
        let notifyKind: String
        if let type = object?["type"] as? String, !type.isEmpty {
            guard copilotNotifyGates.contains(type) else { return nil }
            notifyKind = HookNotificationClassifier.permission
        } else {
            notifyKind = HookNotificationClassifier.classify(message: stdin.message)
            guard notifyKind != HookNotificationClassifier.other else { return nil }
        }
        return HookReport(
            event: "notify", agentSessionId: stdin.sessionId ?? fallbackSessionId,
            sessionName: stdin.sessionName, cwd: stdin.cwd, message: stdin.message,
            notifyKind: notifyKind
        )
    }

    /// Normalized-plugin path: fields pass through as provided (per event).
    static func normalizedReport(
        event: String, stdin: NormalizedStdin, fallbackSessionId: String
    ) -> HookReport? {
        var report = HookReport(
            event: event, agentSessionId: stdin.sessionId ?? fallbackSessionId,
            sessionName: stdin.sessionName, cwd: stdin.cwd
        )
        switch event {
        case "tool":
            report.action = stdin.action
            report.message = stdin.message
        case "busy", "ask", "stop":
            report.message = stdin.message
        case "notify":
            report.message = stdin.message
            // Our generated plugins only emit notify for deliberate input
            // requests, never for ambient host notifications.
            report.notifyKind = HookNotificationClassifier.permission
        default:
            break // session-start and session-end carry no text
        }
        return report
    }
}
