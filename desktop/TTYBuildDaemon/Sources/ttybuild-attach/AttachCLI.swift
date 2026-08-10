import ArgumentParser
import Darwin
import Foundation
import TTYBuildDaemonCore
import TTYBuildKit

/// Shipped attach-only client (docs/EXCLUSIVE_ATTACH_DESIGN.md §6): attaches
/// the current terminal to a daemon-owned session with exclusive hold.
/// Detach: press Ctrl-\ twice. When another surface takes over, the screen
/// becomes a placeholder; ⏎/t claims back, q quits.
@main
struct AttachCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ttybuild-attach",
        abstract: "Attach this terminal to a TTY.Build session."
    )

    @Argument(help: "Session id (see the TTY.Build menu, or omit with --new).")
    var id: Int?

    @Flag(name: .long, help: "Create a new session and attach to it.")
    var new = false

    @Option(name: .long, help: "Working directory for --new.")
    var cwd: String?

    func validate() throws {
        if new, id != nil {
            throw ValidationError("pass either a session id or --new, not both")
        }
        if !new, id == nil {
            throw ValidationError("pass a session id, or --new to create one")
        }
    }

    func run() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ValidationError("ttybuild-attach needs an interactive terminal")
        }

        let home = TTYBuildHome()
        var request: [String: Any] = ["cmd": "attach"]
        if new {
            request["new"] = true
            if let cwd { request["cwd"] = cwd }
            let size = TerminalIO.windowSize()
            request["cols"] = Int(size.cols)
            request["rows"] = Int(size.rows)
        } else if let id {
            request["id"] = id
        }

        let stream: AttachStream
        let handshake: AttachStream.Handshake
        do {
            (stream, handshake) = try AttachStream.connect(
                socketPath: home.socketPath, request: request
            )
        } catch {
            FileHandle.standardError.write(Data("ttybuild-attach: \(error)\n".utf8))
            throw ExitCode(1)
        }

        let session = AttachSession(stream: stream, handshake: handshake)
        throw ExitCode(session.run())
    }
}
