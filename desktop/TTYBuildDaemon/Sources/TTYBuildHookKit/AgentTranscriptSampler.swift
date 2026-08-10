import Foundation

/// The newest agent-authored message (and, for Claude, session title) in a
/// running transcript.
public struct AgentTranscriptActivity: Equatable, Sendable {
    public var detail: String?
    /// Claude's own title for the session. The hook payloads carry only
    /// user-set custom titles, so the AI-generated title is recoverable from
    /// transcript lines alone.
    public var sessionTitle: String?

    public init(detail: String? = nil, sessionTitle: String? = nil) {
        self.detail = detail
        self.sessionTitle = sessionTitle
    }
}

/// Best-effort, bounded sampling for the two agents whose local transcript
/// formats and roots are known. Hook events remain the source of truth for
/// state transitions; this only keeps a running row's detail fresh between
/// those edges.
public enum AgentTranscriptSampler {
    public static func latestActivity(
        agent: String,
        path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) -> AgentTranscriptActivity? {
        guard isAllowedPath(
            agent: agent, path: path, environment: environment, home: home
        ) else { return nil }
        let lines = TranscriptTail.tailLines(path: path)
        switch agent {
        case "claude":
            return latestClaudeActivity(lines)
        case "codex":
            return latestCodexActivity(lines)
        default:
            return nil
        }
    }

    /// The local socket is user-only, but transcript paths are still
    /// untrusted input. Resolve symlinks and only read JSONL below the
    /// corresponding agent's own config directory.
    static func isAllowedPath(
        agent: String,
        path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home explicitHome: URL? = nil
    ) -> Bool {
        guard !path.isEmpty,
              URL(fileURLWithPath: path).pathExtension.lowercased() == "jsonl"
        else { return false }

        let home = explicitHome ?? FileManager.default.homeDirectoryForCurrentUser
        let root: URL
        switch agent {
        case "claude":
            if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
                root = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                root = home.appendingPathComponent(".claude", isDirectory: true)
            }
        case "codex":
            if let configured = environment["CODEX_HOME"], !configured.isEmpty {
                root = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                root = home.appendingPathComponent(".codex", isDirectory: true)
            }
        default:
            return false
        }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private static func latestClaudeActivity(
        _ lines: [Data]
    ) -> AgentTranscriptActivity? {
        var detail: String?
        var titles = ClaudeTranscriptTitles()
        for line in lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            titles.take(object)
            guard
                object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [Any]
            else { continue }

            let text = content.compactMap { item -> String? in
                guard let part = item as? [String: Any],
                      part["type"] as? String == "text"
                else { return nil }
                return part["text"] as? String
            }.joined()
            if let text = cleaned(text, cap: HookFieldCaps.message) {
                detail = text
            }
        }
        guard detail != nil || titles.best != nil else { return nil }
        return AgentTranscriptActivity(detail: detail, sessionTitle: titles.best)
    }

    private static func latestCodexActivity(
        _ lines: [Data]
    ) -> AgentTranscriptActivity? {
        var latest: AgentTranscriptActivity?
        for line in lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let outerType = object["type"] as? String,
                let payload = object["payload"] as? [String: Any],
                let type = payload["type"] as? String
            else { continue }

            if outerType == "event_msg", type == "agent_message",
               let message = cleaned(
                   payload["message"] as? String, cap: HookFieldCaps.message
               )
            {
                latest = AgentTranscriptActivity(detail: message)
                continue
            }
            guard outerType == "response_item" else { continue }
            switch type {
            case "message":
                guard payload["role"] as? String == "assistant",
                      let content = payload["content"] as? [Any]
                else { continue }
                let text = content.compactMap { item -> String? in
                    guard let part = item as? [String: Any],
                          part["type"] as? String == "output_text"
                    else { return nil }
                    return part["text"] as? String
                }.joined()
                if let text = cleaned(text, cap: HookFieldCaps.message) {
                    latest = AgentTranscriptActivity(detail: text)
                }
            default:
                break
            }
        }
        return latest
    }

    private static func cleaned(_ value: String?, cap: Int) -> String? {
        guard let value else { return nil }
        let result = sanitizeHookText(value, cap: cap)
        return result.isEmpty ? nil : result
    }
}
