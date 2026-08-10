import Foundation
import XCTest

@testable import TTYBuildDaemonCore

/// Kiro's flat-entry merge into ~/.kiro/agents/kiro_default.json, gated on a
/// (faked) `kiro-cli --version` probe when the file must be created.
final class HookInstallerKiroTests: XCTestCase {
    private var home: URL!
    private let reporter = "/Users/me/.ttybuild/bin/ttybuild-hook"

    private var fileURL: URL {
        home.appendingPathComponent(".kiro/agents/kiro_default.json")
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-kiro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func probe(
        status: Int32 = 0, stdout: String = "kiro-cli 2.3.0", stderr: String = ""
    ) -> HookInstaller.KiroProbe {
        {
            HookInstaller.KiroProbeOutput(
                status: status, standardOutput: stdout, standardError: stderr
            )
        }
    }

    private func install(
        reporter: String? = nil, probe: HookInstaller.KiroProbe? = nil
    ) throws {
        try HookInstaller.install(
            for: .kiro, reporterPath: reporter ?? self.reporter, home: home,
            kiroProbe: probe ?? self.probe()
        )
    }

    private func state() throws -> HookInstaller.State {
        try HookInstaller.state(for: .kiro, reporterPath: reporter, home: home)
    }

    private func readRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFreshInstallWritesDefaultConfigAndFlatHooks() throws {
        try install()
        let root = try readRoot()
        // Supacode's known-good default agent config.
        XCTAssertEqual(root["name"] as? String, "kiro_default")
        XCTAssertEqual(root["tools"] as? [String], ["*"])
        XCTAssertEqual(root["useLegacyMcpJson"] as? Bool, true)
        XCTAssertEqual((root["resources"] as? [String])?.count, 4)
        // Flat entries, millisecond timeouts, no type/matcher wrapper.
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["agentSpawn", "userPromptSubmit", "stop"])
        let spawn = try XCTUnwrap(hooks["agentSpawn"] as? [[String: Any]])
        XCTAssertEqual(spawn.count, 1)
        XCTAssertEqual(
            spawn[0]["command"] as? String,
            "\(reporter) kiro --event session-start \(HookInstaller.sentinel)"
        )
        XCTAssertEqual(spawn[0]["timeout_ms"] as? Int, 1000)
        XCTAssertNil(spawn[0]["type"])
        XCTAssertNil(spawn[0]["timeout"])
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertEqual(stop[0]["timeout_ms"] as? Int, 1000)
        XCTAssertEqual(try state(), .installed)
    }

    func testProbeGateRefusesUnavailableCLI() throws {
        XCTAssertThrowsError(try install(probe: probe(status: 127))) { error in
            guard case HookInstaller.InstallerError.kiroCLIUnavailable = error else {
                return XCTFail("expected kiroCLIUnavailable, got \(error)")
            }
        }
        XCTAssertThrowsError(try install(probe: probe(stdout: "no version here"))) { error in
            guard case HookInstaller.InstallerError.kiroCLIUnavailable = error else {
                return XCTFail("expected kiroCLIUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testProbeGateRefusesWrongMajorVersion() throws {
        XCTAssertThrowsError(try install(probe: probe(stdout: "kiro-cli 1.9.4"))) { error in
            guard case HookInstaller.InstallerError.unsupportedKiroVersion(let found) = error
            else {
                return XCTFail("expected unsupportedKiroVersion, got \(error)")
            }
            XCTAssertEqual(found, "1.9.4")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testProbeReadsVersionFromStderr() throws {
        try install(probe: probe(stdout: "", stderr: "kiro-cli version 2.0.1\n"))
        XCTAssertEqual(try state(), .installed)
    }

    func testProbeSkippedWhenFileExists() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "name": "custom",
            "hooks": ["stop": [["command": "my-hook.sh", "timeout_ms": 1] as [String: Any]]],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: fileURL)

        try install(probe: {
            XCTFail("probe must not run when the agent config already exists")
            return HookInstaller.KiroProbeOutput(status: 127, standardOutput: "", standardError: "")
        })

        let root = try readRoot()
        XCTAssertEqual(root["name"] as? String, "custom", "existing config not replaced")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "user entry + ttybuild entry")
        XCTAssertEqual(stop[0]["command"] as? String, "my-hook.sh")
        XCTAssertEqual(try state(), .installed)
    }

    func testReinstallIsIdempotent() throws {
        try install()
        let first = try Data(contentsOf: fileURL)
        try install()
        XCTAssertEqual(try Data(contentsOf: fileURL), first)
    }

    func testUninstallPreservesUserEntries() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "name": "kiro_default",
            "hooks": ["stop": [["command": "my-hook.sh", "timeout_ms": 1] as [String: Any]]],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: fileURL)
        try install()
        try HookInstaller.uninstall(for: .kiro, home: home)

        let root = try readRoot()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop[0]["command"] as? String, "my-hook.sh")
        XCTAssertNil(hooks["agentSpawn"], "all-ttybuild event arrays pruned")
        XCTAssertEqual(try state(), .notInstalled)
    }

    func testUninstallKeepsEmptyHooksObject() throws {
        try install()
        try HookInstaller.uninstall(for: .kiro, home: home)
        let root = try readRoot()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertTrue(hooks.isEmpty, "hooks stays as {} — part of the default agent shape")
    }

    func testOutdatedWhenReporterPathChanges() throws {
        try install(reporter: "/old/ttybuild-hook")
        XCTAssertEqual(try state(), .outdated)
        try install()
        XCTAssertEqual(try state(), .installed)
    }

    func testStateOnMissingFile() throws {
        XCTAssertEqual(try state(), .notInstalled)
    }
}
