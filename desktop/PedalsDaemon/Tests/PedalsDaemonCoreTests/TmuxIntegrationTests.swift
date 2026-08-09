import Foundation
import XCTest

@testable import PedalsDaemonCore

/// SessionManager against a real tmux binary on a private socket under a
/// temporary directory (never the user's real `~/.pedals`). Skipped when no
/// tmux is installed.
final class TmuxIntegrationTests: XCTestCase {
    private var tmuxBinary: String!
    private var directory: URL!
    private var configuration: TmuxConfiguration!

    override func setUpWithError() throws {
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(entry)/tmux")
        }
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("tmux is not installed on this machine")
        }
        tmuxBinary = found

        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pedals-it-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory

        // Panes run a hermetic /bin/sh instead of the user's login shell.
        let configPath = directory.appendingPathComponent("tmux.conf").path
        try (TmuxConfiguration.configContents + "set -g default-command /bin/sh\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)

        configuration = TmuxConfiguration(
            binaryPath: tmuxBinary,
            socketPath: directory.appendingPathComponent("tmux.sock").path,
            configPath: configPath
        )
    }

    override func tearDownWithError() throws {
        configuration?.killServer()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// `tmux -S <sock> ls`, or nil when the private server is unreachable.
    private func listSessions() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        process.arguments = ["-S", configuration.socketPath, "list-sessions"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func waitFor(
        _ timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func testCreateListOutputRoundTripAndClose() throws {
        let manager = SessionManager(
            options: SessionManager.Options(tmux: configuration)
        )
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        let name = "pedals-\(id)"

        XCTAssertTrue(
            waitFor { self.listSessions()?.contains(name) == true },
            "tmux ls must show the managed session \(name)"
        )

        // The pane metadata poll parses real tmux output.
        XCTAssertTrue(
            waitFor {
                self.configuration.listPanes().contains {
                    $0.sessionID == id && $0.tty.hasPrefix("/dev/ttys")
                }
            },
            "list-panes must expose the pane identity for agent matching"
        )

        manager.write(id: id, data: Data("printf 'pedals-it-%s\\n' ok\n".utf8))
        XCTAssertTrue(
            waitFor {
                guard let snapshot = manager.replaySnapshot(id: id) else { return false }
                return String(decoding: snapshot.data, as: UTF8.self).contains("pedals-it-ok")
            },
            "typed input must round-trip through the tmux pane into the ring buffer"
        )

        XCTAssertTrue(manager.close(id: id))
        XCTAssertTrue(
            waitFor(5) { self.listSessions()?.contains(name) != true },
            "close must remove the session from the private tmux server"
        )
    }

    func testCloseAllKillsThePrivateServer() throws {
        let manager = SessionManager(
            options: SessionManager.Options(tmux: configuration)
        )

        _ = try manager.create(cwd: nil, cols: 80, rows: 24)
        _ = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertTrue(
            waitFor { (self.listSessions() ?? "").contains("pedals-") },
            "the private server never came up"
        )

        manager.closeAll()

        XCTAssertTrue(
            waitFor(5) { self.listSessions() == nil },
            "closeAll must kill the private tmux server"
        )
        XCTAssertTrue(manager.list().isEmpty)
    }
}
