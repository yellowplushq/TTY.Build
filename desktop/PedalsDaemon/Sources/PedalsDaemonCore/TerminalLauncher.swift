import AppKit
import Foundation

/// Detection and command-launch support for the menu bar's "Open in Terminal"
/// action. macOS has no "default terminal" API, so — like GitHub Desktop's
/// shell enumeration — we keep a table of known terminals, detect which are
/// installed, and rank the likely preference: running terminals first, then
/// by Spotlight last-used date, with Terminal.app as the always-present
/// fallback. The user can override the choice in Settings.
public struct TerminalLauncher: Sendable {
    public enum LaunchError: Error, CustomStringConvertible {
        case notInstalled(String)
        case noExecutable(String)
        case appleScriptFailed(String)
        case spawnFailed(String)

        public var description: String {
            switch self {
            case .notInstalled(let name): "\(name) is not installed"
            case .noExecutable(let name): "could not locate the \(name) executable"
            case .appleScriptFailed(let detail): detail
            case .spawnFailed(let detail): detail
            }
        }
    }

    public enum Strategy: Sendable {
        /// Terminal.app: `do script`.
        case terminalAppleScript
        /// iTerm2: `create window with default profile command`.
        case iTermAppleScript
        /// Run the app bundle's CLI binary. Arguments are built from the
        /// command, the user's shell, and whether the app is already running
        /// (WezTerm spawns into a running instance, starts a new one
        /// otherwise).
        case cli(executableName: String?, arguments: @Sendable (_ command: String, _ shell: String, _ isRunning: Bool) -> [String])
    }

    public struct Terminal: Sendable, Equatable, Identifiable {
        public let bundleID: String
        public let name: String
        let strategy: Strategy

        public var id: String { bundleID }

        public static func == (lhs: Terminal, rhs: Terminal) -> Bool {
            lhs.bundleID == rhs.bundleID
        }
    }

    /// Injectable system probes so ranking is unit-testable.
    public struct Probe: Sendable {
        public var appURL: @Sendable (String) -> URL?
        public var runningBundleIDs: @Sendable () -> Set<String>
        public var lastUsedDate: @Sendable (URL) -> Date?

        public init(
            appURL: @escaping @Sendable (String) -> URL?,
            runningBundleIDs: @escaping @Sendable () -> Set<String>,
            lastUsedDate: @escaping @Sendable (URL) -> Date?
        ) {
            self.appURL = appURL
            self.runningBundleIDs = runningBundleIDs
            self.lastUsedDate = lastUsedDate
        }

        public static let live = Probe(
            appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            runningBundleIDs: {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            },
            lastUsedDate: {
                NSMetadataItem(url: $0)?
                    .value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            }
        )
    }

    private static func shellWrapping(
        _ prefix: [String]
    ) -> @Sendable (String, String, Bool) -> [String] {
        { command, shell, _ in prefix + [shell, "-lc", command] }
    }

    /// Every terminal we know how to open a session in. Warp and Hyper are
    /// deliberately absent: neither offers a stable "open a window running
    /// this command" interface.
    public static let knownTerminals: [Terminal] = [
        Terminal(bundleID: "com.apple.Terminal", name: "Terminal", strategy: .terminalAppleScript),
        Terminal(bundleID: "com.googlecode.iterm2", name: "iTerm2", strategy: .iTermAppleScript),
        Terminal(
            bundleID: "com.mitchellh.ghostty", name: "Ghostty",
            strategy: .cli(executableName: nil, arguments: shellWrapping(["-e"]))
        ),
        Terminal(
            bundleID: "org.alacritty", name: "Alacritty",
            strategy: .cli(executableName: nil, arguments: shellWrapping(["-e"]))
        ),
        Terminal(
            bundleID: "com.github.wez.wezterm", name: "WezTerm",
            strategy: .cli(executableName: nil) { command, shell, isRunning in
                let wrapped = [shell, "-lc", command]
                return isRunning
                    ? ["cli", "spawn", "--new-window", "--"] + wrapped
                    : ["start", "--"] + wrapped
            }
        ),
        Terminal(
            bundleID: "net.kovidgoyal.kitty", name: "kitty",
            strategy: .cli(executableName: nil, arguments: shellWrapping([]))
        ),
    ]

    public static func installed(probe: Probe = .live) -> [Terminal] {
        knownTerminals.filter { probe.appURL($0.bundleID) != nil }
    }

    /// Best-guess ordering of the user's preferred terminal: anything
    /// currently running beats anything not running; within a group, most
    /// recently used first. Terminals with no usage record sort last.
    public static func ranked(probe: Probe = .live) -> [Terminal] {
        let running = probe.runningBundleIDs()
        return installed(probe: probe).sorted { lhs, rhs in
            let lhsRunning = running.contains(lhs.bundleID)
            let rhsRunning = running.contains(rhs.bundleID)
            if lhsRunning != rhsRunning { return lhsRunning }
            let lhsDate = probe.appURL(lhs.bundleID).flatMap { probe.lastUsedDate($0) }
            let rhsDate = probe.appURL(rhs.bundleID).flatMap { probe.lastUsedDate($0) }
            switch (lhsDate, rhsDate) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name < rhs.name
            }
        }
    }

    /// Opens a new window of `terminal` running `command` (a full shell
    /// command line, e.g. `TmuxConfiguration.attachCommand(id:)`).
    public static func open(
        command: String, terminal: Terminal, probe: Probe = .live
    ) throws {
        switch terminal.strategy {
        case .terminalAppleScript:
            try runAppleScript("""
                tell application "Terminal"
                    activate
                    do script "\(appleScriptEscape(command))"
                end tell
                """)
        case .iTermAppleScript:
            try runAppleScript("""
                tell application "iTerm"
                    activate
                    create window with default profile command "\(appleScriptEscape(command))"
                end tell
                """)
        case .cli(let executableName, let arguments):
            guard let appURL = probe.appURL(terminal.bundleID) else {
                throw LaunchError.notInstalled(terminal.name)
            }
            let executable: URL
            if let executableName {
                executable = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
            } else if let resolved = Bundle(url: appURL)?.executableURL {
                executable = resolved
            } else {
                throw LaunchError.noExecutable(terminal.name)
            }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let isRunning = probe.runningBundleIDs().contains(terminal.bundleID)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments(command, shell, isRunning)
            do {
                try process.run()
            } catch {
                throw LaunchError.spawnFailed("\(terminal.name): \(error.localizedDescription)")
            }
        }
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            throw LaunchError.appleScriptFailed(message)
        }
    }
}
