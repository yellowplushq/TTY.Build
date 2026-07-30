import Foundation
import XCTest

@testable import PedalsDaemonCore

/// The generated-source plugin agents: opencode (JS plugin), omp/pi (TS
/// extensions), hermes (Python plugin dir). Shared own-file semantics —
/// refusal to clobber unowned files, marker-gated deletes, byte-compare
/// outdated — plus per-agent content checks.
final class HookInstallerPluginTests: XCTestCase {
    private var home: URL!
    private let reporter = "/Users/me/.pedals/bin/pedals-hook"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedals-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func path(for agent: HookInstaller.HookedAgent) -> String {
        HookInstaller.settingsPath(for: agent, home: home)
    }

    private func state(_ agent: HookInstaller.HookedAgent) throws -> HookInstaller.State {
        try HookInstaller.state(for: agent, reporterPath: reporter, home: home)
    }

    private func content(_ agent: HookInstaller.HookedAgent) throws -> String {
        try String(contentsOfFile: path(for: agent), encoding: .utf8)
    }

    // MARK: - Shared single-file lifecycle (opencode, omp, pi)

    private func runSingleFileLifecycle(
        _ agent: HookInstaller.HookedAgent, marker: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Missing → notInstalled; uninstall is a no-op.
        XCTAssertEqual(try state(agent), .notInstalled, file: file, line: line)
        try HookInstaller.uninstall(for: agent, home: home)

        // Fresh install.
        try HookInstaller.install(for: agent, reporterPath: reporter, home: home)
        let text = try content(agent)
        XCTAssertTrue(text.hasPrefix(marker + "\n"), "marker first line", file: file, line: line)
        XCTAssertTrue(text.contains(reporter), file: file, line: line)
        XCTAssertEqual(try state(agent), .installed, file: file, line: line)

        // Idempotent reinstall.
        let first = try Data(contentsOf: URL(fileURLWithPath: path(for: agent)))
        try HookInstaller.install(for: agent, reporterPath: reporter, home: home)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path(for: agent))), first,
            file: file, line: line
        )

        // Byte drift with the marker still present → outdated.
        try Data((text + "// user edit\n").utf8)
            .write(to: URL(fileURLWithPath: path(for: agent)))
        XCTAssertEqual(try state(agent), .outdated, file: file, line: line)

        // Reporter move → outdated; reinstall repairs.
        try HookInstaller.install(for: agent, reporterPath: "/old/pedals-hook", home: home)
        XCTAssertEqual(try state(agent), .outdated, file: file, line: line)
        try HookInstaller.install(for: agent, reporterPath: reporter, home: home)
        XCTAssertEqual(try state(agent), .installed, file: file, line: line)

        // Uninstall deletes the owned file.
        try HookInstaller.uninstall(for: agent, home: home)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path(for: agent)), file: file, line: line
        )

        // An unowned file is never clobbered or deleted.
        let user = Data("export const Mine = async () => ({});\n".utf8)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path(for: agent)).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try user.write(to: URL(fileURLWithPath: path(for: agent)))
        XCTAssertThrowsError(
            try HookInstaller.install(for: agent, reporterPath: reporter, home: home),
            file: file, line: line
        ) { error in
            guard case HookInstaller.InstallerError.unownedFile = error else {
                return XCTFail("expected unownedFile, got \(error)", file: file, line: line)
            }
        }
        XCTAssertEqual(try state(agent), .notInstalled, file: file, line: line)
        try HookInstaller.uninstall(for: agent, home: home)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path(for: agent))), user,
            file: file, line: line
        )
    }

    // MARK: - opencode

    func testOpenCodeLifecycle() throws {
        try runSingleFileLifecycle(.opencode, marker: "// pedals-managed-hook")
    }

    func testOpenCodeContent() throws {
        try HookInstaller.install(for: .opencode, reporterPath: reporter, home: home)
        XCTAssertTrue(path(for: .opencode).hasSuffix(".config/opencode/plugins/pedals-presence.js"))
        let text = try content(.opencode)
        XCTAssertTrue(text.contains("export const PedalsPresence = async"))
        XCTAssertTrue(text.contains("node:child_process"))
        XCTAssertTrue(text.contains("[\"opencode\", \"--event\", event]"))
        XCTAssertTrue(text.contains("\"tool.execute.before\""))
        XCTAssertTrue(text.contains("\"permission.ask\""))
        XCTAssertTrue(text.contains("message.updated"))
        XCTAssertTrue(text.contains("message.part.updated"))
        XCTAssertTrue(text.contains("STREAM_INTERVAL_MS = 5000"))
        XCTAssertTrue(text.contains("latestMessages.get(id)"))
        XCTAssertTrue(text.contains("report(\"busy\", { sessionId: id, message })"))
        XCTAssertTrue(text.contains("permission.asked"))
        XCTAssertTrue(text.contains("session.idle"))
        XCTAssertTrue(text.contains("permission.replied"))
        XCTAssertTrue(text.contains("session.deleted"))
        XCTAssertTrue(text.contains("dispose"))
        XCTAssertFalse(text.contains("tool.execute.after"), "deliberately unmapped")
    }

    func testOpenCodeGeneratedJavaScriptParses() throws {
        let url = home.appendingPathComponent("pedals-presence.mjs")
        try HookInstaller.OpenCode.canonicalData(reporterPath: reporter).write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--check", url.path]
        let diagnostics = Pipe()
        process.standardError = diagnostics
        do {
            try process.run()
        } catch {
            throw XCTSkip("Node.js is unavailable: \(error)")
        }
        process.waitUntilExit()
        let output = String(
            decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    func testRefreshManagedGeneratedPluginsNeverOptsIn() throws {
        XCTAssertEqual(
            try HookInstaller.refreshManagedGeneratedPluginInstallations(
                reporterPath: reporter, home: home
            ),
            []
        )
        XCTAssertEqual(try state(.opencode), .notInstalled)
        XCTAssertEqual(try state(.omp), .notInstalled)
        XCTAssertEqual(try state(.pi), .notInstalled)
    }

    func testRefreshManagedGeneratedPluginsUpdatesOnlyOwnedFiles() throws {
        try HookInstaller.install(
            for: .opencode, reporterPath: "/old/pedals-hook", home: home
        )
        try HookInstaller.install(
            for: .pi, reporterPath: "/old/pedals-hook", home: home
        )
        let refreshed = try HookInstaller.refreshManagedGeneratedPluginInstallations(
            reporterPath: reporter, home: home
        )
        XCTAssertEqual(Set(refreshed), Set([.opencode, .pi]))
        XCTAssertEqual(try state(.opencode), .installed)
        XCTAssertEqual(try state(.pi), .installed)
        XCTAssertEqual(try state(.omp), .notInstalled)
    }

    // MARK: - omp / pi

    func testOmpLifecycle() throws {
        try runSingleFileLifecycle(.omp, marker: "/* pedals-managed-extension */")
    }

    func testPiLifecycle() throws {
        try runSingleFileLifecycle(.pi, marker: "/* pedals-managed-extension */")
    }

    func testOmpContent() throws {
        try HookInstaller.install(for: .omp, reporterPath: reporter, home: home)
        XCTAssertTrue(path(for: .omp).hasSuffix(".omp/agent/extensions/pedals/index.ts"))
        let text = try content(.omp)
        XCTAssertTrue(text.contains("@oh-my-pi/pi-coding-agent"))
        XCTAssertTrue(text.contains("[\"omp\", \"--event\", event]"))
        XCTAssertTrue(text.contains("agent_start"))
        XCTAssertTrue(text.contains("message_update"))
        XCTAssertTrue(text.contains("agent_end"))
        XCTAssertTrue(text.contains("lastAssistantText"))
        XCTAssertTrue(text.contains("STREAM_INTERVAL_MS = 5000"))
        XCTAssertFalse(
            text.contains("report(\"session-end\")"),
            "omp subagent shutdown must not end the top-level record"
        )
    }

    func testPiContent() throws {
        try HookInstaller.install(for: .pi, reporterPath: reporter, home: home)
        XCTAssertTrue(path(for: .pi).hasSuffix(".pi/agent/extensions/pedals/index.ts"))
        let text = try content(.pi)
        XCTAssertTrue(text.contains("@mariozechner/pi-coding-agent"))
        XCTAssertTrue(text.contains("[\"pi\", \"--event\", event]"))
        XCTAssertTrue(text.contains("message_update"))
        XCTAssertTrue(text.contains("STREAM_INTERVAL_MS = 5000"))
        XCTAssertTrue(text.contains("session_shutdown"))
        XCTAssertTrue(text.contains("report(\"session-end\")"))
    }

    // MARK: - hermes

    private var hermesDir: URL {
        home.appendingPathComponent(".hermes/plugins/pedals-presence", isDirectory: true)
    }
    private var hermesInit: URL { hermesDir.appendingPathComponent("__init__.py") }
    private var hermesYaml: URL { hermesDir.appendingPathComponent("plugin.yaml") }

    func testHermesFreshInstall() throws {
        try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        let module = try String(contentsOf: hermesInit, encoding: .utf8)
        XCTAssertTrue(module.hasPrefix("# pedals-managed-hook\n"))
        XCTAssertTrue(module.contains("[_REPORTER, \"hermes\", \"--event\", event]"))
        XCTAssertTrue(module.contains("subprocess.Popen"))
        XCTAssertTrue(module.contains("def register(ctx):"))
        XCTAssertTrue(module.contains("transform_llm_output"))
        XCTAssertTrue(module.contains("return None"))
        let yaml = try String(contentsOf: hermesYaml, encoding: .utf8)
        XCTAssertTrue(yaml.contains("name: pedals-presence"))
        XCTAssertTrue(yaml.contains("version: \"1.0.0\""))
        XCTAssertTrue(yaml.contains("provides_hooks:"))
        for hook in ["on_session_start", "pre_llm_call", "transform_llm_output", "on_session_end"] {
            XCTAssertTrue(yaml.contains("- \(hook)"), hook)
        }
        XCTAssertEqual(try state(.hermes), .installed)

        // Idempotent.
        try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        XCTAssertEqual(try state(.hermes), .installed)
    }

    func testHermesRefusesUnownedModuleAndYaml() throws {
        try FileManager.default.createDirectory(at: hermesDir, withIntermediateDirectories: true)
        try Data("def register(ctx):\n    pass\n".utf8).write(to: hermesInit)
        XCTAssertThrowsError(
            try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        ) { error in
            guard case HookInstaller.InstallerError.unownedFile = error else {
                return XCTFail("expected unownedFile, got \(error)")
            }
        }
        XCTAssertEqual(try state(.hermes), .notInstalled)
        try HookInstaller.uninstall(for: .hermes, home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hermesInit.path),
                      "unowned module survives uninstall")

        // A plugin.yaml with no owned module is someone else's plugin too.
        try FileManager.default.removeItem(at: hermesInit)
        try Data("name: other-plugin\n".utf8).write(to: hermesYaml)
        XCTAssertThrowsError(
            try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: hermesYaml.path))
    }

    func testHermesUninstallRemovesWholeDirectory() throws {
        try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        try HookInstaller.uninstall(for: .hermes, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermesDir.path))
        XCTAssertEqual(try state(.hermes), .notInstalled)
    }

    func testHermesStateRequiresBothFilesByteEqual() throws {
        try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)

        // Drifted module → outdated.
        let module = try String(contentsOf: hermesInit, encoding: .utf8)
        try Data((module + "# user edit\n").utf8).write(to: hermesInit)
        XCTAssertEqual(try state(.hermes), .outdated)

        // Restore module, break yaml → still outdated.
        try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        XCTAssertEqual(try state(.hermes), .installed)
        try FileManager.default.removeItem(at: hermesYaml)
        XCTAssertEqual(try state(.hermes), .outdated)

        // Reporter move → outdated.
        try HookInstaller.install(for: .hermes, reporterPath: reporter, home: home)
        XCTAssertEqual(
            try HookInstaller.state(for: .hermes, reporterPath: "/old/pedals-hook", home: home),
            .outdated
        )
    }

    func testHermesMissingDirectoryState() throws {
        XCTAssertEqual(try state(.hermes), .notInstalled)
        try HookInstaller.uninstall(for: .hermes, home: home) // no-op
    }
}
