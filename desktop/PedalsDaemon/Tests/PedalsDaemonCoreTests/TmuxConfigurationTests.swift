import Foundation
import XCTest

@testable import PedalsDaemonCore

final class TmuxConfigurationTests: XCTestCase {
    private var fixture: FakeTmux.Fixture!

    override func setUpWithError() throws {
        fixture = try FakeTmux.makeFixture()
    }

    override func tearDownWithError() throws {
        fixture.cleanUp()
    }

    func testSessionNameAndIDRoundTrip() {
        let config = fixture.configuration
        XCTAssertEqual(config.sessionName(for: 42), "pedals-42")
        XCTAssertEqual(config.sessionID(forName: "pedals-42"), 42)
        XCTAssertEqual(config.sessionID(forName: "pedals-1"), 1)
        XCTAssertNil(config.sessionID(forName: "other-1"), "foreign sessions are rejected")
        XCTAssertNil(config.sessionID(forName: "pedals-"))
        XCTAssertNil(config.sessionID(forName: "pedals-abc"))
    }

    func testNewSessionArgumentsShapeAndSortedEnvironment() {
        let config = TmuxConfiguration(
            binaryPath: "/usr/local/bin/tmux",
            socketPath: "/tmp/t.sock",
            configPath: "/tmp/t.conf"
        )
        let argv = config.newSessionArguments(
            id: 7, cwd: "/tmp/work", cols: 80, rows: 24,
            extraEnvironment: ["BETA": "two words", "ALPHA": "1"]
        )
        XCTAssertEqual(argv, [
            "/usr/local/bin/tmux",
            "-S", "/tmp/t.sock",
            "-f", "/tmp/t.conf",
            "new-session",
            "-s", "pedals-7",
            "-x", "80",
            "-y", "24",
            "-c", "/tmp/work",
            "-e", "COLORTERM=truecolor",
            "-e", "PROMPT_EOL_MARK=",
            "-e", "ALPHA=1",
            "-e", "BETA=two words",
        ])
    }

    func testNewSessionArgumentsNeverLetExtraEnvironmentOverrideRenderingInvariants() {
        // zsh's partial-line `%` marker and truecolor are rendering
        // invariants; a stray extraEnvironment entry must not re-enable them
        // (tmux `-e` is last-one-wins for duplicate keys).
        let config = TmuxConfiguration(
            binaryPath: "/usr/local/bin/tmux",
            socketPath: "/tmp/t.sock",
            configPath: "/tmp/t.conf"
        )
        let argv = config.newSessionArguments(
            id: 1, cwd: "/tmp", cols: 80, rows: 24,
            extraEnvironment: ["PROMPT_EOL_MARK": "visible", "COLORTERM": "no", "PS1": "$ "]
        )
        XCTAssertEqual(argv.filter { $0 == "PROMPT_EOL_MARK=" }.count, 1)
        XCTAssertEqual(argv.filter { $0 == "COLORTERM=truecolor" }.count, 1)
        XCTAssertFalse(argv.contains("PROMPT_EOL_MARK=visible"))
        XCTAssertFalse(argv.contains("COLORTERM=no"))
        XCTAssertTrue(argv.contains("PS1=$ "))
    }

    func testAttachCommandShellQuotesEveryComponent() {
        let config = TmuxConfiguration(
            binaryPath: "/opt/pedals app/tmux",
            socketPath: "/tmp/dir with spaces/tmux.sock",
            configPath: "/tmp/conf dir/tmux.conf"
        )
        XCTAssertEqual(
            config.attachCommand(id: 3),
            "'/opt/pedals app/tmux' -S '/tmp/dir with spaces/tmux.sock'"
                + " -f '/tmp/conf dir/tmux.conf' attach-session -t 'pedals-3'"
        )
    }

    func testShellQuoteEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(TmuxConfiguration.shellQuote("plain"), "'plain'")
        XCTAssertEqual(TmuxConfiguration.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(TmuxConfiguration.shellQuote(""), "''")
    }

    func testListPanesParsesServerOutput() throws {
        let config = fixture.configuration
        // The recorded pid must be alive or the fake drops the session.
        try fixture.recordSession(
            name: "pedals-1", pid: getpid(), cwd: "/tmp/one", command: "zsh"
        )
        try fixture.recordSession(
            name: "pedals-2", pid: getpid(), cwd: "/tmp/two", command: "sh"
        )
        // A foreign session name on the socket is never adopted.
        try fixture.recordSession(
            name: "user-scratch", pid: getpid(), cwd: "/tmp/x", command: "bash"
        )
        // Per-session metadata override drives tty/pid/path/command.
        try fixture.setPaneMeta(
            sessionName: "pedals-2",
            tty: "/dev/ttys090", pid: 31337,
            path: "/private/override", command: "vim"
        )

        let panes = config.listPanes()
        XCTAssertEqual(panes.count, 2)

        let first = try XCTUnwrap(panes.first { $0.sessionID == 1 })
        XCTAssertEqual(first.tty, "/dev/ttys000")
        XCTAssertEqual(first.pid, getpid())
        XCTAssertEqual(first.currentPath, "/tmp/one")
        XCTAssertEqual(first.currentCommand, "zsh")

        let second = try XCTUnwrap(panes.first { $0.sessionID == 2 })
        XCTAssertEqual(second.tty, "/dev/ttys090")
        XCTAssertEqual(second.pid, 31337)
        XCTAssertEqual(second.currentPath, "/private/override")
        XCTAssertEqual(second.currentCommand, "vim")
    }

    func testListPanesEmptyWhenServerUnreachable() {
        // No state directory at all: the private server has never started.
        XCTAssertEqual(fixture.configuration.listPanes(), [])
    }

    func testResolveEitherFindsTmuxWithHomePathsOrThrowsBinaryNotFound() throws {
        let home = PedalsHome(
            directory: URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("pedals-resolve-\(UUID().uuidString.prefix(8))")
        )
        defer { try? FileManager.default.removeItem(at: home.directory) }
        do {
            let resolved = try TmuxConfiguration.resolve(home: home)
            XCTAssertEqual(resolved.socketPath, home.tmuxSocketPath)
            XCTAssertEqual(resolved.configPath, home.tmuxConfigURL.path)
            XCTAssertTrue(resolved.binaryPath.hasSuffix("/tmux"))
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: resolved.binaryPath)
            )
        } catch TmuxConfiguration.ResolveError.binaryNotFound {
            // Also a valid outcome on a host without tmux: the failure mode
            // is the contract.
        }
    }

    func testWriteConfigFileIsIdempotentAndPrivate() throws {
        let home = PedalsHome(directory: fixture.directory)
        let config = fixture.configuration
        try config.writeConfigFile(home: home)

        let url = URL(fileURLWithPath: config.configPath)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            TmuxConfiguration.configContents
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: config.configPath)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        // A second write with unchanged contents leaves the file untouched.
        let modified = try FileManager.default
            .attributesOfItem(atPath: config.configPath)[.modificationDate] as? Date
        try config.writeConfigFile(home: home)
        let modifiedAgain = try FileManager.default
            .attributesOfItem(atPath: config.configPath)[.modificationDate] as? Date
        XCTAssertEqual(modified, modifiedAgain)
    }
}
