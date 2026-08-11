import Darwin
import Foundation
import XCTest

@testable import TTYBuildHookKit

/// Reporter-side agent process identification: argv-based matching that sees
/// through runtime wrappers, with the lineage order picking the ancestor
/// closest to the hook.
final class AgentProcessLocatorTests: XCTestCase {
    private func entry(_ pid: pid_t, _ name: String) -> LineageEntry {
        LineageEntry(pid: pid, name: name)
    }

    func testDirectCommMatch() {
        let lineage = [entry(10, "sh"), entry(20, "claude"), entry(30, "zsh")]
        XCTAssertEqual(
            AgentProcessLocator.locate(
                slug: "claude", lineage: lineage, argvProvider: { _ in nil }
            ),
            20
        )
    }

    func testNearestMatchWins() {
        // A hook spawned by a subagent CLI nested under another agent binds
        // to the nearest matching ancestor, not the outermost.
        let lineage = [entry(20, "claude"), entry(30, "codex")]
        XCTAssertEqual(
            AgentProcessLocator.locate(
                slug: "claude", lineage: lineage, argvProvider: { _ in nil }
            ),
            20
        )
    }

    func testRuntimeWrappedAgentFoundViaArgv() {
        let lineage = [entry(10, "sh"), entry(20, "node"), entry(30, "zsh")]
        let located = AgentProcessLocator.locate(
            slug: "claude", lineage: lineage,
            argvProvider: { pid in
                pid == 20 ? ["node", "/Users/dev/.nvm/versions/bin/claude", "--continue"] : nil
            }
        )
        XCTAssertEqual(located, 20)
    }

    func testRuntimeFlagsSkippedBeforeScriptPath() {
        let lineage = [entry(20, "node")]
        let located = AgentProcessLocator.locate(
            slug: "kimi", lineage: lineage,
            argvProvider: { _ in ["node", "--enable-source-maps", "/opt/kimi-code/bin/kimi"] }
        )
        XCTAssertEqual(located, 20)
    }

    func testArgvZeroBasenameMatch() {
        // Some binaries report a generic comm ("MainThread") while argv0
        // still carries the real path.
        let lineage = [entry(40, "MainThread")]
        let located = AgentProcessLocator.locate(
            slug: "opencode", lineage: lineage,
            argvProvider: { _ in ["/home/dev/.local/share/pnpm/opencode"] }
        )
        XCTAssertEqual(located, 40)
    }

    func testAliasAndSuffixNormalization() {
        let lineage = [entry(50, "claude-code")]
        XCTAssertEqual(
            AgentProcessLocator.locate(
                slug: "claude", lineage: lineage, argvProvider: { _ in nil }
            ),
            50
        )

        let wrapped = [entry(60, "bun")]
        XCTAssertEqual(
            AgentProcessLocator.locate(
                slug: "opencode", lineage: wrapped,
                argvProvider: { _ in ["bun", "/x/bin/opencode2"] }
            ),
            60
        )
    }

    func testShellCommandArgumentDoesNotMatch() {
        // `bash -c "sleep 60"` with a codex-looking path elsewhere in argv
        // must not identify bash as codex.
        let lineage = [entry(70, "bash")]
        XCTAssertNil(
            AgentProcessLocator.locate(
                slug: "codex", lineage: lineage,
                argvProvider: { _ in ["bash", "-c", "sleep 60"] }
            )
        )
    }

    func testNoMatchReturnsNil() {
        let lineage = [entry(10, "zsh"), entry(11, "login"), entry(12, "iTerm2")]
        XCTAssertNil(
            AgentProcessLocator.locate(
                slug: "claude", lineage: lineage, argvProvider: { _ in nil }
            )
        )
    }

    func testOwnProcessArgvReadable() throws {
        // KERN_PROCARGS2 on ourselves: the test runner's argv must decode.
        let argv = try XCTUnwrap(AgentProcessLocator.processArgv(pid: getpid()))
        XCTAssertFalse(argv.isEmpty)
        XCTAssertFalse(argv[0].isEmpty)
    }
}
