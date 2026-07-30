import Foundation
import XCTest

@testable import PedalsDaemonCore

/// Codex installer against a temp home: hooks.json grouped merge plus the
/// `[features] hooks = true` flag edited line-based in config.toml.
final class HookInstallerCodexTests: XCTestCase {
    private var home: URL!
    private let reporter = "/Users/me/.pedals/bin/pedals-hook"

    private var hooksURL: URL {
        home.appendingPathComponent(".codex/hooks.json")
    }
    private var configURL: URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedals-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func install(reporter: String? = nil) throws {
        try HookInstaller.install(for: .codex, reporterPath: reporter ?? self.reporter, home: home)
    }

    private func state() throws -> HookInstaller.State {
        try HookInstaller.state(for: .codex, reporterPath: reporter, home: home)
    }

    private func readHooks() throws -> [String: Any] {
        let data = try Data(contentsOf: hooksURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func readConfig() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    private func managedCommands(in root: [String: Any]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        guard let hooks = root["hooks"] as? [String: Any] else { return found }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for entry in group["hooks"] as? [[String: Any]] ?? [] {
                    if let command = entry["command"] as? String,
                       command.contains(HookInstaller.sentinel)
                    {
                        found[event, default: []].append(command)
                    }
                }
            }
        }
        return found
    }

    func testFreshInstallOnMissingFiles() throws {
        try install()

        let root = try readHooks()
        let managed = managedCommands(in: root)
        XCTAssertEqual(Set(managed.keys), [
            "SessionStart", "UserPromptSubmit", "PreToolUse",
            "PermissionRequest", "Stop", "SessionEnd",
        ])
        XCTAssertEqual(
            managed["SessionStart"],
            ["\(reporter) codex --event session-start \(HookInstaller.sentinel)"]
        )
        XCTAssertEqual(
            managed["UserPromptSubmit"],
            ["\(reporter) codex --event prompt \(HookInstaller.sentinel)"]
        )
        XCTAssertEqual(
            managed["PreToolUse"],
            ["\(reporter) codex --event tool \(HookInstaller.sentinel)"]
        )
        XCTAssertEqual(
            managed["PermissionRequest"],
            ["\(reporter) codex --event ask \(HookInstaller.sentinel)"]
        )
        XCTAssertEqual(
            managed["Stop"],
            ["\(reporter) codex --event stop \(HookInstaller.sentinel)"]
        )
        XCTAssertEqual(
            managed["SessionEnd"],
            ["\(reporter) codex --event session-end \(HookInstaller.sentinel)"]
        )
        // Timeouts and matcherless groups.
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertNil(sessionStart[0]["matcher"])
        let startEntry = try XCTUnwrap((sessionStart[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(startEntry["timeout"] as? Int, 1)
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let stopEntry = try XCTUnwrap((stop[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(stopEntry["timeout"] as? Int, 1)

        let config = try readConfig()
        XCTAssertTrue(config.contains("[features]"))
        XCTAssertTrue(config.contains("hooks = true"))

        XCTAssertEqual(try state(), .installed)
    }

    func testReinstallIsIdempotent() throws {
        try install()
        let firstConfig = try readConfig()
        try install()
        XCTAssertEqual(try readConfig(), firstConfig)
        let managed = managedCommands(in: try readHooks())
        for (event, commands) in managed {
            XCTAssertEqual(commands.count, 1, "duplicate entries for \(event)")
        }
        XCTAssertEqual(try state(), .installed)
    }

    func testInstallPreservesUserContentAndStripsLegacyFlag() throws {
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let userEntry: [String: Any] = [
            "type": "command", "command": "my-own-hook.sh", "timeout": 3,
        ]
        let hooksSeed: [String: Any] = [
            "model": "gpt-5.3",
            "hooks": ["Stop": [["hooks": [userEntry]]]],
        ]
        try JSONSerialization.data(withJSONObject: hooksSeed).write(to: hooksURL)
        try Data("""
        # codex config
        model = "gpt-5.3"

        [ features ]  # feature flags
        other = 1
        codex_hooks = true

        [profile]
        hooks = false
        """.utf8).write(to: configURL)

        try install()

        // hooks.json: user entry preserved, ours appended.
        let root = try readHooks()
        XCTAssertEqual(root["model"] as? String, "gpt-5.3")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "user group + pedals group")
        XCTAssertEqual(
            (stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "my-own-hook.sh"
        )

        // config.toml: flag added inside the spaced/commented [ features ]
        // header, legacy flag stripped, unrelated sections untouched.
        let config = try readConfig()
        XCTAssertTrue(config.contains("# codex config"))
        XCTAssertTrue(config.contains("model = \"gpt-5.3\""))
        XCTAssertTrue(config.contains("[ features ]  # feature flags"))
        XCTAssertTrue(config.contains("other = 1"))
        XCTAssertFalse(config.contains("codex_hooks"))
        XCTAssertFalse(config.contains("[features]"), "no second section appended")
        let featuresRange = try XCTUnwrap(config.range(of: "[ features ]"))
        let profileRange = try XCTUnwrap(config.range(of: "[profile]"))
        let hooksTrueRange = try XCTUnwrap(config.range(of: "hooks = true"))
        XCTAssertTrue(hooksTrueRange.lowerBound > featuresRange.upperBound)
        XCTAssertTrue(hooksTrueRange.upperBound < profileRange.lowerBound)
        XCTAssertTrue(config.contains("hooks = false"), "[profile] hooks untouched")

        XCTAssertEqual(try state(), .installed)
    }

    func testUninstallRemovesEntriesAndFlagPreservingUserLines() throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        model = "gpt-5.3"

        [features]
        other = 1
        """.utf8).write(to: configURL)

        try install()
        XCTAssertEqual(try state(), .installed)
        try HookInstaller.uninstall(for: .codex, home: home)

        let root = try readHooks()
        XCTAssertNil(root["hooks"], "an all-pedals hooks object is pruned")

        let config = try readConfig()
        XCTAssertTrue(config.contains("model = \"gpt-5.3\""))
        XCTAssertTrue(config.contains("[features]"))
        XCTAssertTrue(config.contains("other = 1"))
        XCTAssertFalse(config.contains("hooks = true"))
        XCTAssertEqual(try state(), .notInstalled)
    }

    func testUninstallDropsSectionWeCreated() throws {
        try install()
        try HookInstaller.uninstall(for: .codex, home: home)
        let config = try readConfig()
        XCTAssertFalse(config.contains("[features]"), "our own emptied section is dropped")
    }

    func testUninstallWithoutManagedEntriesLeavesUserFlag() throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("[features]\nhooks = true\n".utf8).write(to: configURL)
        try HookInstaller.uninstall(for: .codex, home: home)
        XCTAssertTrue(try readConfig().contains("hooks = true"),
                      "a user-owned flag survives when we had nothing installed")
    }

    func testStateCombinations() throws {
        // Missing everything.
        XCTAssertEqual(try state(), .notInstalled)

        // Installed hooks but flag manually removed → outdated.
        try install()
        try Data("".utf8).write(to: configURL)
        XCTAssertEqual(try state(), .outdated)

        // Flag present but hooks.json gone → outdated.
        try install()
        try FileManager.default.removeItem(at: hooksURL)
        XCTAssertEqual(try state(), .outdated)

        // Legacy flag lingering → outdated even with hooks + flag right.
        try install()
        var config = try readConfig()
        config = config.replacingOccurrences(
            of: "hooks = true", with: "hooks = true\ncodex_hooks = true"
        )
        try Data(config.utf8).write(to: configURL)
        XCTAssertEqual(try state(), .outdated)
    }

    func testOutdatedWhenReporterPathChanges() throws {
        try install(reporter: "/old/path/pedals-hook")
        XCTAssertEqual(try state(), .outdated)
        try install()
        XCTAssertEqual(try state(), .installed)
    }

    func testRefreshManagedInstallationUpdatesReporterAndEntries() throws {
        let source = home.appendingPathComponent("app/pedals-hook")
        let destination = home.appendingPathComponent(".pedals/bin/pedals-hook")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("new reporter".utf8).write(to: source)
        try Data("old reporter".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path
        )
        try install(reporter: destination.path)

        XCTAssertTrue(try HookInstaller.refreshManagedCodexInstallation(
            reporterSource: source,
            reporterDestination: destination,
            home: home
        ))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new reporter".utf8))
        XCTAssertEqual(
            try HookInstaller.state(
                for: .codex, reporterPath: destination.path, home: home
            ),
            .installed
        )
        XCTAssertEqual(Set(managedCommands(in: try readHooks()).keys), [
            "SessionStart", "UserPromptSubmit", "PreToolUse",
            "PermissionRequest", "Stop", "SessionEnd",
        ])
    }

    func testRefreshManagedInstallationNeverOptsIn() throws {
        let source = home.appendingPathComponent("app/pedals-hook")
        let destination = home.appendingPathComponent(".pedals/bin/pedals-hook")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("new reporter".utf8).write(to: source)

        XCTAssertFalse(try HookInstaller.refreshManagedCodexInstallation(
            reporterSource: source,
            reporterDestination: destination,
            home: home
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }
}
