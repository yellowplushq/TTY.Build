import AppKit
import ApplicationServices
import Foundation
import TTYBuildDaemonCore

/// A terminal app we know how to hand a runnable `.command` script to
/// without AppleScript, keystroke synthesis, or extra permissions
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §6).
///
/// Launch strategies, in the spirit of OpenInTerminal's per-app adapters
/// but built around the fact that we always have an executable script:
/// - `.opensCommandFiles`: the app declares the shell-script document type
///   and executes `.command` files it opens (Terminal.app, iTerm2).
/// - `.executeArgs`: the app's CLI runs a program passed via
///   `open -na <app> --args …` (Ghostty/Alacritty `-e`, kitty positional,
///   WezTerm `start --`).
/// Apps with neither (e.g. Warp, which would need Accessibility-permission
/// keystroke injection à la VibeTunnel) fall back to Terminal.app.
enum KnownTerminal: String, CaseIterable {
    case terminal
    case iTerm2
    case ghostty
    case warp
    case warpPreview
    case kitty
    case alacritty
    case wezterm
    case hyper

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm2: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .warpPreview: "dev.warp.Warp-Preview"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        case .wezterm: "com.github.wez.wezterm"
        case .hyper: "co.zeit.hyper"
        }
    }

    init?(bundleIdentifier: String) {
        guard let match = Self.allCases.first(
            where: { $0.bundleIdentifier == bundleIdentifier }
        ) else { return nil }
        self = match
    }

    /// Fallback ranking when nothing was ever activated: running terminals
    /// win by rough popularity (VibeTunnel's detection-priority idea).
    var detectionPriority: Int {
        switch self {
        case .terminal: 100
        case .iTerm2: 95
        case .warp: 85
        case .warpPreview: 84
        case .ghostty: 80
        case .kitty: 75
        case .alacritty: 70
        case .wezterm: 60
        case .hyper: 50
        }
    }

    /// `open -na <app> --args` argument vector that executes `script`, or
    /// nil when the app either opens `.command` files itself or cannot run
    /// a command without keystroke injection.
    func executeArguments(script: String) -> [String]? {
        switch self {
        case .ghostty, .alacritty: ["-e", script]
        case .kitty: [script]
        case .wezterm: ["start", "--", script]
        case .terminal, .iTerm2, .warp, .warpPreview, .hyper: nil
        }
    }

    /// Whether the app executes an opened `.command` file (declares the
    /// shell-script document type).
    var opensCommandFiles: Bool {
        switch self {
        case .terminal, .iTerm2: true
        default: false
        }
    }

    /// Whether we can type the command into a fresh window of a running
    /// instance (⌘N + keystrokes via System Events). The escape hatch for
    /// single-instance apps where `open -n` would spawn a second app
    /// instance (Ghostty) and for apps with no CLI channel at all (Warp).
    /// Requires the Accessibility permission the app already asks for.
    var supportsKeystrokeWindow: Bool {
        switch self {
        case .ghostty, .warp, .warpPreview: true
        default: false
        }
    }

    /// The "run it" keystroke. Warp ignores key code 36 and needs a raw
    /// carriage return (VibeTunnel's finding).
    var keystrokeReturnSnippet: String {
        switch self {
        case .warp, .warpPreview: "keystroke (ASCII character 13)"
        default: "key code 36"
        }
    }

    var canRunScript: Bool {
        opensCommandFiles || executeArguments(script: "") != nil
            || supportsKeystrokeWindow
    }

    var installedURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// Remembers the terminal app the user most recently used. The menu bar app
/// is long-lived, so app-activation notifications give a true MRU signal;
/// the recorded bundle id survives restarts via UserDefaults.
@MainActor
final class TerminalUsageTracker {
    static let defaultsKey = "lastUsedTerminalBundleID"
    private var observer: NSObjectProtocol?

    /// The most recently activated (still installed) known terminal.
    static var lastUsedTerminal: KnownTerminal? {
        guard let id = UserDefaults.standard.string(forKey: defaultsKey),
              let terminal = KnownTerminal(bundleIdentifier: id),
              terminal.installedURL != nil
        else { return nil }
        return terminal
    }

    func start() {
        guard observer == nil else { return }
        // Seed on first run from terminals that are already running, so the
        // very first "Open in Terminal" can honor e.g. an open Ghostty even
        // before the user switches apps once.
        if TerminalUsageTracker.lastUsedTerminal == nil,
           let running = Self.runningTerminal()
        {
            UserDefaults.standard.set(
                running.bundleIdentifier, forKey: Self.defaultsKey
            )
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                let id = app.bundleIdentifier,
                KnownTerminal(bundleIdentifier: id) != nil
            else { return }
            UserDefaults.standard.set(id, forKey: Self.defaultsKey)
        }
    }

    /// The best-guess terminal among running processes. A running
    /// *third-party* terminal is a deliberate user choice and outranks
    /// Terminal.app (which may merely be macOS's incidental default);
    /// third-party ties break by popularity.
    static func runningTerminal() -> KnownTerminal? {
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let candidates = KnownTerminal.allCases
            .filter { running.contains($0.bundleIdentifier) }
        let thirdParty = candidates.filter { $0 != .terminal }
        return thirdParty.max { $0.detectionPriority < $1.detectionPriority }
            ?? candidates.first
    }

    // No deinit-time unsubscription: the tracker is owned by the app
    // delegate and lives for the whole process.
}

/// "Open in Terminal" and the PATH install for the shipped attach client
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §§6–7).
///
/// The bundled `ttybuild` CLI is first installed to
/// `~/.tty.build/bin/ttybuild` (stable across app relocation, same
/// pattern as the hook reporter). Opening a session writes a per-session
/// `.command` launcher and hands it to the user's terminal of choice:
/// most recently used first, then a running terminal, then Terminal.app.
@MainActor
enum TerminalOpener {
    enum OpenerError: LocalizedError {
        case missingBundledClient
        case symlinkFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledClient:
                "The ttybuild CLI is missing from this build."
            case .symlinkFailed(let detail):
                "Could not install the command line tool: \(detail)"
            }
        }
    }

    static let installedCommandName = "ttybuild"

    /// The `ttybuild` CLI embedded in the app bundle by the build. It lives
    /// in Contents/Helpers because case-insensitive APFS would collide
    /// MacOS/ttybuild with the app executable TTYBuild.
    private static var bundledClient: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/ttybuild")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Copies the bundled client into `~/.tty.build/bin` (atomic replace,
    /// 0755) so scripts and symlinks keep working across app updates.
    @discardableResult
    static func installClientBinary(home: TTYBuildHome = TTYBuildHome()) throws -> URL {
        guard let bundled = bundledClient else {
            throw OpenerError.missingBundledClient
        }
        let destination = home.cliURL
        try HookInstaller.installReporterBinary(from: bundled, to: destination)
        return destination
    }

    /// The terminal a new attach window should open in: most recently used,
    /// else the highest-priority running one, else Terminal.app.
    static func preferredTerminal() -> KnownTerminal {
        if let last = TerminalUsageTracker.lastUsedTerminal, last.canRunScript {
            return last
        }
        if let running = TerminalUsageTracker.runningTerminal(), running.canRunScript {
            return running
        }
        return .terminal
    }

    /// Opens the user's preferred terminal attached to `sessionId`.
    static func openInTerminal(sessionId: Int, home: TTYBuildHome = TTYBuildHome()) throws {
        let launcher = try writeLauncher(sessionId: sessionId, home: home)
        launch(script: launcher, in: preferredTerminal())
    }

    private static func writeLauncher(sessionId: Int, home: TTYBuildHome) throws -> URL {
        let client = try installClientBinary(home: home)
        let directory = home.openScriptsDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `exec` replaces the wrapper shell so the terminal tab runs only the
        // attach client; `clear` drops the shell's own startup noise first.
        let script = """
        #!/bin/zsh
        clear
        exec \(shellQuoted(client.path)) attach \(sessionId)
        """
        let launcher = directory.appendingPathComponent("tty-\(sessionId).command")
        try Data(script.utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: launcher.path
        )
        return launcher
    }

    private static func launch(script: URL, in terminal: KnownTerminal) {
        let configuration = NSWorkspace.OpenConfiguration()

        if terminal.opensCommandFiles, let app = terminal.installedURL {
            NSWorkspace.shared.open(
                [script], withApplicationAt: app, configuration: configuration
            ) { _, _ in }
            return
        }

        // A running single-instance terminal (Ghostty): `open -n` would
        // spawn a second app instance, so type the command into a fresh
        // window of the existing one when Accessibility allows it.
        if terminal.supportsKeystrokeWindow, terminal.isRunning,
           AXIsProcessTrusted()
        {
            launchViaKeystrokes(script: script, in: terminal)
            return
        }

        if let args = terminal.executeArguments(script: script.path),
           let app = terminal.installedURL
        {
            // `open -na <app> --args …`: a fresh (first or, for a running
            // single-instance app, second) instance running the script —
            // no AppleScript and no Accessibility permission involved.
            configuration.createsNewApplicationInstance = true
            configuration.arguments = args
            NSWorkspace.shared.openApplication(
                at: app, configuration: configuration
            ) { _, _ in }
            return
        }

        // Keystroke-only terminals (Warp) from cold start, when permitted.
        if terminal.supportsKeystrokeWindow, AXIsProcessTrusted() {
            launchViaKeystrokes(script: script, in: terminal)
            return
        }

        // No permitted way to run a command in this terminal: fall back to
        // Terminal.app, which is always present.
        if let fallback = KnownTerminal.terminal.installedURL {
            NSWorkspace.shared.open(
                [script], withApplicationAt: fallback, configuration: configuration
            ) { _, _ in }
        } else {
            NSWorkspace.shared.open(script)
        }
    }

    /// Opens a new window in the (possibly cold-started) terminal and types
    /// `exec <script>` into it — the VibeTunnel launch pattern, minus its
    /// clipboard use: the command is typed directly so the user's pasteboard
    /// is never clobbered. Runs osascript off the main thread; the child
    /// process inherits this app's Automation/Accessibility identity.
    private static func launchViaKeystrokes(script: URL, in terminal: KnownTerminal) {
        let wasRunning = terminal.isRunning
        // Cold starts need the app to finish launching before ⌘N lands;
        // warm instances just need activation to settle.
        let activateDelay = wasRunning ? 0.4 : 2.5
        let command = "clear; exec \(shellQuoted(script.path))"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application id "\(terminal.bundleIdentifier)" to activate
        delay \(activateDelay)
        tell application "System Events"
            keystroke "n" using {command down}
            delay 0.5
            keystroke "\(escaped)"
            \(terminal.keystrokeReturnSnippet)
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - PATH install (Settings)

    /// Candidate directories for the `ttybuild` symlink, best first.
    private static var pathCandidates: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    /// Where the command is currently reachable, if anywhere.
    static func installedCommandLocation() -> URL? {
        let target = TTYBuildHome().cliURL.path
        for directory in pathCandidates {
            let link = directory.appendingPathComponent(installedCommandName)
            if let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: link.path),
                destination == target
            {
                return link
            }
        }
        return nil
    }

    /// Symlinks the installed client onto the PATH: `/usr/local/bin` when
    /// writable, else `~/.local/bin` (which the user may need to add to
    /// PATH). Never escalates privileges.
    @discardableResult
    static func installCommandLineTool() throws -> URL {
        let client = try installClientBinary()
        var lastFailure = "no writable install location"
        for directory in pathCandidates {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                let link = directory.appendingPathComponent(installedCommandName)
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: client
                )
                return link
            } catch {
                lastFailure = "\(directory.path): \(error.localizedDescription)"
            }
        }
        throw OpenerError.symlinkFailed(lastFailure)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
