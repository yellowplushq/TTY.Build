import ActivityKit
import PedalsKit
import XCTest
@testable import Pedals

final class LiveActivityPresentationTests: XCTestCase {
    func testNoAgentsAlwaysUsesTerminalPresentation() {
        let state = makeState(
            running: 0,
            waiting: 0,
            done: 0,
            recentState: AgentState.waiting.rawValue
        )

        XCTAssertEqual(state.totalAgents, 0)
        XCTAssertNil(state.displayedAgentState)
    }

    func testRecentAgentStateWinsWhenAgentsExist() {
        let state = makeState(
            running: 1,
            waiting: 1,
            done: 0,
            recentState: AgentState.running.rawValue
        )

        XCTAssertEqual(state.totalAgents, 2)
        XCTAssertEqual(state.displayedAgentState, .running)
    }

    func testAgentAggregateNeverFallsBackToTerminalWithoutRichContent() {
        XCTAssertEqual(
            makeState(running: 0, waiting: 1, done: 0).displayedAgentState,
            .waiting
        )
        XCTAssertEqual(
            makeState(running: 0, waiting: 0, done: 1).displayedAgentState,
            .done
        )
        XCTAssertEqual(
            makeState(running: 1, waiting: 0, done: 0).displayedAgentState,
            .running
        )
    }

    func testLocalHomePresentationResolvesWithoutEncryptedEnvelope() {
        let content = AgentActivity.Content(
            id: "agent-1",
            agent: "codex",
            state: .done,
            sessionName: "Fix Dynamic Island",
            message: "Concrete agent presentation restored",
            updatedAt: 123
        )
        var state = makeState(running: 0, waiting: 0, done: 1)
        state.recentAgentDisplay = .init(content: content)

        let resolved = state.resolvedRecentAgent
        XCTAssertEqual(resolved?.agent, "codex")
        XCTAssertEqual(resolved?.state, .done)
        XCTAssertEqual(resolved?.sessionName, "Fix Dynamic Island")
        XCTAssertEqual(resolved?.message, "Concrete agent presentation restored")
        XCTAssertEqual(state.displayedAgentState, .done)
    }

    func testContentStateDecodesOlderPayloadWithoutLocalPresentation() throws {
        let original = makeState(
            running: 1,
            waiting: 0,
            done: 0,
            recentState: AgentState.running.rawValue
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "recentAgentDisplay")

        let decoded = try JSONDecoder().decode(
            TTYActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.recentAgentDisplay)
        XCTAssertEqual(decoded.displayedAgentState, .running)
    }

    func testActivityCountSummaryCountsOnlyAdditionalAgents() {
        XCTAssertEqual(
            makeState(
                totalRunning: 2, running: 2, waiting: 1, done: 0
            ).activityCountSummary,
            "and 2 more agents, 2 terminals"
        )
        XCTAssertEqual(
            makeState(
                totalRunning: 0, running: 2, waiting: 0, done: 0
            ).activityCountSummary,
            "and 1 more agent"
        )
        XCTAssertEqual(
            makeState(
                totalRunning: 2, running: 1, waiting: 0, done: 0
            ).activityCountSummary,
            "2 terminals"
        )
    }

    func testActivityCountSummaryOmitsZeroCountsAndOfflineComputers() {
        XCTAssertEqual(
            makeState(
                totalRunning: 1, running: 0, waiting: 0, done: 0,
                offline: 4
            ).activityCountSummary,
            "1 terminal"
        )
        XCTAssertNil(
            makeState(
                totalRunning: 0, running: 1, waiting: 0, done: 0,
                offline: 4
            ).activityCountSummary
        )
    }

    private func makeState(
        totalRunning: Int = 3,
        running: Int,
        waiting: Int,
        done: Int,
        recentState: String? = nil,
        offline: Int = 0
    ) -> TTYActivityAttributes.ContentState {
        .init(
            totalRunning: totalRunning,
            agentsRunning: running,
            agentsWaiting: waiting,
            agentsDone: done,
            recentAgentState: recentState,
            onlineComputerCount: 1,
            offlineComputerCount: offline,
            updatedAt: .now,
            sequence: 1
        )
    }
}
