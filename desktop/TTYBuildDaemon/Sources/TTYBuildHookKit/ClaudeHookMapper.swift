import Foundation

/// Maps a Claude Code hook invocation (its stdin JSON) onto the daemon's
/// stable event vocabulary. The per-agent adapter is deliberately thin: this
/// mapping is the only Claude-specific knowledge in the reporter
/// (docs/AGENT_MONITORING_DESIGN.md §3).
public enum ClaudeHookMapper {
    /// PreToolUse tools that mean "the agent is waiting for the user".
    static let askTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Parses hook stdin JSON and maps the event. Returns nil for unknown or
    /// malformed events; the reporter then exits silently.
    public static func report(stdinData: Data) -> HookReport? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any],
            let eventName = object["hook_event_name"] as? String,
            let sessionId = object["session_id"] as? String, !sessionId.isEmpty
        else { return nil }

        var report = HookReport(
            event: "", agentSessionId: sessionId,
            sessionName: hookSessionName(from: object),
            cwd: object["cwd"] as? String,
            transcriptPath: (object["transcript_path"] as? String).flatMap {
                let path = sanitizeHookText($0, cap: HookFieldCaps.transcriptPath)
                return path.isEmpty ? nil : path
            }
        )
        switch eventName {
        case "SessionStart":
            report.event = "session-start"
        case "UserPromptSubmit":
            report.event = "prompt"
            report.prompt = (object["prompt"] as? String).map {
                sanitizeHookText($0, cap: HookFieldCaps.prompt)
            }
        case "PreToolUse":
            let tool = object["tool_name"] as? String ?? ""
            if askTools.contains(tool) {
                report.event = "ask"
            } else {
                report.event = "tool"
                let line = hookActionLine(tool: tool, input: object["tool_input"] as? [String: Any])
                let action = sanitizeHookText(line, cap: HookFieldCaps.action)
                report.action = action.isEmpty ? nil : action
            }
        case "Notification":
            // Claude fires Notification for more than input requests. Only a
            // permission prompt or the idle reminder means "waiting for the
            // user"; anything else is dropped here like an unknown event —
            // noise must not flip a working agent to waiting (or even bump
            // its row). Prefer the structured type when the host provides
            // one; fall back to classifying the human-readable message.
            report.event = "notify"
            report.message = (object["message"] as? String).map {
                sanitizeHookText($0, cap: HookFieldCaps.message)
            }
            let kind: HookNotificationClassifier.Kind
            if let type = object["notification_type"] as? String, !type.isEmpty {
                kind = Self.notifyKind(fromType: type)
            } else {
                kind = HookNotificationClassifier.classify(message: report.message)
            }
            guard kind.isInputRequest else { return nil }
        case "PreCompact":
            report.event = "compact"
        case "Stop":
            report.event = "stop"
            // Claude appends the final assistant message to the transcript
            // only after this hook runs, so a transcript scan reliably sees
            // the previous message. The stdin field is taken from the
            // in-memory turn and is the only source that has the real one;
            // the scan stays as the message fallback for older Claude builds
            // and as the sole error-flag source either way.
            let stdinMessage = (object["last_assistant_message"] as? String)
                .flatMap { value -> String? in
                    let cleaned = sanitizeHookText(value, cap: HookFieldCaps.message)
                    return cleaned.isEmpty ? nil : cleaned
                }
            if let path = report.transcriptPath {
                let summary = TranscriptTail.scan(path: path, sessionId: sessionId)
                report.message = stdinMessage ?? summary.lastMessage
                report.agentError = summary.isError
                // The stdin `session_title` (a user-set custom title) wins;
                // the AI-generated title only exists as transcript lines.
                if report.sessionName == nil {
                    report.sessionName = summary.sessionTitle
                }
            } else {
                report.message = stdinMessage
                report.agentError = false
            }
        case "SessionEnd":
            report.event = "session-end"
        default:
            return nil
        }
        return report
    }

    /// Newer Claude builds carry `notification_type` on Notification stdin;
    /// an explicit non-input type wins over permission-looking message text.
    static func notifyKind(fromType type: String) -> HookNotificationClassifier.Kind {
        switch type.lowercased() {
        case "permission_request", "permission_prompt", "permission":
            .permission
        case "idle", "idle_prompt", "waiting_for_input":
            .idle
        default:
            .other
        }
    }
}
