import Foundation

/// Everything the daemon needs to drive its private tmux server: the bundled
/// (or, in development, PATH-resolved) tmux binary, a private socket under
/// `PedalsHome`, and a generated `-f` config that keeps the user's own
/// `~/.tmux.conf` out of managed sessions.
///
/// Every managed TTY is a tmux session named `pedals-<id>` on this server.
/// The daemon never connects to any other tmux server and never adopts
/// sessions it did not create.
public struct TmuxConfiguration: Sendable {
    public enum ResolveError: Error, CustomStringConvertible {
        /// No bundled tmux next to the executable and no tmux on PATH.
        case binaryNotFound

        public var description: String {
            switch self {
            case .binaryNotFound:
                "no tmux binary found — expected one next to the executable or on PATH"
            }
        }
    }

    public enum CommandError: Error, CustomStringConvertible {
        case nonZeroExit(command: String, status: Int32)

        public var description: String {
            switch self {
            case .nonZeroExit(let command, let status):
                "tmux \(command) exited with status \(status)"
            }
        }
    }

    public let binaryPath: String
    public let socketPath: String
    public let configPath: String

    public init(binaryPath: String, socketPath: String, configPath: String) {
        self.binaryPath = binaryPath
        self.socketPath = socketPath
        self.configPath = configPath
    }

    /// Resolution order: `tmux` next to the running executable (the app
    /// bundle's MacOS directory, or the build products directory for the
    /// headless `pedals` executable), then a `tmux` found on PATH. Mirrors
    /// `RemoteManagement.bundledReporter()`.
    public static func resolve(home: PedalsHome) throws -> TmuxConfiguration {
        let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("tmux")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return TmuxConfiguration(
                binaryPath: bundled.path,
                socketPath: home.tmuxSocketPath,
                configPath: home.tmuxConfigURL.path
            )
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("tmux")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return TmuxConfiguration(
                    binaryPath: candidate.path,
                    socketPath: home.tmuxSocketPath,
                    configPath: home.tmuxConfigURL.path
                )
            }
        }
        throw ResolveError.binaryNotFound
    }

    /// Generated configuration for the private server. Written on every
    /// resolve so upgrades take effect on the next server start; the server
    /// reads it via `-f`, which also keeps `~/.tmux.conf` from loading.
    public static let configContents = """
        # Managed by Pedals. Regenerated on every daemon start; do not edit.
        set -s default-terminal screen-256color
        set -sa terminal-overrides ',xterm-256color:RGB'
        set -s escape-time 10
        set -g set-titles on
        set -g set-titles-string '#T'
        set -g window-size latest
        set -g focus-events on
        set -g mouse on
        set -g history-limit 50000
        set -g status off

        """

    public func writeConfigFile(home: PedalsHome) throws {
        try home.ensureDirectoryExists()
        let url = URL(fileURLWithPath: configPath)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != Self.configContents else { return }
        try Data(Self.configContents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configPath
        )
    }

    public func sessionName(for id: Int) -> String { "pedals-\(id)" }

    /// Session id back out of a session name; nil for sessions we did not
    /// create (there should be none on the private socket).
    public func sessionID(forName name: String) -> Int? {
        guard name.hasPrefix("pedals-") else { return nil }
        return Int(name.dropFirst("pedals-".count))
    }

    /// Full argv (binary included) for the PTY-spawned tmux client that owns
    /// the new session. `-x/-y` size the client so the pane starts with the
    /// requested grid; `-c` pins the pane's starting directory; `-e` forwards
    /// the environment panes need (the tmux server would otherwise filter it).
    /// `COLORTERM` and `PROMPT_EOL_MARK` are rendering invariants, so an
    /// `extraEnvironment` entry can never override them (tmux `-e` is
    /// last-one-wins for duplicate keys).
    public func newSessionArguments(
        id: Int, cwd: String, cols: UInt16, rows: UInt16,
        extraEnvironment: [String: String]
    ) -> [String] {
        var argv = [
            binaryPath,
            "-S", socketPath,
            "-f", configPath,
            "new-session",
            "-s", sessionName(for: id),
            "-x", String(cols),
            "-y", String(rows),
            "-c", cwd,
            "-e", "COLORTERM=truecolor",
            "-e", "PROMPT_EOL_MARK=",
        ]
        for key in extraEnvironment.keys.sorted() {
            guard key != "COLORTERM", key != "PROMPT_EOL_MARK" else { continue }
            argv.append("-e")
            argv.append("\(key)=\(extraEnvironment[key] ?? "")")
        }
        return argv
    }

    /// Human-facing command line that attaches a local terminal to the
    /// session, quoted for embedding in `sh -c` / AppleScript `do script`.
    public func attachCommand(id: Int) -> String {
        [
            Self.shellQuote(binaryPath),
            "-S", Self.shellQuote(socketPath),
            "-f", Self.shellQuote(configPath),
            "attach-session",
            "-t", Self.shellQuote(sessionName(for: id)),
        ].joined(separator: " ")
    }

    // MARK: - Control subprocesses

    /// Kills the tmux session; the daemon's client for it then exits through
    /// the normal PTY exit path. Errors are ignored by callers that also
    /// SIGHUP the client as a backstop.
    public func killSession(id: Int) {
        _ = try? run(["kill-session", "-t", sessionName(for: id)])
    }

    /// Kills the private server outright. Only `pedals-*` sessions live on
    /// this socket, so this never touches a user's own tmux state.
    public func killServer() {
        _ = try? run(["kill-server"])
    }

    public struct PaneInfo: Equatable, Sendable {
        public let sessionID: Int
        public let tty: String
        public let pid: pid_t
        public let currentPath: String
        public let currentCommand: String
    }

    /// One `list-panes` snapshot across the private server. An unreachable
    /// server (no sessions yet, or already dead) yields an empty list.
    public func listPanes() -> [PaneInfo] {
        guard let output = try? run([
            "list-panes", "-a", "-F",
            "#{session_name}\t#{pane_tty}\t#{pane_pid}\t#{pane_current_path}\t#{pane_current_command}",
        ]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let id = sessionID(forName: String(fields[0])),
                  let pid = pid_t(fields[2])
            else { return nil }
            return PaneInfo(
                sessionID: id, tty: String(fields[1]), pid: pid,
                currentPath: String(fields[3]), currentCommand: String(fields[4])
            )
        }
    }

    /// Runs tmux with the private-socket flags prepended and returns stdout.
    /// Throws on a non-zero exit or a spawn failure.
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-S", socketPath, "-f", configPath] + arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandError.nonZeroExit(
                command: arguments.first ?? "",
                status: process.terminationStatus
            )
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Single-quote escaping for shell embedding (`'` → `'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
