import AppKit
import Foundation
import TTYBuildDaemonCore

/// "Open in Terminal" and the PATH install for the shipped attach client
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §§6–7).
///
/// The bundled `ttybuild-attach` is first installed to
/// `~/.tty.build/bin/ttybuild-attach` (stable across app relocation, same
/// pattern as the hook reporter). Opening a session writes a per-session
/// `.command` launcher and hands it to the user's default terminal via
/// LaunchServices, so iTerm2/Warp users land in their own terminal without
/// any per-app scripting.
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

    /// Opens the user's default terminal attached to `sessionId`.
    static func openInTerminal(sessionId: Int, home: TTYBuildHome = TTYBuildHome()) throws {
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
        NSWorkspace.shared.open(launcher)
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
