import Foundation

/// Builds the one-line `agent-event` control request (PROTOCOL.md §7) the
/// reporter writes to the daemon's local socket.
public enum HookWire {
    public static func requestLine(
        agent: String, report: HookReport, lineage: [LineageEntry],
        seq: UInt64? = nil, agentPid: pid_t? = nil
    ) -> Data? {
        var object: [String: Any] = [
            "cmd": "agent-event",
            "noReply": true,
            "agent": agent,
            "event": report.event,
            "agentSessionId": report.agentSessionId,
        ]
        // Machine-wide monotonic capture time: the daemon drops events that
        // arrive behind a newer report for the same session (hook processes
        // race each other; arrival order is not event order).
        if let seq { object["seq"] = NSNumber(value: seq) }
        // The reporter's own identification of the agent ancestor; stronger
        // than the daemon's first-non-shell guess.
        if let agentPid, agentPid > 0 { object["agentPid"] = Int(agentPid) }
        if let sessionName = report.sessionName { object["sessionName"] = sessionName }
        if let cwd = report.cwd { object["cwd"] = cwd }
        if let prompt = report.prompt { object["prompt"] = prompt }
        if let message = report.message { object["message"] = message }
        if let action = report.action { object["action"] = action }
        if let transcriptPath = report.transcriptPath {
            object["transcriptPath"] = transcriptPath
        }
        if let agentError = report.agentError { object["agentError"] = agentError }
        object["lineage"] = lineage.map { entry -> [String: Any] in
            var encoded: [String: Any] = ["pid": Int(entry.pid), "name": entry.name]
            if let tty = entry.tty { encoded["tty"] = tty }
            return encoded
        }
        guard var data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)
        return data
    }
}
