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

    /// Two computers' envelopes must pack into one 4 KiB Live Activity push.
    /// The budget is a guarantee, not an aim: even pathological input (CJK
    /// text, quote-heavy strings whose JSON escapes double in size, oversized
    /// identity fields) seals inside the target with the second row intact.
    func testSealWithinBudgetGuaranteesBothRowsUnderPathologicalInput() throws {
        let cjk = String(repeating: "字", count: 400)
        let quotes = String(repeating: "\"\\", count: 300)
        let verbose = AgentInfo(
            id: UUID().uuidString + quotes,
            agent: "opencode-" + cjk,
            state: .waiting,
            sessionName: quotes,
            cwd: "/tmp/" + cjk,
            action: quotes,
            message: quotes,
            prompt: cjk,
            sessionId: Int(Int32.max),
            term: quotes,
            updatedAt: 1_770_000_000.123
        )
        var content = AgentActivity.Content(info: verbose)
        content.second = AgentActivity.Companion(info: verbose)

        let key = AgentActivity.activityKey(secret: Data(repeating: 0x42, count: 32))
        let sealed = try AgentActivity.sealWithinBudget(
            content, key: key, computerID: "computer-a"
        )
        XCTAssertLessThanOrEqual(
            sealed.count, RelayMetadata.AgentActivityEnvelope.targetSealedBytes
        )

        // The budget squeezes text, never the row count or agent identity.
        let opened = try AgentActivity.open(sealed, key: key, computerID: "computer-a")
        XCTAssertNotNil(opened.second)
        XCTAssertEqual(opened.state, .waiting)
        XCTAssertEqual(opened.second?.state, .waiting)
        XCTAssertTrue(opened.agent.hasPrefix("opencode-"))
    }

    /// Ordinary content sealed through the budget path is byte-identical to
    /// a plain seal: the first scale pass leaves standard truncation alone.
    func testSealWithinBudgetKeepsOrdinaryContentIntact() throws {
        var content = AgentActivity.Content(info: info())
        content.second = AgentActivity.Companion(info: info(id: "a-2"))
        let key = AgentActivity.activityKey(secret: Data(repeating: 0x42, count: 32))
        let sealed = try AgentActivity.sealWithinBudget(
            content, key: key, computerID: "computer-a"
        )
        XCTAssertEqual(
            try AgentActivity.open(sealed, key: key, computerID: "computer-a"),
            content
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

    func testOnlyRunningStateEdgesBypassTheRefreshFloor() {
        let done = info(id: "resumed", state: .done)
        let running = info(id: "resumed", state: .running, updatedAt: 1_001)
        XCTAssertTrue(RelayHostClient.enteredRunning(running, from: [done]))

        let alreadyRunning = info(id: "resumed", state: .running)
        XCTAssertFalse(RelayHostClient.enteredRunning(running, from: [alreadyRunning]))
        XCTAssertFalse(
            RelayHostClient.enteredRunning(info(id: "resumed", state: .waiting), from: [done])
        )
    }
}
