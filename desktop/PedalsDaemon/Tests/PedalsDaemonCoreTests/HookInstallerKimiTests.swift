import Foundation
import XCTest

@testable import PedalsDaemonCore

/// Kimi's `[[hooks]]` block editor for ~/.kimi-code/config.toml: managed
/// blocks pruned and re-appended, user blocks and keys preserved byte-for-
/// byte, TOML string escaping round-trips.
final class HookInstallerKimiTests: XCTestCase {
    private var home: URL!
    private let reporter = "/Users/me/.pedals/bin/pedals-hook"

    private var fileURL: URL {
        home.appendingPathComponent(".kimi-code/config.toml")
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedals-kimi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func install(reporter: String? = nil) throws {
        try HookInstaller.install(for: .kimi, reporterPath: reporter ?? self.reporter, home: home)
    }

    private func state() throws -> HookInstaller.State {
        try HookInstaller.state(for: .kimi, reporterPath: reporter, home: home)
    }

    private func readConfig() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    private let allEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd",
    ]

    func testFreshInstallOnMissingFile() throws {
        try install()
        let config = try readConfig()
        XCTAssertEqual(
            config.components(separatedBy: "[[hooks]]").count - 1, 6,
            "six managed blocks"
        )
        for event in allEvents {
            XCTAssertTrue(config.contains("event = \"\(event)\""), event)
        }
        XCTAssertTrue(config.contains(
            "command = \"\(reporter) kimi --event session-start \(HookInstaller.sentinel)\""
        ))
        XCTAssertTrue(config.contains("timeout = 1"))
        XCTAssertTrue(config.hasSuffix("\n"))
        XCTAssertEqual(try state(), .installed)
    }

    func testReinstallIsIdempotent() throws {
        try install()
        let first = try readConfig()
        try install()
        XCTAssertEqual(try readConfig(), first)
    }

    func testUserContentPreservedThroughInstallAndUninstall() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let seed = """
        theme = "dark"

        [[hooks]]
        event = "Stop"
        command = 'my own hook'
        timeout = 3

        [mcp]
        server = "local"
        """
        try Data(seed.utf8).write(to: fileURL)

        try install()
        var config = try readConfig()
        XCTAssertTrue(config.contains("theme = \"dark\""))
        XCTAssertTrue(config.contains("command = 'my own hook'"), "user [[hooks]] block kept")
        XCTAssertTrue(config.contains("[mcp]"))
        XCTAssertEqual(config.components(separatedBy: "[[hooks]]").count - 1, 7)
        XCTAssertEqual(try state(), .installed)

        try HookInstaller.uninstall(for: .kimi, home: home)
        config = try readConfig()
        XCTAssertTrue(config.contains("theme = \"dark\""))
        XCTAssertTrue(config.contains("command = 'my own hook'"))
        XCTAssertTrue(config.contains("server = \"local\""))
        XCTAssertFalse(config.contains(HookInstaller.sentinel))
        XCTAssertEqual(config.components(separatedBy: "[[hooks]]").count - 1, 1)
        XCTAssertEqual(try state(), .notInstalled)
    }

    func testOutdatedWhenReporterPathChanges() throws {
        try install(reporter: "/old/pedals-hook")
        XCTAssertEqual(try state(), .outdated)
        try install()
        XCTAssertEqual(try state(), .installed)
        let config = try readConfig()
        XCTAssertFalse(config.contains("/old/pedals-hook"), "old blocks replaced")
    }

    func testCRLFNormalization() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("theme = \"dark\"\r\nmodel = \"k3\"\r\n".utf8).write(to: fileURL)
        try install()
        let config = try readConfig()
        XCTAssertFalse(config.contains("\r"))
        XCTAssertTrue(config.contains("theme = \"dark\"\nmodel = \"k3\"\n"))
        XCTAssertEqual(try state(), .installed)
    }

    func testNonUTF8IsATypedError() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: fileURL)
        XCTAssertThrowsError(try install()) { error in
            guard case HookInstaller.InstallerError.malformedSettings = error else {
                return XCTFail("expected malformedSettings, got \(error)")
            }
        }
    }

    func testTomlEscapingRoundTrips() throws {
        // A reporter path needing basic-string escaping still set-compares
        // as installed (escape on write, unescape on parse).
        let awkward = #"/Users/me/"weird dir"/pedals\hook"#
        try install(reporter: awkward)
        XCTAssertEqual(
            try HookInstaller.state(for: .kimi, reporterPath: awkward, home: home),
            .installed
        )
        let config = try readConfig()
        XCTAssertTrue(config.contains(#"\"weird dir\""#), "quotes escaped on disk")
        XCTAssertTrue(config.contains(#"pedals\\hook"#), "backslash escaped on disk")
    }

    func testStateOnMissingFile() throws {
        XCTAssertEqual(try state(), .notInstalled)
        try HookInstaller.uninstall(for: .kimi, home: home) // no-op
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
