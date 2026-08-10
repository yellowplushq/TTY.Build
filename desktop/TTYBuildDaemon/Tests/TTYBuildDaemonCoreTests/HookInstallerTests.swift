import Foundation
import XCTest

@testable import TTYBuildDaemonCore

/// HookInstaller against a temp Claude settings.json: install, idempotent
/// reinstall, uninstall preserving user hooks, outdated detection.
final class HookInstallerTests: XCTestCase {
    private var directory: URL!
    private var settingsPath: String!
    private let reporter = "/Users/me/.ttybuild/bin/ttybuild-hook"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsPath = directory.appendingPathComponent("settings.json").path
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: settingsPath))
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

    private let allEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification",
        "Stop", "SessionEnd", "PreCompact",
    ]

    func testFreshInstallOnMissingFile() throws {
        try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        let root = try readSettings()
        let managed = managedCommands(in: root)
        XCTAssertEqual(Set(managed.keys), allEvents)
        for (_, commands) in managed {
            XCTAssertEqual(commands, ["\(reporter) claude \(HookInstaller.sentinel)"])
        }
        // Entry shape.
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1)
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "")
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertNil(stop[0]["matcher"], "Stop takes no matcher")
        let entry = try XCTUnwrap((stop[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["timeout"] as? Int, 1)

        XCTAssertEqual(
            try HookInstaller.state(reporterPath: reporter, settingsPath: settingsPath),
            .installed
        )
    }

    func testReinstallIsIdempotent() throws {
        try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        let managed = managedCommands(in: try readSettings())
        for (event, commands) in managed {
            XCTAssertEqual(commands.count, 1, "duplicate entries for \(event)")
        }
        XCTAssertEqual(Set(managed.keys), allEvents)
    }

    func testInstallAndUninstallPreserveUserHooksAndKeys() throws {
        let userEntry: [String: Any] = [
            "type": "command", "command": "my-own-hook.sh", "timeout": 5,
        ]
        try write([
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [userEntry]]
                ]
            ],
        ])

        try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        var root = try readSettings()
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["permissions"])
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 2, "user group + ttybuild group")
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "Bash")

        try HookInstaller.uninstall(settingsPath: settingsPath)
        root = try readSettings()
        XCTAssertEqual(root["model"] as? String, "opus")
        hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1, "only the user group survives")
        XCTAssertEqual(
            (preToolUse[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "my-own-hook.sh"
        )
        // Events that held only ttybuild entries are pruned entirely.
        XCTAssertNil(hooks["Stop"])
        XCTAssertNil(hooks["SessionStart"])
        XCTAssertEqual(
            try HookInstaller.state(reporterPath: reporter, settingsPath: settingsPath),
            .notInstalled
        )
    }

    func testUninstallPrunesEmptyHooksObject() throws {
        try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        try HookInstaller.uninstall(settingsPath: settingsPath)
        let root = try readSettings()
        XCTAssertNil(root["hooks"], "an all-ttybuild hooks object is pruned")
    }

    func testOutdatedWhenReporterPathChanges() throws {
        try HookInstaller.install(reporterPath: "/old/path/ttybuild-hook", settingsPath: settingsPath)
        XCTAssertEqual(
            try HookInstaller.state(reporterPath: reporter, settingsPath: settingsPath),
            .outdated
        )
        // Reinstall repairs it in place.
        try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        XCTAssertEqual(
            try HookInstaller.state(reporterPath: reporter, settingsPath: settingsPath),
            .installed
        )
        let managed = managedCommands(in: try readSettings())
        for (_, commands) in managed {
            XCTAssertEqual(commands.count, 1, "old-path entries were replaced, not kept")
        }
    }

    func testRefusesNonObjectHooksValue() throws {
        try write(["hooks": ["not", "an", "object"]])
        XCTAssertThrowsError(
            try HookInstaller.install(reporterPath: reporter, settingsPath: settingsPath)
        )
        XCTAssertThrowsError(try HookInstaller.uninstall(settingsPath: settingsPath))
        // The file was left untouched.
        let root = try readSettings()
        XCTAssertEqual((root["hooks"] as? [String]), ["not", "an", "object"])
    }

    func testStateOnMissingFile() throws {
        XCTAssertEqual(
            try HookInstaller.state(reporterPath: reporter, settingsPath: settingsPath),
            .notInstalled
        )
    }
}
