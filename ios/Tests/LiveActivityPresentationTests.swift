import ActivityKit
import TTYBuildKit
import XCTest
@testable import TTYBuild

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
            ).activityCountSummary(),
            "and 2 more agents, 2 terminals"
        )
        XCTAssertEqual(
            makeState(
                totalRunning: 0, running: 2, waiting: 0, done: 0
            ).activityCountSummary(),
            "and 1 more agent"
        )
        XCTAssertEqual(
            makeState(
                totalRunning: 2, running: 1, waiting: 0, done: 0
            ).activityCountSummary(),
            "2 terminals"
        )
    }

    func testActivityCountSummaryExcludesEveryVisibleAgentRow() {
        XCTAssertEqual(
            makeState(
                totalRunning: 0, running: 2, waiting: 1, done: 0
            ).activityCountSummary(visibleAgents: 2),
            "and 1 more agent"
        )
        XCTAssertNil(
            makeState(
                totalRunning: 0, running: 1, waiting: 1, done: 0
            ).activityCountSummary(visibleAgents: 2)
        )
    }

    func testActivityCountSummaryOmitsZeroCountsAndOfflineComputers() {
        XCTAssertEqual(
            makeState(
                totalRunning: 1, running: 0, waiting: 0, done: 0,
                offline: 4
            ).activityCountSummary(),
            "1 terminal"
        )
        XCTAssertNil(
            makeState(
                totalRunning: 0, running: 1, waiting: 0, done: 0,
                offline: 4
            ).activityCountSummary()
        )
    }

    func testSecondAgentSurvivesTheLocalDisplayRoundTrip() {
        let content = AgentActivity.Content(
            id: "agent-1",
            agent: "codex",
            state: .running,
            sessionName: "Primary session",
            updatedAt: 200,
            second: .init(
                id: "agent-2",
                agent: "claude",
                state: .waiting,
                sessionName: "Second session",
                message: "Choose how to continue",
                updatedAt: 150
            )
        )
        var state = makeState(running: 1, waiting: 1, done: 0)
        state.recentAgentDisplay = .init(content: content)

        let second = state.resolvedRecentAgent?.second
        XCTAssertEqual(second?.agent, "claude")
        XCTAssertEqual(second?.state, .waiting)
        XCTAssertEqual(second?.sessionName, "Second session")
        XCTAssertEqual(second?.message, "Choose how to continue")
        XCTAssertEqual(second?.updatedAt, 150)
    }

    func testDisplayDecodesOlderPayloadWithoutSecondAgent() throws {
        let content = AgentActivity.Content(
            id: "agent-1",
            agent: "codex",
            state: .running,
            sessionName: "Primary session",
            updatedAt: 200,
            second: .init(
                id: "agent-2",
                agent: "claude",
                state: .waiting,
                updatedAt: 150
            )
        )
        var state = makeState(running: 1, waiting: 1, done: 0)
        state.recentAgentDisplay = .init(content: content)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                as? [String: Any]
        )
        var display = try XCTUnwrap(object["recentAgentDisplay"] as? [String: Any])
        display.removeValue(forKey: "second")
        object["recentAgentDisplay"] = display

        let decoded = try JSONDecoder().decode(
            TTYActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.recentAgentDisplay?.second)
        XCTAssertEqual(decoded.resolvedRecentAgent?.agent, "codex")
    }

    func testResolvedAgentRowsFollowDisplayOrderAndAggregateCap() {
        let content = AgentActivity.Content(
            id: "agent-1",
            agent: "codex",
            state: .running,
            sessionName: "Primary session",
            updatedAt: 200,
            second: .init(
                id: "agent-2",
                agent: "claude",
                state: .waiting,
                sessionName: "Second session",
                updatedAt: 150
            )
        )
        var state = makeState(running: 1, waiting: 1, done: 0)
        state.recentAgentDisplay = .init(content: content)

        let rows = state.resolvedAgentRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.slug, "codex")
        XCTAssertEqual(rows.first?.title, "Primary session")
        XCTAssertEqual(rows.last?.slug, "claude")
        XCTAssertEqual(rows.last?.state, .waiting)

        // The aggregate stays authoritative: one remaining agent means the
        // stale second row disappears.
        var single = state
        single.agentsWaiting = 0
        XCTAssertEqual(single.resolvedAgentRows.count, 1)
        XCTAssertEqual(single.resolvedAgentRows.first?.slug, "codex")
    }

    func testMoreAgentsDecodesAsOptionalAndRoundTrips() throws {
        var state = makeState(running: 2, waiting: 0, done: 0)
        state.moreAgents = [
            .init(
                computerID: "computer-b",
                state: "running",
                updatedAt: .now,
                sealed: "c2VhbGVk"
            ),
        ]
        let decoded = try JSONDecoder().decode(
            TTYActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded.moreAgents?.count, 1)
        XCTAssertEqual(decoded.moreAgents?.first?.computerID, "computer-b")
        XCTAssertEqual(decoded.moreAgents?.first?.sealed, "c2VhbGVk")

        // Pushes from an older relay omit the key entirely.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                as? [String: Any]
        )
        object.removeValue(forKey: "moreAgents")
        let legacy = try JSONDecoder().decode(
            TTYActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.moreAgents)
    }

    func testSnapshotCarriedEnvelopesPopulateContentState() {
        let updatedAt = Date(timeIntervalSince1970: 1_783_000_000)
        let snapshot = TTYStatusSnapshot(
            totalRunning: 1,
            computers: [
                ComputerTTYStatus(
                    id: "computer-a",
                    name: "Studio",
                    runningTTYCount: 1,
                    agents: ComputerAgentCounts(running: 1, waiting: 1),
                    online: true,
                    updatedAt: updatedAt
                ),
            ],
            recentAgent: .init(
                computerID: "computer-a",
                state: "waiting",
                updatedAt: updatedAt,
                sealed: "c2VhbGVk"
            ),
            moreAgents: [
                .init(
                    computerID: "computer-b",
                    state: "running",
                    updatedAt: updatedAt,
                    sealed: "b3RoZXI="
                ),
            ],
            updatedAt: updatedAt,
            sequence: 9
        )

        let state = TTYActivityAttributes.ContentState(snapshot: snapshot)
        XCTAssertEqual(state.totalAgents, 2)
        XCTAssertEqual(state.recentAgentComputerID, "computer-a")
        XCTAssertEqual(state.recentAgentState, "waiting")
        XCTAssertEqual(state.recentAgentUpdatedAt, updatedAt)
        XCTAssertEqual(state.recentAgentSealed, "c2VhbGVk")
        XCTAssertEqual(state.moreAgents?.count, 1)
        XCTAssertEqual(state.moreAgents?.first?.computerID, "computer-b")
        XCTAssertEqual(state.moreAgents?.first?.sealed, "b3RoZXI=")
        XCTAssertEqual(state.displayedAgentState, .waiting)
    }

    func testSnapshotWithoutEnvelopesLeavesContentStateCountOnly() {
        let snapshot = TTYStatusSnapshot(
            totalRunning: 1,
            computers: [
                ComputerTTYStatus(
                    id: "computer-a",
                    name: "Studio",
                    runningTTYCount: 1,
                    agents: ComputerAgentCounts(running: 1, waiting: 0),
                    online: true,
                    updatedAt: .now
                ),
            ],
            updatedAt: .now,
            sequence: 1
        )

        let state = TTYActivityAttributes.ContentState(snapshot: snapshot)
        XCTAssertNil(state.recentAgentComputerID)
        XCTAssertNil(state.recentAgentSealed)
        XCTAssertNil(state.moreAgents)
        XCTAssertEqual(state.displayedAgentState, .running)
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
