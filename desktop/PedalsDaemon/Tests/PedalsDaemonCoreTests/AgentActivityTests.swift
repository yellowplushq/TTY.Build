import Foundation
import PedalsKit
import XCTest

@testable import PedalsDaemonCore

final class AgentActivityTests: XCTestCase {
    private func info(
        id: String = "a-1",
        state: AgentState = .waiting,
        updatedAt: Double = 1_000
    ) -> AgentInfo {
        AgentInfo(
            id: id,
            agent: "claude",
            state: state,
            sessionName: "Pedals release",
            cwd: "/tmp/pedals",
            action: "AskUserQuestion",
            message: "Pick one",
            prompt: "  choose\n a   plan ",
            sessionId: 4,
            term: "xterm-256color",
            updatedAt: updatedAt
        )
    }

    func testContentIsCompactAndRoundTripsEndToEnd() throws {
        let secret = Data(repeating: 0x42, count: 32)
        let key = AgentActivity.activityKey(secret: secret)
        let content = AgentActivity.Content(info: info())
        XCTAssertEqual(content.sessionName, "Pedals release")
        XCTAssertEqual(content.project, "pedals")
        XCTAssertEqual(content.prompt, "choose a plan")

        let sealed = try AgentActivity.seal(content, key: key, computerID: "computer-a")
        XCTAssertLessThanOrEqual(sealed.count, RelayMetadata.AgentActivityEnvelope.maxSealedBytes)
        XCTAssertEqual(
            try AgentActivity.open(sealed, key: key, computerID: "computer-a"),
            content
        )
        XCTAssertThrowsError(
            try AgentActivity.open(sealed, key: key, computerID: "computer-b")
        )
    }

    func testAgentCountsIncludeOnlyRecentFinishedAgents() {
        let now = Date(timeIntervalSince1970: 1_000)
        let list = [
            info(id: "a", state: .running),
            info(id: "b", state: .waiting),
            info(id: "c", state: .error),
            info(id: "d", state: .done, updatedAt: 950),
            info(id: "e", state: .done, updatedAt: 900),
        ]
        XCTAssertEqual(
            RelayHostClient.agentCounts(of: list, now: now),
            RelayMetadata.AgentCounts(running: 1, waiting: 2, done: 1)
        )
        XCTAssertEqual(RelayHostClient.agentCounts(of: [], now: now), .zero)
    }
}
