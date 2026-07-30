import Darwin
import Foundation
import PedalsHookKit

// Lean hook reporter: `pedals-hook <agent-slug> [--event <event>]` reads one
// hook payload from stdin and forwards the mapped event to the daemon's local
// socket. Claude names its event inside the stdin JSON; every other agent
// names it on argv and stdin only enriches. It must never disturb the agent
// that invoked it — no stdout, no nonzero exit, and every failure path is a
// silent `exit(0)`.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let slug = arguments[1]
guard slug == "claude" || AgentHookMapper.slugs.contains(slug) else { exit(0) }

var argvEvent: String?
if let index = arguments.firstIndex(of: "--event"), index + 1 < arguments.count {
    argvEvent = arguments[index + 1]
}

// A malformed hook host must not keep the agent waiting for stdin EOF.
let input = HookInput.read()

let report: HookReport?
if slug == "claude" {
    report = ClaudeHookMapper.report(stdinData: input)
} else if let event = argvEvent {
    // The daemon resolves Codex's title/transcript from its read-only state
    // database after accepting the event. Avoid doing the same SQLite work
    // synchronously inside Codex's hook process.
    report = AgentHookMapper.report(
        slug: slug,
        event: event,
        stdinData: input,
        resolveCodexMetadata: false
    )
} else {
    report = nil // non-Claude slugs require --event
}
guard let report else { exit(0) }
let lineage = ProcessLineage.walk()
guard let line = HookWire.requestLine(agent: slug, report: report, lineage: lineage)
else { exit(0) }
HookSocket.send(line, socketPath: HookSocket.defaultSocketPath())
exit(0)
