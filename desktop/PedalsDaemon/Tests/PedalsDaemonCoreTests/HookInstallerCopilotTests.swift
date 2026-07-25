import Foundation
import XCTest

@testable import PedalsDaemonCore

/// Copilot's whole-file installer at ~/.copilot/hooks/pedals.json: canonical
/// byte-compare, refusal to clobber unowned files, sentinel-gated deletes.
final class HookInstallerCopilotTests: XCTestCase {
    private var home: URL!
    private let reporter = "/Users/me/.pedals/bin/pedals-hook"

    private var fileURL: URL {
        home.appendingPathComponent(".copilot/hooks/pedals.json")
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedals-copilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func state() throws -> HookInstaller.State {
        try HookInstaller.state(for: .copilot, reporterPath: reporter, home: home)
    }

    func testFreshInstallShape() throws {
        try HookInstaller.install(for: .copilot, reporterPath: reporter, home: home)
        let data = try Data(contentsOf: fileURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            [
                "sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse",
                "agentStop", "sessionEnd", "notification",
            ]
        )
        let start = try XCTUnwrap(hooks["sessionStart"] as? [[String: Any]])
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start[0]["type"] as? String, "command")
        XCTAssertEqual(
            start[0]["bash"] as? String,
            "\(reporter) copilot --event session-start \(HookInstaller.sentinel)"
        )
        XCTAssertEqual(start[0]["timeoutSec"] as? Int, 1)
        XCTAssertNil(start[0]["command"], "copilot uses `bash`, not `command`")
        let notify = try XCTUnwrap(hooks["notification"] as? [[String: Any]])
        XCTAssertEqual(
            notify[0]["bash"] as? String,
            "\(reporter) copilot --event notification \(HookInstaller.sentinel)"
        )
        XCTAssertEqual(notify[0]["timeoutSec"] as? Int, 1)
        XCTAssertEqual(try state(), .installed)
    }

    func testReinstallIsIdempotent() throws {
        try HookInstaller.install(for: .copilot, reporterPath: reporter, home: home)
        let first = try Data(contentsOf: fileURL)
        try HookInstaller.install(for: .copilot, reporterPath: reporter, home: home)
        XCTAssertEqual(try Data(contentsOf: fileURL), first)
    }

    func testRefusesToClobberUnownedFile() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let userContent = Data("{\"version\": 1, \"hooks\": {}}\n".utf8)
        try userContent.write(to: fileURL)

        XCTAssertThrowsError(
            try HookInstaller.install(for: .copilot, reporterPath: reporter, home: home)
        ) { error in
            guard case HookInstaller.InstallerError.unownedFile = error else {
                return XCTFail("expected unownedFile, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), userContent, "file untouched")
        XCTAssertEqual(try state(), .notInstalled)

        // Uninstall must not delete it either.
        try HookInstaller.uninstall(for: .copilot, home: home)
        XCTAssertEqual(try Data(contentsOf: fileURL), userContent)
    }

    func testUninstallDeletesOwnedFile() throws {
        try HookInstaller.install(for: .copilot, reporterPath: reporter, home: home)
        try HookInstaller.uninstall(for: .copilot, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try state(), .notInstalled)
    }

    func testOutdatedWhenReporterPathChanges() throws {
        try HookInstaller.install(for: .copilot, reporterPath: "/old/pedals-hook", home: home)
        XCTAssertEqual(try state(), .outdated)
        try HookInstaller.install(for: .copilot, reporterPath: reporter, home: home)
        XCTAssertEqual(try state(), .installed)
    }

    func testStateOnMissingFile() throws {
        XCTAssertEqual(try state(), .notInstalled)
        try HookInstaller.uninstall(for: .copilot, home: home) // no-op
    }
}
