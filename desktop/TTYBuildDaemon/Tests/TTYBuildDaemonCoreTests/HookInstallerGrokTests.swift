import Foundation
import XCTest

@testable import TTYBuildDaemonCore

/// Grok's whole-file installer at ~/.grok/hooks/ttybuild.json: grouped shape
/// with a TTYBUILD_HOME env passthrough on every entry.
final class HookInstallerGrokTests: XCTestCase {
    private var home: URL!
    private let reporter = "/Users/me/.ttybuild/bin/ttybuild-hook"

    private var fileURL: URL {
        home.appendingPathComponent(".grok/hooks/ttybuild.json")
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func state() throws -> HookInstaller.State {
        try HookInstaller.state(for: .grok, reporterPath: reporter, home: home)
    }

    private func readRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFreshInstallShape() throws {
        try HookInstaller.install(for: .grok, reporterPath: reporter, home: home)
        let root = try readRoot()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
        )
        // Every entry carries the TTYBUILD_HOME env passthrough.
        for (event, value) in hooks {
            let groups = try XCTUnwrap(value as? [[String: Any]], "\(event)")
            for group in groups {
                for entry in try XCTUnwrap(group["hooks"] as? [[String: Any]]) {
                    XCTAssertEqual(
                        entry["env"] as? [String: String],
                        ["TTYBUILD_HOME": "${TTYBUILD_HOME}"],
                        "\(event) entry lacks env passthrough"
                    )
                }
            }
        }
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "")
        let toolEntry = try XCTUnwrap((preToolUse[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            toolEntry["command"] as? String,
            "\(reporter) grok --event tool \(HookInstaller.sentinel)"
        )
        XCTAssertEqual(toolEntry["timeout"] as? Int, 1)
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertNil(stop[0]["matcher"])
        XCTAssertEqual(try state(), .installed)
    }

    func testReinstallIsIdempotent() throws {
        try HookInstaller.install(for: .grok, reporterPath: reporter, home: home)
        let first = try Data(contentsOf: fileURL)
        try HookInstaller.install(for: .grok, reporterPath: reporter, home: home)
        XCTAssertEqual(try Data(contentsOf: fileURL), first)
    }

    func testRefusesToClobberUnownedFile() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let userContent = Data("{\"hooks\": {}}\n".utf8)
        try userContent.write(to: fileURL)
        XCTAssertThrowsError(
            try HookInstaller.install(for: .grok, reporterPath: reporter, home: home)
        ) { error in
            guard case HookInstaller.InstallerError.unownedFile = error else {
                return XCTFail("expected unownedFile, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), userContent)
        XCTAssertEqual(try state(), .notInstalled)
        try HookInstaller.uninstall(for: .grok, home: home)
        XCTAssertEqual(try Data(contentsOf: fileURL), userContent, "unowned file survives uninstall")
    }

    func testMissingEnvReadsOutdated() throws {
        try HookInstaller.install(for: .grok, reporterPath: reporter, home: home)
        // Strip the env maps but keep the sentinel commands.
        var root = try readRoot()
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            for groupIndex in groups.indices {
                var entries = try XCTUnwrap(groups[groupIndex]["hooks"] as? [[String: Any]])
                for entryIndex in entries.indices {
                    entries[entryIndex].removeValue(forKey: "env")
                }
                groups[groupIndex]["hooks"] = entries
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: fileURL)
        XCTAssertEqual(try state(), .outdated)
    }

    func testUninstallDeletesOwnedFileAndStateTransitions() throws {
        try HookInstaller.install(for: .grok, reporterPath: "/old/ttybuild-hook", home: home)
        XCTAssertEqual(try state(), .outdated)
        try HookInstaller.install(for: .grok, reporterPath: reporter, home: home)
        XCTAssertEqual(try state(), .installed)
        try HookInstaller.uninstall(for: .grok, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try state(), .notInstalled)
    }
}
