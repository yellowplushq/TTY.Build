import AppKit
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

    var canRunScript: Bool {
        opensCommandFiles || executeArguments(script: "") != nil
    }

    var installedURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
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
/// The bundled `ttybuild-attach` is first installed to
/// `~/.tty.build/bin/ttybuild-attach` (stable across app relocation, same
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
                "The ttybuild-attach helper is missing from this build."
            case .symlinkFailed(let detail):
                "Could not install the command line tool: \(detail)"
            }
        }
    }

    static let installedCommandName = "ttybuild-attach"

    /// The attach client embedded in the app bundle by the build.
    private static var bundledClient: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent()
            .appendingPathComponent("ttybuild-attach")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Copies the bundled client into `~/.tty.build/bin` (atomic replace,
    /// 0755) so scripts and symlinks keep working across app updates.
    @discardableResult
    static func installClientBinary(home: TTYBuildHome = TTYBuildHome()) throws -> URL {
        guard let bundled = bundledClient else {
            throw OpenerError.missingBundledClient
        }
        let destination = home.attachClientURL
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
        exec \(shellQuoted(client.path)) \(sessionId)
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

        if let args = terminal.executeArguments(script: script.path),
           let app = terminal.installedURL
        {
            // `open -na <app> --args …`: a fresh window running the script,
            // no AppleScript and no Accessibility permission involved.
            configuration.createsNewApplicationInstance = true
            configuration.arguments = args
            NSWorkspace.shared.openApplication(
                at: app, configuration: configuration
            ) { _, _ in }
            return
        }

        // No permission-free way to run a command in this terminal (Warp,
        // unknown): fall back to Terminal.app, which is always present.
        if let fallback = KnownTerminal.terminal.installedURL {
            NSWorkspace.shared.open(
                [script], withApplicationAt: fallback, configuration: configuration
            ) { _, _ in }
        } else {
            NSWorkspace.shared.open(script)
        }
    }

    // MARK: - PATH install (Settings)

    /// Candidate directories for the `ttybuild-attach` symlink, best first.
    private static var pathCandidates: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    /// Where the command is currently reachable, if anywhere.
    static func installedCommandLocation() -> URL? {
        let target = TTYBuildHome().attachClientURL.path
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
