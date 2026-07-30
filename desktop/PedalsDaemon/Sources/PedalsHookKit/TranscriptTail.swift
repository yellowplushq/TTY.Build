import Foundation

/// What a Stop-time transcript scan learned about the just-ended turn.
public struct TranscriptSummary: Equatable, Sendable {
    /// Concatenated text of the last assistant message, capped and stripped.
    public var lastMessage: String?
    /// The turn died on an API error (no later user/assistant line followed).
    public var isError: Bool
    /// Claude's own session title (custom over AI-generated); hook payloads
    /// only carry user-set custom titles, so this is the sole source for the
    /// usual AI-generated one.
    public var sessionTitle: String?

    public init(
        lastMessage: String? = nil, isError: Bool = false,
        sessionTitle: String? = nil
    ) {
        self.lastMessage = lastMessage
        self.isError = isError
        self.sessionTitle = sessionTitle
    }
}

/// Claude session-title transcript lines. The newest custom title outranks
/// the newest AI title, mirroring Claude's own session-resume logic.
struct ClaudeTranscriptTitles {
    private var custom: String?
    private var ai: String?

    var best: String? { custom ?? ai }

    mutating func take(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "custom-title":
            if let title = Self.cleaned(object["customTitle"]) { custom = title }
        case "ai-title":
            if let title = Self.cleaned(object["aiTitle"]) { ai = title }
        default:
            break
        }
    }

    private static func cleaned(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = sanitizeHookText(value, cap: HookFieldCaps.sessionName)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Tail scan of a Claude Code transcript (JSONL). Only the last 256 KiB are
/// read; any parse failure degrades to no-message/no-error — the scan must
/// never invent a spurious error.
public enum TranscriptTail {
    public static let tailLimit = 256 * 1024

    public static func scan(path: String, sessionId: String) -> TranscriptSummary {
        let lines = tailLines(path: path)
        guard !lines.isEmpty else { return TranscriptSummary() }

        var lastMessage: String?
        var isError = false
        var titles = ClaudeTranscriptTitles()
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            let type = object["type"] as? String
            if (object["isApiErrorMessage"] as? Bool) == true {
                // A dead turn ends on the error line; a recovered turn has
                // later user/assistant traffic that clears the flag below.
                if object["sessionId"] as? String == sessionId { isError = true }
            } else if type == "user" || type == "assistant" {
                isError = false
            }
            if type == "assistant", let text = assistantText(object), !text.isEmpty {
                lastMessage = text
            }
            titles.take(object)
        }
        return TranscriptSummary(
            lastMessage: lastMessage, isError: isError, sessionTitle: titles.best
        )
    }

    /// Shared bounded JSONL reader for stop-time summaries and live sampling.
    /// Returning independent Data values avoids retaining the entire tail
    /// buffer after parsing.
    static func tailLines(path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return []
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return [] }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        // A mid-file start almost certainly landed inside a line; drop it.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map { Data($0) }
    }

    /// Concatenated `message.content[].text` parts of an assistant line.
    private static func assistantText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else { return nil }
        let text = content.compactMap { item -> String? in
            guard let part = item as? [String: Any],
                  part["type"] as? String == "text"
            else { return nil }
            return part["text"] as? String
        }.joined(separator: " ")
        let cleaned = sanitizeHookText(text, cap: HookFieldCaps.message)
        return cleaned.isEmpty ? nil : cleaned
    }
}
