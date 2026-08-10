import XCTest

@testable import TTYBuild

final class HomeAgentLaunchTests: XCTestCase {
    @MainActor
    func testCodexOpensChatGPTHomeUniversalLink() {
        XCTAssertEqual(
            HomeViewController.agentAppURL(for: "codex")?.absoluteString,
            "https://chatgpt.com/#native"
        )
    }

    @MainActor
    func testClaudeOpensNewConversationUniversalLink() {
        XCTAssertEqual(
            HomeViewController.agentAppURL(for: "claude")?.absoluteString,
            "https://claude.ai/new"
        )
    }

    @MainActor
    func testOtherAgentsHaveNoAppShortcut() {
        for slug in [
            "copilot", "grok", "hermes", "kimi", "kiro", "omp",
            "opencode", "pi", "unknown",
        ] {
            XCTAssertNil(HomeViewController.agentAppURL(for: slug), slug)
        }
    }
}
